import AppKit
import Foundation

/// Lists, attaches, and kills the multiplexer sessions running on a server —
/// both normal **tmux** sessions and the **tmate** session remux hosts (which
/// lives on its own socket, so a plain `tmux ls` wouldn't show it).
///
/// All remote work is plain SSH (`ssh user@host tmux …`), matching the rest of
/// the Server Library; no daemon on the target.
@MainActor
enum RemoteSessions {
    static let tmateSocket = RemuxTmateHosting.socketPath

    struct Session: Identifiable, Equatable {
        enum Kind: String { case tmux, tmate }
        let kind: Kind
        let name: String
        let windows: Int
        let attached: Bool
        var id: String { "\(kind.rawValue)/\(name)" }
    }

    // MARK: - List

    /// Lists tmux + tmate sessions on `server`. Returns `nil` if the server could
    /// not be reached (SSH auth/connection failed — e.g. a password host with no
    /// live shared connection), or the parsed sessions (possibly empty) on success.
    static func list(server: SavedServer) async -> [Session]? {
        let (dest, identity, port) = sshParams(server)
        let result = await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: listScript)
        }.value
        guard result.ok else { return nil }
        return parse(result.output)
    }

    private static let listScript: String =
        "SOCK=\(RemuxTmateHosting.socketPath); " +
        "tmux list-sessions -F 'TMUX|#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null; " +
        "if [ -S \"$SOCK\" ]; then tmate -S \"$SOCK\" list-sessions -F 'TMATE|#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null; fi"

    private static func parse(_ text: String) -> [Session] {
        var result: [Session] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let kind: Session.Kind = parts[0] == "TMATE" ? .tmate : .tmux
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result.append(Session(
                kind: kind,
                name: name,
                windows: Int(parts[2]) ?? 1,
                attached: (Int(parts[3]) ?? 0) > 0
            ))
        }
        return result
    }

    // MARK: - Attach

    /// Opens a terminal attached to `session` on `server`.
    @discardableResult
    static func attach(server: SavedServer, session: Session) -> Workspace? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        let remote: String
        switch session.kind {
        case .tmux:
            remote = "tmux attach -t \(RemuxCollabSession.shellQuote(session.name))"
        case .tmate:
            remote = "tmate -S \(tmateSocket) attach"
        }
        return tabManager.addWorkspace(
            title: "\(server.nickname) · \(session.name)",
            initialTerminalCommand: RemuxCollabSession.remoteCommandTerminal(server: server, remoteCommand: remote),
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false
        )
    }

    // MARK: - Kill

    /// Kills `session` on `server`. Returns `true` if the SSH command exited 0.
    static func kill(server: SavedServer, session: Session) async -> Bool {
        let (dest, identity, port) = sshParams(server)
        let remote: String
        switch session.kind {
        case .tmux:
            remote = "tmux kill-session -t \(RemuxCollabSession.shellQuote(session.name))"
        case .tmate:
            // tmate has one session per server; kill-server tears it down.
            remote = "tmate -S \(tmateSocket) kill-server"
        }
        return await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: remote).ok
        }.value
    }

    // MARK: - SSH plumbing

    private static func sshParams(_ server: SavedServer) -> (String, String?, Int?) {
        let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (server.sshDestination, (identity?.isEmpty == false) ? identity : nil, server.port)
    }

    private nonisolated static func sshCapture(
        destination: String, identity: String?, port: Int?, remoteCommand: String
    ) -> (output: String, ok: Bool) {
        // BatchMode so we never block on a password prompt; ControlMaster lets us
        // ride the interactive Connect session's authentication (so password-only
        // hosts list their sessions once the user has connected).
        var args = ["-o", "ConnectTimeout=18", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes"]
        args += RemuxCollabSession.controlOptionArgs(for: destination)
        if let identity { args += ["-i", identity] }
        if let port { args += ["-p", String(port)] }
        args.append(destination)
        args.append(remoteCommand)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return ("", false) }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus == 0)
    }
}
