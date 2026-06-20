import Foundation

/// Background (non-terminal) `scp` transfers for the dual-pane file manager, so
/// dragging files between panes just works inline instead of opening a terminal.
/// Uses BatchMode + ControlMaster, so it rides the interactive Connect session's
/// auth (connect once first for password-only hosts).
@MainActor
enum SFTPTransfer {
    /// Uploads local paths into `remoteDirectory` on `server`.
    static func upload(localPaths: [String], to server: SavedServer, remoteDirectory: String) async -> Bool {
        guard !localPaths.isEmpty else { return false }
        var args = baseArgs(server)
        args.append(contentsOf: localPaths)
        args.append("\(server.sshDestination):\(remoteDirectory)")
        return await run(args)
    }

    /// Downloads remote paths on `server` into `localDirectory`.
    static func download(remotePaths: [String], from server: SavedServer, localDirectory: String) async -> Bool {
        guard !remotePaths.isEmpty else { return false }
        var args = baseArgs(server)
        for path in remotePaths { args.append("\(server.sshDestination):\(path)") }
        args.append(localDirectory)
        return await run(args)
    }

    private static func baseArgs(_ server: SavedServer) -> [String] {
        var args = ["-r", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=20"]
        args += RemuxCollabSession.controlOptionArgs(for: server.sshDestination)
        if let port = server.port { args += ["-P", String(port)] } // scp: -P (capital)
        if let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty {
            args += ["-i", identity]
        }
        return args
    }

    private static func run(_ args: [String]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}
