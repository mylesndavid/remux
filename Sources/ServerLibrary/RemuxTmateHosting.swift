import AppKit
import Foundation

/// "Share beyond the tailnet" hosting via [tmate](https://tmate.io): sets up a
/// tmate session on a server (installing tmate if missing), captures the public
/// share links, attaches the host's terminal, and copies the read-write link.
///
/// tmate gives a **read-write** link (pair — type together) and a **read-only**
/// link (watch — see everything, can't touch the terminal), plus web URLs. The
/// read-only link is the "be there and watch without interrupting" mode. Sharing
/// works for anyone, anywhere — no tailnet, public IP, or port-forwarding — via
/// tmate's relay servers.
@MainActor
enum RemuxTmateHosting {
    /// The four share links tmate produces for a session.
    struct Links: Equatable {
        let readWriteSSH: String
        let readOnlySSH: String
        let web: String
        let webReadOnly: String
    }

    enum Failure: Error, Equatable {
        case sshFailed(String)
        case tmateInstallFailed
        case noLinks
    }

    /// Fixed per-host socket so re-hosting reuses/replaces one session.
    static let socketPath = "/tmp/remux-tmate.sock"

    /// Sets up tmate on `server`, captures links, attaches the host terminal, and
    /// copies the read-write link to the clipboard. The setup SSH runs off the
    /// main actor (install + relay handshake can take ~30s).
    static func host(server: SavedServer, store: ServerLibraryStore = .shared) async -> Result<Links, Failure> {
        let destination = server.sshDestination
        let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = server.port

        let result = await Task.detached(priority: .userInitiated) {
            runSetup(
                destination: destination,
                identity: (identity?.isEmpty == false) ? identity : nil,
                port: port
            )
        }.value

        guard case .success(let links) = result else { return result }

        // Attach the host's own terminal to the freshly created tmate session.
        if let tabManager = AppDelegate.shared?.tabManager {
            _ = tabManager.addWorkspace(
                title: "\(server.nickname) · tmate",
                initialTerminalCommand: RemuxCollabSession.remoteCommandTerminal(
                    server: server,
                    remoteCommand: "tmate -S \(socketPath) attach"
                ),
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false
            )
            store.markConnected(id: server.id)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(links.readWriteSSH, forType: .string)
        return .success(links)
    }

    /// Stops the tmate session on `server` (`tmate kill-server`). Best-effort;
    /// returns `true` if the SSH command exited cleanly. Runs off the main actor.
    static func stop(server: SavedServer) async -> Bool {
        let destination = server.sshDestination
        let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = server.port
        return await Task.detached(priority: .userInitiated) {
            var args = ["-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes"]
            if let identity, !identity.isEmpty { args += ["-i", identity] }
            if let port { args += ["-p", String(port)] }
            args.append(destination)
            args.append("tmate -S \(socketPath) kill-server")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    // MARK: - Background setup

    private nonisolated static func runSetup(destination: String, identity: String?, port: Int?) -> Result<Links, Failure> {
        var args = ["-o", "ConnectTimeout=25", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes"]
        if let identity { args += ["-i", identity] }
        if let port { args += ["-p", String(port)] }
        args.append(destination)
        args.append(remoteScript)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(.sshFailed("\(error)"))
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: outData, encoding: .utf8) ?? ""
        if text.contains("TMATE_INSTALL_FAILED") { return .failure(.tmateInstallFailed) }

        func field(_ key: String) -> String? {
            for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
                return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        guard let readWrite = field("RW_SSH"), !readWrite.isEmpty,
              let readOnly = field("RO_SSH"), !readOnly.isEmpty else {
            if process.terminationStatus != 0 {
                let errText = String(data: errData, encoding: .utf8) ?? ""
                return .failure(.sshFailed(errText.isEmpty ? "ssh exit \(process.terminationStatus)" : errText))
            }
            return .failure(.noLinks)
        }

        return .success(Links(
            readWriteSSH: readWrite,
            readOnlySSH: readOnly,
            web: field("WEB") ?? "",
            webReadOnly: field("WEB_RO") ?? ""
        ))
    }

    /// Remote shell script: ensure tmate is installed (across common package
    /// managers), start a detached session, and print the share links. Kept free
    /// of shell line-continuations so it survives being passed as one SSH arg.
    private nonisolated static var remoteScript: String {
        """
        set -e
        SOCK=/tmp/remux-tmate.sock
        if ! command -v tmate >/dev/null 2>&1; then if { apt-get update -y && apt-get install -y tmate; } >/dev/null 2>&1; then :; elif dnf install -y tmate >/dev/null 2>&1; then :; elif yum install -y tmate >/dev/null 2>&1; then :; elif apk add tmate >/dev/null 2>&1; then :; elif brew install tmate >/dev/null 2>&1; then :; else echo TMATE_INSTALL_FAILED; exit 0; fi; fi
        tmate -S "$SOCK" kill-server >/dev/null 2>&1 || true
        tmate -S "$SOCK" new-session -d
        tmate -S "$SOCK" wait tmate-ready
        printf 'RW_SSH=%s\\n' "$(tmate -S "$SOCK" display -p '#{tmate_ssh}')"
        printf 'RO_SSH=%s\\n' "$(tmate -S "$SOCK" display -p '#{tmate_ssh_ro}')"
        printf 'WEB=%s\\n' "$(tmate -S "$SOCK" display -p '#{tmate_web}')"
        printf 'WEB_RO=%s\\n' "$(tmate -S "$SOCK" display -p '#{tmate_web_ro}')"
        """
    }
}
