import AppKit
import Foundation

/// Live-collaboration engine for remux: multiple people share ONE tmux session
/// on a host, so everyone is in the same live shell ("remuxed into one server").
///
/// Transport/auth/NAT-traversal are delegated to the connection the host already
/// uses — Tailscale SSH for tailnet servers (keyless, ACL-scoped, shareable via
/// Tailscale node sharing) or plain SSH otherwise. The shared terminal itself is
/// just `tmux new-session -A -s <name>` (attach-or-create) over that connection;
/// tmux's native multi-client model does the rest.
///
/// `@MainActor` because it drives `TabManager`/`Workspace` and `NSPasteboard`.
@MainActor
enum RemuxCollabSession {
    /// URL scheme + host for invite links (registered in Info.plist as `remux://`).
    static let inviteScheme = "remux"
    static let inviteHostPath = "join"

    // MARK: - Session-name hygiene

    /// tmux session names cannot contain `.`/`:` and we keep them shell-safe so
    /// the attach command needs no quoting. Empty input falls back to "shared".
    static func sanitizedSessionName(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return cleaned.isEmpty ? "shared" : cleaned
    }

    // MARK: - Command construction

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Stable short socket path for a destination's SSH ControlMaster, so reuse
    /// works across separate processes/launches. (djb2 hash → 8 hex chars.)
    nonisolated static func controlPath(for destination: String) -> String {
        var hash: UInt64 = 5381
        for byte in destination.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return "/tmp/rmcm-\(String(hash & 0xffff_ffff, radix: 16)).sock"
    }

    /// Common OpenSSH `-o` options that share one authenticated connection across
    /// commands: the interactive Connect session becomes the master, and later
    /// non-interactive calls (session list/kill, scp, file browser) ride it — so a
    /// password-only host (e.g. a Mac over Remote Login) is entered once, not per
    /// command. Only applies to plain `ssh`/`scp` (not Tailscale SSH).
    nonisolated static func controlOptionArgs(for destination: String) -> [String] {
        ["-o", "ControlMaster=auto",
         "-o", "ControlPath=\(controlPath(for: destination))",
         "-o", "ControlPersist=30m"]
    }

    /// The base SSH invocation (no remote command) that opens an interactive
    /// shell on `server`: `ssh -t [-p][-i] user@host`, or `tailscale ssh user@host`
    /// when the server opts into Tailscale SSH. A TTY is always requested so tmux
    /// works and Tailscale's interactive auth check can display in the pane.
    private static func baseSSH(server: SavedServer) -> String {
        if server.usesTailscaleSSH, let binary = TailscaleDiscovery.locateBinary() {
            return "\(shellQuote(binary)) ssh \(shellQuote(server.sshDestination))"
        }
        var parts = ["ssh", "-t"]
        parts += controlOptionArgs(for: server.sshDestination)
        if let port = server.port { parts += ["-p", String(port)] }
        if let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty {
            parts += ["-i", shellQuote(identity)]
        }
        parts.append(shellQuote(server.sshDestination))
        return parts.joined(separator: " ")
    }

    /// Wraps a command so the terminal pane stays open if it exits non-zero,
    /// surfacing the error (or a Tailscale auth prompt) instead of vanishing.
    static func holdOnError(_ command: String) -> String {
        command + "; __rc=$?; if [ \"$__rc\" -ne 0 ]; then printf '\\n[remux] connection closed (exit %s). Press Enter to close.\\n' \"$__rc\"; read -r _; fi"
    }

    /// Terminal command to open an interactive shell on `server`.
    static func interactiveCommand(server: SavedServer) -> String {
        holdOnError(baseSSH(server: server))
    }

    /// Terminal command that runs an arbitrary (simple, shell-safe) remote command
    /// over the server's pty-allocating SSH — e.g. attaching a tmate session.
    static func remoteCommandTerminal(server: SavedServer, remoteCommand: String) -> String {
        holdOnError("\(baseSSH(server: server)) \(remoteCommand)")
    }

    /// Terminal command that attaches to (or creates) the shared tmux session
    /// `session` on `server`, over the same pty-allocating base SSH.
    static func attachCommand(server: SavedServer, session rawSession: String) -> String {
        let session = sanitizedSessionName(rawSession)
        let remoteTmux = "tmux new-session -A -s \(session)" // session is shell-safe
        return holdOnError("\(baseSSH(server: server)) \(remoteTmux)")
    }

    // MARK: - Invite links

    /// Builds a `remux://join?...` invite for a shared session on `server`.
    static func inviteURL(server: SavedServer, session rawSession: String) -> URL? {
        var components = URLComponents()
        components.scheme = inviteScheme
        components.host = inviteHostPath
        components.queryItems = [
            URLQueryItem(name: "host", value: server.sshDestination),
            URLQueryItem(name: "session", value: sanitizedSessionName(rawSession)),
            URLQueryItem(name: "ts", value: server.usesTailscaleSSH ? "1" : "0"),
        ]
        return components.url
    }

    /// A parsed invite: where to connect and how.
    struct Invite: Equatable {
        let host: String
        let session: String
        let useTailscaleSSH: Bool

        /// A transient `SavedServer` sufficient to build the attach command.
        var server: SavedServer {
            SavedServer(nickname: host, host: host, useTailscaleSSH: useTailscaleSSH ? true : nil)
        }
    }

    /// Parses a pasted `remux://join?host=&session=&ts=` link into an `Invite`.
    /// Returns `nil` if the string isn't a recognizable remux invite.
    static func parseInvite(_ raw: String) -> Invite? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == inviteScheme,
              (components.host?.lowercased() == inviteHostPath || components.path.contains(inviteHostPath)) else {
            return nil
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let host = value("host"), !host.isEmpty,
              let session = value("session"), !session.isEmpty else {
            return nil
        }
        let ts = (value("ts") ?? "0") == "1"
        return Invite(host: host, session: sanitizedSessionName(session), useTailscaleSSH: ts)
    }

    // MARK: - Actions

    /// Hosts a shared session on `server`: opens the host's terminal attached to
    /// `session` and copies the `remux://join` invite to the clipboard.
    ///
    /// - Returns: the invite URL (also placed on the pasteboard), or `nil` if the
    ///   app graph isn't ready.
    @discardableResult
    static func host(server: SavedServer, session rawSession: String, store: ServerLibraryStore = .shared) -> URL? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        let session = sanitizedSessionName(rawSession)

        _ = tabManager.addWorkspace(
            title: "\(server.nickname) · \(session)",
            initialTerminalCommand: attachCommand(server: server, session: session),
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false
        )
        store.markConnected(id: server.id)

        guard let url = inviteURL(server: server, session: session) else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        return url
    }

    /// Joins a shared session described by `invite`: opens a terminal attached to
    /// the same tmux session on the same host.
    @discardableResult
    static func join(_ invite: Invite) -> Workspace? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        return tabManager.addWorkspace(
            title: "\(invite.host) · \(invite.session)",
            initialTerminalCommand: attachCommand(server: invite.server, session: invite.session),
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false
        )
    }
}
