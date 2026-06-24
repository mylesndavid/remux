import AppKit
import Foundation

/// "Rooms" — shared, multi-person workspaces on a single host.
///
/// A Room is a **named tmux server** (its own socket, `tmux -L remux-<name>`).
/// Because the socket lives on the host, everyone connected to that host (as the
/// same user, for now) discovers the same Rooms — so it's a shared space, not a
/// per-person one. A Room holds multiple **Sessions** (tmux sessions) that people
/// create, join, and leave; presence = how many clients are attached.
///
/// All remote work is plain SSH (`ssh user@host tmux -L … …`); no daemon on the
/// target. Mirrors `RemoteSessions`' SSH plumbing (BatchMode + ControlMaster, so
/// it reuses the interactive Connect session's auth on password hosts).
@MainActor
enum RemoteRooms {
    /// Socket prefix that marks a tmux server as a remux Room.
    static let socketPrefix = "remux-"

    struct Room: Identifiable, Equatable {
        let name: String          // logical name (socket minus prefix)
        let socket: String        // full socket name, e.g. "remux-incident"
        let sessionCount: Int
        let attachedClients: Int  // total clients attached anywhere in the room
        var id: String { socket }
        var isOccupied: Bool { attachedClients > 0 }
    }

    struct RoomSession: Identifiable, Equatable {
        let name: String
        let windows: Int
        let attached: Int         // clients attached to this session = presence
        var id: String { name }
    }

    static func socketName(for roomName: String) -> String {
        socketPrefix + RemuxCollabSession.sanitizedSessionName(roomName)
    }

    static func displayName(forSocket socket: String) -> String {
        socket.hasPrefix(socketPrefix) ? String(socket.dropFirst(socketPrefix.count)) : socket
    }

    // MARK: - List rooms (discovery via sockets in the tmux tmpdir)

    /// Lists the Rooms on `server`. `nil` if the host couldn't be reached.
    static func listRooms(server: SavedServer) async -> [Room]? {
        let (dest, identity, port) = sshParams(server)
        let result = await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: listRoomsScript)
        }.value
        guard result.ok else { return nil }
        var rooms: [Room] = []
        for line in result.output.split(separator: "\n") {
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 4, p[0] == "ROOM" else { continue }
            let socket = p[1].trimmingCharacters(in: .whitespaces)
            guard socket.hasPrefix(socketPrefix) else { continue }
            rooms.append(Room(
                name: displayName(forSocket: socket),
                socket: socket,
                sessionCount: Int(p[2]) ?? 0,
                attachedClients: Int(p[3]) ?? 0
            ))
        }
        return rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let listRoomsScript: String = """
        DIR="${TMUX_TMPDIR:-/tmp/tmux-$(id -u)}"
        for s in "$DIR"/remux-*; do
          [ -S "$s" ] || continue
          n=$(basename "$s")
          sess=$(tmux -L "$n" list-sessions 2>/dev/null | grep -c .)
          cli=$(tmux -L "$n" list-clients 2>/dev/null | grep -c .)
          printf 'ROOM|%s|%s|%s\\n' "$n" "$sess" "$cli"
        done
        """

    // MARK: - List sessions in a room

    /// Lists the sessions inside `room` on `server`. `nil` if unreachable.
    static func listSessions(server: SavedServer, room: Room) async -> [RoomSession]? {
        let (dest, identity, port) = sshParams(server)
        let socket = RemuxCollabSession.shellQuote(room.socket)
        let cmd = "tmux -L \(socket) list-sessions -F 'S|#{session_name}|#{session_windows}|#{session_attached}' 2>/dev/null"
        let result = await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: cmd)
        }.value
        guard result.ok else { return nil }
        var sessions: [RoomSession] = []
        for line in result.output.split(separator: "\n") {
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 4, p[0] == "S" else { continue }
            let name = p[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            sessions.append(RoomSession(name: name, windows: Int(p[2]) ?? 1, attached: Int(p[3]) ?? 0))
        }
        return sessions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Mutations

    /// Creates a new Room (its first session is named "main"). Returns success.
    static func createRoom(server: SavedServer, name: String) async -> Bool {
        let socket = RemuxCollabSession.shellQuote(socketName(for: name))
        return await run(server, "tmux -L \(socket) new-session -d -s main")
    }

    /// Creates a new session inside `room`. Returns success.
    static func createSession(server: SavedServer, room: Room, name: String) async -> Bool {
        let socket = RemuxCollabSession.shellQuote(room.socket)
        let session = RemuxCollabSession.shellQuote(RemuxCollabSession.sanitizedSessionName(name))
        return await run(server, "tmux -L \(socket) new-session -d -s \(session)")
    }

    /// Kills one session in `room`.
    static func killSession(server: SavedServer, room: Room, session: RoomSession) async -> Bool {
        let socket = RemuxCollabSession.shellQuote(room.socket)
        let name = RemuxCollabSession.shellQuote(session.name)
        return await run(server, "tmux -L \(socket) kill-session -t \(name)")
    }

    /// Tears down the whole Room (all sessions).
    static func closeRoom(server: SavedServer, room: Room) async -> Bool {
        let socket = RemuxCollabSession.shellQuote(room.socket)
        return await run(server, "tmux -L \(socket) kill-server")
    }

    // MARK: - Attach (opens a terminal tab joined to a session in the room)

    @discardableResult
    static func attach(server: SavedServer, room: Room, session: RoomSession) -> Workspace? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        let socket = RemuxCollabSession.shellQuote(room.socket)
        let name = RemuxCollabSession.shellQuote(session.name)
        // attach-or-create: if it was killed out from under us, don't error.
        let remote = "tmux -L \(socket) new-session -A -s \(name)"
        return tabManager.addWorkspace(
            title: "\(room.name) · \(session.name)",
            initialTerminalCommand: RemuxCollabSession.remoteCommandTerminal(server: server, remoteCommand: remote),
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false
        )
    }

    // MARK: - SSH plumbing

    private static func run(_ server: SavedServer, _ remoteCommand: String) async -> Bool {
        let (dest, identity, port) = sshParams(server)
        return await Task.detached(priority: .userInitiated) {
            sshCapture(destination: dest, identity: identity, port: port, remoteCommand: remoteCommand).ok
        }.value
    }

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
