import AppKit
import Foundation

/// Shared **port tunnels** for a Room — so a dev server running in the room
/// (e.g. localhost:3000) becomes a public URL everyone in the room can open in
/// their browser. Each tunnel is a Cloudflare **quick tunnel**
/// (`cloudflared tunnel --url http://localhost:<port>`), ephemeral and killable.
///
/// Discovery is shared: active tunnels are recorded in a per-room state file on
/// the host (`/tmp/remux-tunnels-<socket>.tsv`, lines `port\turl\tpid`), so every
/// room member sees the same tunnel list. Dead PIDs are pruned on read.
///
/// Heads-up: a quick-tunnel URL is public-by-link (anyone with it reaches the
/// service). Fine for ephemeral pairing; killable any time.
@MainActor
enum RemoteTunnels {
    struct Tunnel: Identifiable, Equatable {
        let port: Int
        let url: String
        let pid: Int
        var id: Int { port }
    }

    private static func stateFile(_ socket: String) -> String { "/tmp/remux-tunnels-\(socket).tsv" }

    // MARK: - List

    /// Lists active tunnels for `room` on `server`. `nil` if the host is unreachable.
    static func list(server: SavedServer, room: RemoteRooms.Room) async -> [Tunnel]? {
        let (dest, identity, port) = sshParams(server)
        let f = shellQuote(stateFile(room.socket))
        // Print only lines whose PID is still alive; rewrite the file pruning dead ones.
        let cmd = """
        F=\(f); [ -f "$F" ] || exit 0; TMP=$(mktemp)
        while IFS=$'\\t' read -r p u pid; do
          [ -n "$pid" ] || continue
          if kill -0 "$pid" 2>/dev/null; then printf '%s\\t%s\\t%s\\n' "$p" "$u" "$pid" | tee -a "$TMP"; fi
        done < "$F"
        mv "$TMP" "$F" 2>/dev/null || true
        """
        let result = await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: cmd, timeout: 18)
        }.value
        guard result.ok else { return nil }
        var tunnels: [Tunnel] = []
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let p = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let pid = Int(parts[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let url = parts[1].trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("http") else { continue }
            tunnels.append(Tunnel(port: p, url: url, pid: pid))
        }
        return tunnels.sorted { $0.port < $1.port }
    }

    // MARK: - Expose

    enum ExposeResult: Equatable { case ok(Tunnel); case unreachable; case installFailed; case noURL }

    /// Exposes `port` on the room's host via a Cloudflare quick tunnel.
    static func expose(server: SavedServer, room: RemoteRooms.Room, port: Int) async -> ExposeResult {
        let (dest, identity, sshPort) = sshParams(server)
        let f = shellQuote(stateFile(room.socket))
        let cmd = """
        set -e
        F=\(f); PORT=\(port)
        if ! command -v cloudflared >/dev/null 2>&1; then
          ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) A=amd64;; esac
          if ! curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$A" -o /usr/local/bin/cloudflared 2>/dev/null; then echo CLOUDFLARED_INSTALL_FAILED; exit 0; fi
          chmod +x /usr/local/bin/cloudflared || { echo CLOUDFLARED_INSTALL_FAILED; exit 0; }
        fi
        LOG=$(mktemp /tmp/remux-tun-XXXXXX.log)
        nohup cloudflared tunnel --no-autoupdate --url "http://localhost:$PORT" > "$LOG" 2>&1 &
        PID=$!
        H=""
        for i in $(seq 1 45); do
          H=$(grep -oE 'https://[a-z0-9-]+\\.trycloudflare\\.com' "$LOG" 2>/dev/null | head -1)
          [ -n "$H" ] && break; sleep 1
        done
        if [ -z "$H" ]; then kill "$PID" 2>/dev/null; echo NO_URL; exit 0; fi
        printf '%s\\t%s\\t%s\\n' "$PORT" "$H" "$PID" >> "$F"
        echo "TUNNEL=$PORT|$H|$PID"
        """
        let result = await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: sshPort, remoteCommand: cmd, timeout: 90)
        }.value
        guard result.ok else { return .unreachable }
        if result.output.contains("CLOUDFLARED_INSTALL_FAILED") { return .installFailed }
        for line in result.output.split(separator: "\n") where line.hasPrefix("TUNNEL=") {
            let body = line.dropFirst("TUNNEL=".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if body.count >= 3, let p = Int(body[0]), let pid = Int(body[2]) {
                return .ok(Tunnel(port: p, url: body[1], pid: pid))
            }
        }
        return .noURL
    }

    // MARK: - Stop

    static func stop(server: SavedServer, room: RemoteRooms.Room, tunnel: Tunnel) async -> Bool {
        let (dest, identity, port) = sshParams(server)
        let f = shellQuote(stateFile(room.socket))
        let cmd = """
        F=\(f); PID=\(tunnel.pid)
        kill "$PID" 2>/dev/null || true
        if [ -f "$F" ]; then grep -v $'\\t'"$PID"$ "$F" > "$F.tmp" 2>/dev/null || true; mv "$F.tmp" "$F" 2>/dev/null || true; fi
        echo STOPPED
        """
        return await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: cmd, timeout: 20).ok
        }.value
    }

    /// Opens a tunnel URL in the user's default browser.
    static func open(_ tunnel: Tunnel) {
        guard let url = URL(string: tunnel.url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - SSH plumbing

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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
