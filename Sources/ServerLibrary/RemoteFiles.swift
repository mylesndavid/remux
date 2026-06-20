import Foundation

/// Remote filesystem browsing over plain SSH. Lists a directory with sizes/dates
/// via `cd <path> && pwd && ls -lAp`, parsed into `FileItem`s. Connection sharing
/// (ControlMaster) lets listing ride the interactive session's auth.
@MainActor
enum RemoteFiles {
    struct Listing: Equatable {
        let path: String        // resolved absolute path
        let items: [FileItem]
    }

    /// Lists `path` on `server` (empty/`nil` → login home). `nil` on SSH failure.
    static func list(server: SavedServer, path: String?) async -> Listing? {
        let (dest, identity, port) = sshParams(server)
        let target = (path?.isEmpty == false) ? path! : "$HOME"
        let cdArg = target == "$HOME" ? "\"$HOME\"" : RemuxCollabSession.shellQuote(target)
        let remote = "cd \(cdArg) && pwd && ls -lAp"

        let (output, ok) = await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: remote)
        }.value
        guard ok else { return nil }

        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let resolved = lines.first?.trimmingCharacters(in: .whitespaces), resolved.hasPrefix("/") else {
            return nil
        }
        lines.removeFirst()

        var items: [FileItem] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            guard let item = parseLine(line) else { continue }
            items.append(item)
        }
        items.sort(by: FileSort.compare)
        return Listing(path: resolved, items: items)
    }

    /// Parses one `ls -lAp` line: `perms links owner group size mon day time name`.
    private static func parseLine(_ line: String) -> FileItem? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 9 else { return nil }
        let perms = fields[0]
        let size = Int64(fields[4])
        let modified = "\(fields[5]) \(fields[6]) \(fields[7])"
        var name = fields[8...].joined(separator: " ")
        // ls -p marks dirs with a trailing slash; perms[0]=='d' also flags dirs.
        let isDir = perms.first == "d" || name.hasSuffix("/")
        if name.hasSuffix("/") { name.removeLast() }
        // Strip symlink "name -> target" to just the link name.
        if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return FileItem(name: name, isDirectory: isDir, size: isDir ? nil : size, modified: modified)
    }

    static func childPath(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    static func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    // MARK: - SSH plumbing

    private static func sshParams(_ server: SavedServer) -> (String, String?, Int?) {
        let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (server.sshDestination, (identity?.isEmpty == false) ? identity : nil, server.port)
    }

    private nonisolated static func sshCapture(
        destination: String, identity: String?, port: Int?, remoteCommand: String
    ) -> (output: String, ok: Bool) {
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
