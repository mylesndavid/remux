import AppKit
import SwiftUI

/// Dedicated right-sidebar panel for **Rooms** — shared workspaces on a server.
/// Pick a server, see its rooms with live presence, create/name a room inline,
/// join sessions, and share a room. Stays out of the way like a VS Code panel.
struct RoomsSidebarPanel: View {
    @ObservedObject var store: ServerLibraryStore = .shared

    @State private var selectedServerId: SavedServer.ID?
    @State private var rooms: [RemoteRooms.Room] = []
    @State private var sessionsByRoom: [String: [RemoteRooms.RoomSession]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loading = false
    @State private var reachable = true
    @State private var creating = false
    @State private var newRoomName = ""
    @State private var status: String?
    @State private var cloudflareShareSocket: String?
    @State private var tunnelsByRoom: [String: [RemoteTunnels.Tunnel]] = [:]
    @State private var exposingRoom: String?
    @State private var exposePort = ""
    @State private var showLocalRoom = false

    private var selectedServer: SavedServer? {
        if let id = selectedServerId, let s = store.server(id: id) { return s }
        return store.servers.sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }.first
    }

    var body: some View {
        VStack(spacing: 0) {
            serverBar
            Divider()
            content
            if let status {
                Divider()
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: selectedServer?.id) { await reload() }
        .sheet(isPresented: Binding(
            get: { cloudflareShareSocket != nil },
            set: { if !$0 { cloudflareShareSocket = nil } }
        )) {
            if let socket = cloudflareShareSocket, let server = selectedServer {
                CloudflareShareSheet(server: server, roomSocket: socket)
            }
        }
        .sheet(isPresented: $showLocalRoom) {
            LocalRoomSheet()
        }
    }

    // MARK: - Server selector + create

    private var serverBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(store.servers) { s in
                    Button(s.nickname) { selectedServerId = s.id }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.system(size: 10))
                    Text(selectedServer?.nickname ?? "No server")
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }
            .menuStyle(.borderlessButton).fixedSize()

            Spacer(minLength: 4)

            if loading { ProgressView().controlSize(.small) }
            Button { showLocalRoom = true } label: { Image(systemName: "laptopcomputer") }
                .buttonStyle(.borderless).controlSize(.small).help("Host a room on this Mac")
            Button { creating.toggle() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).controlSize(.small).help("New room")
                .disabled(selectedServer == nil)
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).controlSize(.small).help("Refresh")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if creating { inlineCreateRow }
        }
    }

    private var inlineCreateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Room name", text: $newRoomName)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit { Task { await createRoom() } }
            Button("Create") { Task { await createRoom() } }
                .controlSize(.small)
                .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
        .offset(y: 38)
        .zIndex(1)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if selectedServer == nil {
            placeholder("server.rack", "No servers", "Add a server in the Servers panel, then come back to create a shared room.")
        } else if !reachable {
            VStack(spacing: 8) {
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text("Couldn't reach this server.").font(.system(size: 12, weight: .medium))
                Text("Connect once (enter its password if asked) and keep that tab open, then Refresh.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 16)
                if let server = selectedServer {
                    Button { RemuxServerConnector.connect(to: server) } label: {
                        Label("Connect", systemImage: "bolt.horizontal")
                    }.controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rooms.isEmpty {
            placeholder("rectangle.3.group", "No rooms yet", "Tap + to create a shared room others on this server can join.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rooms) { room in roomRow(room) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func placeholder(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func roomRow(_ room: RemoteRooms.Room) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Button { toggle(room) } label: {
                    Image(systemName: expanded.contains(room.socket) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 10)
                }.buttonStyle(.plain)
                Circle().fill(room.isOccupied ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(room.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(room.attachedClients > 0 ? "\(room.attachedClients)" : "")
                    .font(.system(size: 10)).foregroundStyle(.green)
                Menu {
                    Button { share(room) } label: { Label("Copy room link (same server)", systemImage: "link") }
                    Button { cloudflareShareSocket = room.socket } label: { Label("Share via Cloudflare (public link)", systemImage: "globe") }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Share room")
                Button { Task { await addSession(to: room) } } label: { Image(systemName: "plus.circle").font(.system(size: 11)) }
                    .buttonStyle(.borderless).help("New session")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { toggle(room) }

            if expanded.contains(room.socket) {
                ForEach(sessionsByRoom[room.socket] ?? []) { session in
                    sessionRow(room, session)
                }
                if (sessionsByRoom[room.socket] ?? []).isEmpty {
                    Text("No sessions — tap + to add one").font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.leading, 30).padding(.vertical, 3)
                }
                tunnelsSection(room)
            }
        }
    }

    /// Shared port tunnels for the room — a dev server (localhost:PORT) exposed as
    /// a public URL everyone in the room can open. The pair-programming "see the
    /// website" piece.
    @ViewBuilder
    private func tunnelsSection(_ room: RemoteRooms.Room) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 9)).foregroundStyle(.secondary)
            Text("TUNNELS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Button {
                exposingRoom = (exposingRoom == room.socket) ? nil : room.socket
            } label: { Image(systemName: "plus").font(.system(size: 9)) }
                .buttonStyle(.borderless).help("Expose a port (dev server)")
        }
        .padding(.leading, 30).padding(.trailing, 10).padding(.top, 4).padding(.bottom, 1)

        ForEach(tunnelsByRoom[room.socket] ?? []) { tunnel in
            HStack(spacing: 6) {
                Text(":\(tunnel.port)").font(.system(size: 11, weight: .medium, design: .monospaced))
                Text(tunnel.url.replacingOccurrences(of: "https://", with: ""))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button { RemoteTunnels.open(tunnel) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("Open in browser")
                Button(role: .destructive) {
                    Task { _ = await RemoteTunnels.stop(server: selectedServer!, room: room, tunnel: tunnel); await refreshRoom(room) }
                } label: { Image(systemName: "stop.circle").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("Stop tunnel")
            }
            .padding(.leading, 38).padding(.trailing, 10).padding(.vertical, 2)
        }

        if exposingRoom == room.socket {
            HStack(spacing: 6) {
                Text("localhost:").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                TextField("3000", text: $exposePort)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(width: 64)
                    .onSubmit { Task { await exposePortIn(room) } }
                Button("Expose") { Task { await exposePortIn(room) } }
                    .controlSize(.small)
                    .disabled(Int(exposePort.trimmingCharacters(in: .whitespaces)) == nil)
            }
            .padding(.leading, 38).padding(.trailing, 10).padding(.vertical, 3)
        }
    }

    private func sessionRow(_ room: RemoteRooms.Room, _ session: RemoteRooms.RoomSession) -> some View {
        HStack(spacing: 7) {
            Circle().fill(session.attached > 0 ? Color.green : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            Text(session.name).font(.system(size: 12)).lineLimit(1)
            if session.attached > 0 {
                Text("\(session.attached) here").font(.system(size: 9)).foregroundStyle(.green)
            }
            Spacer(minLength: 4)
            Button { RemoteRooms.attach(server: selectedServer!, room: room, session: session) } label: {
                Text("Join").font(.system(size: 11))
            }.buttonStyle(.borderless).help("Join this session")
        }
        .padding(.leading, 30).padding(.trailing, 10).padding(.vertical, 3)
        .contextMenu {
            Button(role: .destructive) {
                Task { _ = await RemoteRooms.killSession(server: selectedServer!, room: room, session: session); await refreshRoom(room) }
            } label: { Label("Kill session", systemImage: "trash") }
        }
    }

    // MARK: - Actions

    private func toggle(_ room: RemoteRooms.Room) {
        if expanded.contains(room.socket) { expanded.remove(room.socket) }
        else { expanded.insert(room.socket); Task { await refreshRoom(room) } }
    }

    private func reload() async {
        guard let server = selectedServer else { rooms = []; return }
        loading = true
        if let result = await RemoteRooms.listRooms(server: server) {
            rooms = result; reachable = true
            for room in result where expanded.contains(room.socket) { await refreshRoom(room) }
        } else {
            rooms = []; reachable = false
        }
        loading = false
    }

    private func refreshRoom(_ room: RemoteRooms.Room) async {
        guard let server = selectedServer else { return }
        if let sessions = await RemoteRooms.listSessions(server: server, room: room) {
            sessionsByRoom[room.socket] = sessions
        }
        if let tunnels = await RemoteTunnels.list(server: server, room: room) {
            tunnelsByRoom[room.socket] = tunnels
        }
    }

    private func exposePortIn(_ room: RemoteRooms.Room) async {
        guard let server = selectedServer,
              let port = Int(exposePort.trimmingCharacters(in: .whitespaces)) else { return }
        exposePort = ""; exposingRoom = nil
        setStatus("Exposing localhost:\(port)…")
        switch await RemoteTunnels.expose(server: server, room: room, port: port) {
        case .ok(let t): setStatus("Tunnel up for :\(port)"); RemoteTunnels.open(t)
        case .unreachable: setStatus("Couldn't reach the server — connect first if it needs a password.")
        case .installFailed: setStatus("Couldn't install cloudflared on the box.")
        case .noURL: setStatus("Tunnel started but Cloudflare returned no URL.")
        }
        await refreshRoom(room)
    }

    private func createRoom() async {
        guard let server = selectedServer else { return }
        let name = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        loading = true
        let ok = await RemoteRooms.createRoom(server: server, name: name)
        newRoomName = ""; creating = false
        setStatus(ok ? "Created room “\(name)”" : "Couldn't create the room — connect to the server first if it needs a password.")
        await reload()
        loading = false
    }

    private func addSession(to room: RemoteRooms.Room) async {
        guard let server = selectedServer else { return }
        let n = (sessionsByRoom[room.socket]?.count ?? room.sessionCount) + 1
        _ = await RemoteRooms.createSession(server: server, room: room, name: "session-\(n)")
        expanded.insert(room.socket)
        await refreshRoom(room)
        await reload()
    }

    private func share(_ room: RemoteRooms.Room) {
        guard let server = selectedServer else { return }
        var c = URLComponents()
        c.scheme = "remux"; c.host = "room"
        c.queryItems = [.init(name: "host", value: server.sshDestination), .init(name: "room", value: room.socket)]
        let link = c.url?.absoluteString ?? "remux://room?host=\(server.sshDestination)&room=\(room.socket)"
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(link, forType: .string)
        setStatus("Link copied. Anyone connected to \(server.nickname) (same login) can open this room.")
    }

    private func setStatus(_ text: String) {
        status = text
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if status == text { status = nil }
        }
    }
}
