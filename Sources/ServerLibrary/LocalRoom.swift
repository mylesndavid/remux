import AppKit
import Foundation

/// Host a pair-programming room on **this Mac** — no Remote Login, nothing
/// inbound. Both halves are outbound:
/// - **Shared terminal** via `tmate` (dials out to a relay; friend joins by link).
/// - **Dev servers / website** via local `cloudflared` quick tunnels (outbound;
///   public URL anyone opens).
///
/// Everything is killable: tmate `kill-server`, tunnels tracked by PID in a local
/// state file (`/tmp/remux-local-tunnels.tsv`).
@MainActor
enum LocalRoom {
    static let tmateSocket = "/tmp/remux-local-tmate.sock"
    static let tunnelState = "/tmp/remux-local-tunnels.tsv"

    struct Links: Equatable {
        let readWrite: String   // tmate ssh (pair)
        let readOnly: String    // tmate ssh -r (watch)
        let webReadOnly: String // browser watch URL
    }

    struct Tunnel: Identifiable, Equatable {
        let port: Int
        let url: String
        let pid: Int
        var id: Int { port }
    }

    enum Failure: Error, Equatable { case noTmate; case tmateFailed(String); case noURL; case noCloudflared }

    // MARK: - Tooling

    static func tmatePath() -> String? {
        ["/opt/homebrew/bin/tmate", "/usr/local/bin/tmate", (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/tmate")]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func cloudflaredPath() -> String? { RemuxCollabSession.cloudflaredBinary() }

    static var isReady: Bool { tmatePath() != nil }

    // MARK: - Terminal share (tmate)

    /// Starts a local tmate session in `folder`, attaches a terminal tab to it,
    /// and returns the join links. Re-runnable (kills any prior local session).
    static func startTerminalShare(folder: String) async -> Result<Links, Failure> {
        guard let tmate = tmatePath() else { return .failure(.noTmate) }
        let result = await Task.detached(priority: .userInitiated) {
            runShell(tmateStartScript(tmate: tmate, folder: folder))
        }.value
        func field(_ k: String) -> String? {
            for line in result.split(separator: "\n") where line.hasPrefix("\(k)=") {
                return String(line.dropFirst(k.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        guard let rw = field("RW"), !rw.isEmpty, let ro = field("RO"), !ro.isEmpty else {
            return .failure(.tmateFailed(result))
        }
        // Attach the host's own terminal to the local tmate session.
        if let tabManager = AppDelegate.shared?.tabManager {
            _ = tabManager.addWorkspace(
                title: "This Mac · pair",
                initialTerminalCommand: RemuxCollabSession.holdOnError("\(shellQuote(tmate)) -S \(shellQuote(tmateSocket)) attach"),
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false
            )
        }
        return .success(Links(readWrite: rw, readOnly: ro, webReadOnly: field("WEBRO") ?? ""))
    }

    static func stopTerminalShare() async {
        guard let tmate = tmatePath() else { return }
        _ = await Task.detached(priority: .userInitiated) {
            runShell("\(shellQuote(tmate)) -S \(shellQuote(tmateSocket)) kill-server 2>/dev/null || true; echo done")
        }.value
    }

    private nonisolated static func tmateStartScript(tmate: String, folder: String) -> String {
        let t = shellQuote(tmate); let s = shellQuote(tmateSocket); let f = shellQuote(folder)
        return """
        \(t) -S \(s) kill-server 2>/dev/null || true
        \(t) -S \(s) new-session -d -c \(f)
        \(t) -S \(s) wait tmate-ready
        printf 'RW=%s\\n' "$(\(t) -S \(s) display -p '#{tmate_ssh}')"
        printf 'RO=%s\\n' "$(\(t) -S \(s) display -p '#{tmate_ssh_ro}')"
        printf 'WEBRO=%s\\n' "$(\(t) -S \(s) display -p '#{tmate_web_ro}')"
        """
    }

    // MARK: - Port tunnels (local cloudflared)

    static func listTunnels() -> [Tunnel] {
        guard FileManager.default.fileExists(atPath: tunnelState) else { return [] }
        let out = runShell("""
        TMP=$(mktemp)
        while IFS=$'\\t' read -r p u pid; do
          [ -n "$pid" ] || continue
          if kill -0 "$pid" 2>/dev/null; then printf '%s\\t%s\\t%s\\n' "$p" "$u" "$pid" | tee -a "$TMP"; fi
        done < \(shellQuote(tunnelState))
        mv "$TMP" \(shellQuote(tunnelState)) 2>/dev/null || true
        """)
        var tunnels: [Tunnel] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let p = Int(parts[0]), let pid = Int(parts[2]), parts[1].hasPrefix("http") else { continue }
            tunnels.append(Tunnel(port: p, url: parts[1], pid: pid))
        }
        return tunnels.sorted { $0.port < $1.port }
    }

    static func exposePort(_ port: Int) async -> Result<Tunnel, Failure> {
        guard let cf = cloudflaredPath() else { return .failure(.noCloudflared) }
        let out = await Task.detached(priority: .userInitiated) {
            runShell("""
            LOG=$(mktemp /tmp/remux-ltun-XXXXXX.log)
            nohup \(shellQuote(cf)) tunnel --no-autoupdate --url "http://localhost:\(port)" > "$LOG" 2>&1 &
            PID=$!
            H=""
            for i in $(seq 1 45); do
              H=$(grep -oE 'https://[a-z0-9-]+\\.trycloudflare\\.com' "$LOG" 2>/dev/null | head -1)
              [ -n "$H" ] && break; sleep 1
            done
            if [ -z "$H" ]; then kill "$PID" 2>/dev/null; echo NO_URL; exit 0; fi
            printf '%s\\t%s\\t%s\\n' "\(port)" "$H" "$PID" >> \(shellQuote(tunnelState))
            echo "TUNNEL=\(port)|$H|$PID"
            """)
        }.value
        for line in out.split(separator: "\n") where line.hasPrefix("TUNNEL=") {
            let b = line.dropFirst("TUNNEL=".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if b.count >= 3, let p = Int(b[0]), let pid = Int(b[2]) { return .success(Tunnel(port: p, url: b[1], pid: pid)) }
        }
        return .failure(.noURL)
    }

    static func stopTunnel(_ tunnel: Tunnel) async {
        _ = await Task.detached(priority: .userInitiated) {
            runShell("""
            kill \(tunnel.pid) 2>/dev/null || true
            if [ -f \(shellQuote(tunnelState)) ]; then grep -v $'\\t'\(tunnel.pid)$ \(shellQuote(tunnelState)) > \(shellQuote(tunnelState)).tmp 2>/dev/null || true; mv \(shellQuote(tunnelState)).tmp \(shellQuote(tunnelState)) 2>/dev/null || true; fi
            echo done
            """)
        }.value
    }

    static func open(_ tunnel: Tunnel) {
        if let url = URL(string: tunnel.url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Shell

    private nonisolated static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private nonisolated static func runShell(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
