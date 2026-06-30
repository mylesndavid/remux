import AppKit
import Foundation

/// "Share a Room with a friend over a Cloudflare link" — for people who aren't on
/// your tailnet and shouldn't get a shell on the box.
///
/// Safety model (everything is scoped + killable, by design):
/// - A **quick tunnel** (`cloudflared tunnel --url tcp://localhost:22`) — ephemeral,
///   dies the moment it's stopped; no named tunnel, DNS, or permanent exposure.
/// - An **ephemeral SSH key** added to the box's `authorized_keys` locked to the
///   room with a forced command: `command="tmux -L <socket> new-session -A -s shared",restrict`.
///   Even if the link leaks, the holder can ONLY attach that one room — no shell,
///   no port-forwarding (restrict), nothing else.
/// - A marker comment on the key line + a tracked PID file so **Stop sharing**
///   fully tears down (kills the tunnel, removes the key line). A belt-and-braces
///   `pkill` fallback is offered too.
///
/// Untested end-to-end (needs a Cloudflare-reachable box + a second machine); the
/// scripts are conservative and idempotent.
@MainActor
enum RemuxCloudflareShare {
    struct Share: Equatable {
        let server: SavedServer
        let roomSocket: String
        let cfHostname: String      // e.g. abc-def.trycloudflare.com (no scheme)
        let user: String
        let privateKey: String      // ephemeral OpenSSH private key (PEM)
        let marker: String          // authorized_keys marker for revoke

        /// A copy-paste command a friend runs in any terminal that has `ssh` +
        /// `cloudflared`. Writes the ephemeral key to a temp file via process
        /// substitution and proxies through the quick tunnel into the room.
        var friendCommand: String {
            "ssh -o StrictHostKeyChecking=no -o ProxyCommand='cloudflared access tcp --hostname \(cfHostname)' " +
            "-i <(printf '%s' \"$REMUX_KEY\") \(user)@\(cfHostname)"
        }
    }

    enum Failure: Error, Equatable {
        case unreachable(String)
        case keygenFailed
        case cloudflaredInstallFailed
        case noTunnelURL
    }

    // MARK: - Share

    static func share(server: SavedServer, roomSocket: String) async -> Result<Share, Failure> {
        let user = server.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "root"
        // 1) Generate an ephemeral keypair locally.
        guard let key = generateEphemeralKey() else { return .failure(.keygenFailed) }
        let marker = "remux-cf-\(UUID().uuidString.prefix(8))"

        // 2) On the box: ensure cloudflared, install the scoped key, start the
        //    quick tunnel, return the public hostname.
        let (dest, identity, port) = sshParams(server)
        let script = remoteShareScript(socket: roomSocket, pubkey: key.publicLine, marker: marker)
        let result = await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: script, timeout: 90)
        }.value
        guard result.ok else { return .failure(.unreachable(result.output)) }
        if result.output.contains("CLOUDFLARED_INSTALL_FAILED") { return .failure(.cloudflaredInstallFailed) }

        var host: String?
        for line in result.output.split(separator: "\n") where line.hasPrefix("CFHOST=") {
            let raw = String(line.dropFirst("CFHOST=".count)).trimmingCharacters(in: .whitespaces)
            host = raw.replacingOccurrences(of: "https://", with: "")
        }
        guard let cfHostname = host, !cfHostname.isEmpty else { return .failure(.noTunnelURL) }

        let share = Share(server: server, roomSocket: roomSocket, cfHostname: cfHostname,
                          user: user, privateKey: key.privateKey, marker: marker)
        // Copy the friend command (key supplied via REMUX_KEY env) to clipboard.
        copyFriendInvite(share)
        return .success(share)
    }

    // MARK: - Compact invite link (remux://join-cf)

    /// A single clickable invite link. The scoped one-time key rides inside it
    /// (base64); safe to share because the key is forced-command-locked to this
    /// room only. The friend's remux opens it → writes the key, connects, lands
    /// in the room. Much cleaner than pasting a shell command.
    static func joinLink(_ share: Share) -> String {
        var c = URLComponents()
        c.scheme = "remux"
        c.host = "join-cf"
        let keyB64 = Data(share.privateKey.utf8).base64EncodedString()
        c.queryItems = [
            URLQueryItem(name: "h", value: share.cfHostname),
            URLQueryItem(name: "u", value: share.user),
            URLQueryItem(name: "room", value: share.roomSocket),
            URLQueryItem(name: "k", value: keyB64),
        ]
        return c.url?.absoluteString ?? ""
    }

    struct JoinInfo: Equatable {
        let cfHostname: String
        let user: String
        let room: String
        let privateKey: String
    }

    /// Parses a `remux://join-cf?...` link. Returns nil if it isn't one.
    static func parseJoinLink(_ raw: String) -> JoinInfo? {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "remux",
              (c.host?.lowercased() == "join-cf" || c.path.contains("join-cf")) else { return nil }
        let items = c.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let h = v("h"), !h.isEmpty, let u = v("u"), !u.isEmpty,
              let keyB64 = v("k"), let keyData = Data(base64Encoded: keyB64),
              let key = String(data: keyData, encoding: .utf8) else { return nil }
        return JoinInfo(cfHostname: h, user: u, room: v("room") ?? "", privateKey: key)
    }

    /// Joins a shared room from an invite: writes the one-time key to a private
    /// temp file and opens a terminal that proxies through the Cloudflare tunnel.
    /// Requires `cloudflared` on the joiner's machine (the held-open pane shows a
    /// clear error if it's missing).
    @discardableResult
    static func join(_ info: JoinInfo) -> Workspace? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remux-cf-join-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyPath = dir.appendingPathComponent("key")
        do {
            try info.privateKey.write(to: keyPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
        } catch { return nil }

        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let proxy = "cloudflared access tcp --hostname \(info.cfHostname)"
        let command = RemuxCollabSession.holdOnError(
            "ssh -t -o StrictHostKeyChecking=no -o \(q("ProxyCommand=\(proxy)")) -i \(q(keyPath.path)) \(q("\(info.user)@\(info.cfHostname)"))"
        )
        return tabManager.addWorkspace(
            title: "shared · \(RemoteRooms.displayName(forSocket: info.room))",
            initialTerminalCommand: command,
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false
        )
    }

    /// Stops a share: kills the tunnel and removes the scoped key line. Idempotent.
    static func stop(_ share: Share) async -> Bool {
        let (dest, identity, port) = sshParams(share.server)
        let script = remoteStopScript(marker: share.marker)
        return await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: script, timeout: 30).ok
        }.value
    }

    // MARK: - Friend invite

    private static func copyFriendInvite(_ share: Share) {
        // Primary invite is the compact clickable link (opens in the friend's remux).
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joinLink(share), forType: .string)
    }

    /// Fallback for friends without remux: a self-contained terminal command.
    static func terminalCommand(_ share: Share) -> String {
        "export REMUX_KEY='\(share.privateKey)'\n\(share.friendCommand)"
    }

    // MARK: - Local keygen

    private static func generateEphemeralKey() -> (privateKey: String, publicLine: String)? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remux-cf-key-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("id_ed25519")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-t", "ed25519", "-N", "", "-q", "-C", "remux-room-share", "-f", keyPath.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let priv = try? String(contentsOf: keyPath, encoding: .utf8),
              let pub = try? String(contentsOf: keyPath.appendingPathExtension("pub"), encoding: .utf8) else {
            return nil
        }
        return (priv, pub.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Remote scripts

    private static func remoteShareScript(socket: String, pubkey: String, marker: String) -> String {
        let sock = shellSingleQuote(socket)
        let pub = shellSingleQuote(pubkey)
        let mark = shellSingleQuote(marker)
        return """
        set -e
        SOCK=\(sock); PUB=\(pub); MARK=\(mark)
        if ! command -v cloudflared >/dev/null 2>&1; then
          ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) A=amd64;; esac
          if ! curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$A" -o /usr/local/bin/cloudflared 2>/dev/null; then echo CLOUDFLARED_INSTALL_FAILED; exit 0; fi
          chmod +x /usr/local/bin/cloudflared || { echo CLOUDFLARED_INSTALL_FAILED; exit 0; }
        fi
        mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 700 "$HOME/.ssh"; chmod 600 "$HOME/.ssh/authorized_keys"
        printf 'command="tmux -L %s new-session -A -s shared",restrict %s %s\\n' "$SOCK" "$PUB" "$MARK" >> "$HOME/.ssh/authorized_keys"
        LOG=$(mktemp /tmp/remux-cf-XXXXXX.log)
        nohup cloudflared tunnel --no-autoupdate --url tcp://localhost:22 > "$LOG" 2>&1 &
        echo $! > "/tmp/remux-cf-$MARK.pid"
        H=""
        for i in $(seq 1 45); do
          H=$(grep -oE 'https://[a-z0-9-]+\\.trycloudflare\\.com' "$LOG" 2>/dev/null | head -1)
          [ -n "$H" ] && break; sleep 1
        done
        echo "CFHOST=$H"
        """
    }

    private static func remoteStopScript(marker: String) -> String {
        let mark = shellSingleQuote(marker)
        return """
        MARK=\(mark)
        if [ -f "/tmp/remux-cf-$MARK.pid" ]; then kill "$(cat /tmp/remux-cf-$MARK.pid)" 2>/dev/null || true; rm -f "/tmp/remux-cf-$MARK.pid"; fi
        if [ -f "$HOME/.ssh/authorized_keys" ]; then
          grep -v "$MARK" "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.remux.tmp" 2>/dev/null || true
          mv "$HOME/.ssh/authorized_keys.remux.tmp" "$HOME/.ssh/authorized_keys" 2>/dev/null || true
          chmod 600 "$HOME/.ssh/authorized_keys"
        fi
        echo STOPPED
        """
    }

    // MARK: - SSH plumbing

    private static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sshParams(_ server: SavedServer) -> (String, String?, Int?) {
        let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (server.sshDestination, (identity?.isEmpty == false) ? identity : nil, server.port)
    }

    private nonisolated static func sshCapture(
        destination: String, identity: String?, port: Int?, remoteCommand: String, timeout: Int
    ) -> (output: String, ok: Bool) {
        var args = ["-o", "ConnectTimeout=\(timeout)", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes"]
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
