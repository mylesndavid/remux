import SwiftUI

/// Shared-workspace ("Rooms") panel for a server: create Rooms, see who's in each
/// session (presence), create/join sessions inside a Room. Rooms are named tmux
/// servers on the host, so everyone connected sees the same Rooms.
struct RoomsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: SavedServer

    @State private var rooms: [RemoteRooms.Room] = []
    @State private var sessionsByRoom: [String: [RemoteRooms.RoomSession]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loading = true
    @State private var reachable = true
    @State private var busy = false
    @State private var newRoomName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.bottom, 4)
            content
            Divider().padding(.top, 4)
            footer
        }
        .padding(16)
        .frame(width: 460, height: 520)
        .task { await reload() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
            Text("Rooms on \(server.nickname)").font(.system(size: 14, weight: .semibold))
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            spacer { ProgressView().controlSize(.small) }
        } else if !reachable {
            spacer {
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text("Couldn't reach this server.").font(.system(size: 12, weight: .medium))
                Text("Connect once (enter its password if asked) and keep that tab open, then Refresh.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { RemuxServerConnector.connect(to: server) } label: {
                    Label("Connect", systemImage: "bolt.horizontal")
                }.controlSize(.small)
            }
        } else if rooms.isEmpty {
            spacer {
                Image(systemName: "rectangle.3.group").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("No rooms yet").font(.system(size: 12, weight: .medium))
                Text("Create a room — a shared space others on this server can join.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rooms) { room in roomRow(room) }
                }
            }
        }
    }

    @ViewBuilder
    private func roomRow(_ room: RemoteRooms.Room) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    toggle(room)
                } label: {
                    Image(systemName: expanded.contains(room.socket) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 10)
                }.buttonStyle(.plain)

                Circle().fill(room.isOccupied ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(room.name).font(.system(size: 12, weight: .medium))
                Text(presenceLabel(people: room.attachedClients, sessions: room.sessionCount))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await addSession(to: room) } } label: {
                    Image(systemName: "plus.circle")
                }.buttonStyle(.borderless).help("New session in this room")
                Button(role: .destructive) { Task { await close(room) } } label: {
                    Image(systemName: "xmark.circle")
                }.buttonStyle(.borderless).help("Close room (ends all its sessions)")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))

            if expanded.contains(room.socket) {
                ForEach(sessionsByRoom[room.socket] ?? []) { session in
                    sessionRow(room, session)
                }
                if (sessionsByRoom[room.socket] ?? []).isEmpty {
                    Text("No sessions").font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.leading, 34).padding(.vertical, 4)
                }
            }
        }
    }

    private func sessionRow(_ room: RemoteRooms.Room, _ session: RemoteRooms.RoomSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(session.attached > 0 ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            Text(session.name).font(.system(size: 12))
            Text(session.attached > 0 ? "\(session.attached) here" : "")
                .font(.system(size: 10)).foregroundStyle(.green)
            Spacer()
            Button {
                RemoteRooms.attach(server: server, room: room, session: session)
                dismiss()
            } label: { Label("Join", systemImage: "bolt.horizontal") }
                .controlSize(.small)
            Button(role: .destructive) {
                Task { busy = true; _ = await RemoteRooms.killSession(server: server, room: room, session: session); await refreshRoom(room); busy = false }
            } label: { Image(systemName: "trash") }
                .controlSize(.small).help("Kill session")
        }
        .padding(.leading, 34).padding(.trailing, 8).padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TextField("New room name", text: $newRoomName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { Task { await createRoom() } }
            Button { Task { await createRoom() } } label: { Label("New Room", systemImage: "plus") }
                .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func spacer<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 8) { c() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presenceLabel(people: Int, sessions: Int) -> String {
        let s = "\(sessions) session\(sessions == 1 ? "" : "s")"
        return people > 0 ? "\(people) here · \(s)" : s
    }

    private func toggle(_ room: RemoteRooms.Room) {
        if expanded.contains(room.socket) { expanded.remove(room.socket) }
        else { expanded.insert(room.socket); Task { await refreshRoom(room) } }
    }

    private func reload() async {
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
        if let sessions = await RemoteRooms.listSessions(server: server, room: room) {
            sessionsByRoom[room.socket] = sessions
        }
    }

    private func createRoom() async {
        let name = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        _ = await RemoteRooms.createRoom(server: server, name: name)
        newRoomName = ""
        await reload()
        busy = false
    }

    private func addSession(to room: RemoteRooms.Room) async {
        busy = true
        let n = (sessionsByRoom[room.socket]?.count ?? room.sessionCount) + 1
        _ = await RemoteRooms.createSession(server: server, room: room, name: "session-\(n)")
        expanded.insert(room.socket)
        await refreshRoom(room)
        await reload()
        busy = false
    }

    private func close(_ room: RemoteRooms.Room) async {
        busy = true
        _ = await RemoteRooms.closeRoom(server: server, room: room)
        await reload()
        busy = false
    }
}
