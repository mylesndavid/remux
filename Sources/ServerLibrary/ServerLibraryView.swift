import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Termius-style Server Library panel for the right sidebar.
///
/// Lists the user's saved SSH servers grouped by `group`, with a connection
/// status dot, click-to-connect, and add/edit/delete affordances. Binds to the
/// shared `ServerLibraryStore`. A row tap opens a remote workspace through
/// `RemuxServerConnector.connect(to:)`.
///
/// Style mirrors the existing sidebar panels (`SessionIndexView`,
/// `DockEmptyView`): a compact control bar above a scrolling list, SF Symbol
/// affordances, localized strings, and value-snapshot rows so an orthogonal
/// `@Published` change does not thrash the row subtree.
struct ServerLibraryView: View {
    @ObservedObject var store: ServerLibraryStore

    /// Server currently presented for editing, or `nil`. When set, the
    /// add/edit sheet is shown bound to a draft copy of this entry.
    @State private var editingServer: SavedServer?
    /// Whether the "Add Server" sheet is presented for a brand-new entry.
    @State private var isAddingServer = false
    /// Transient notice (import result, tmate stopped, …) shown in an alert.
    @State private var importResult: String?
    /// Server for which the "Host Shared Session" sheet is presented, or `nil`.
    @State private var hostingServer: SavedServer?
    /// Server for which the "Share Beyond Tailnet" (tmate) sheet is presented.
    @State private var tmateServer: SavedServer?
    /// Server for which the remote-sessions browser is presented.
    @State private var sessionsServer: SavedServer?
    /// Whether the "Join Shared Session" sheet is presented.
    @State private var isJoining = false

    init(store: ServerLibraryStore = .shared) {
        self.store = store
    }

    /// Imports `~/.ssh/config` into the library and surfaces the outcome.
    private func runImportSSHConfig() {
        report(added: store.importFromSSHConfig(), source: "~/.ssh/config")
    }

    /// Imports the user's Tailscale tailnet and surfaces the outcome.
    private func runImportTailscale() {
        Task {
            let added = await store.importFromTailscale()
            report(added: added, source: "Tailscale")
        }
    }

    private func report(added: Int, source: String) {
        if added > 0 {
            importResult = String.localizedStringWithFormat(
                String(localized: "serverLibrary.import.added", defaultValue: "Imported %1$d server(s) from %2$@."),
                added, source
            )
        } else {
            importResult = String.localizedStringWithFormat(
                String(localized: "serverLibrary.import.none", defaultValue: "Nothing new to import from %@."),
                source
            )
        }
    }

    /// Import menu shared by the control bar and the empty state.
    @ViewBuilder private var importMenuItems: some View {
        Button {
            runImportSSHConfig()
        } label: {
            Label(
                String(localized: "serverLibrary.import.sshConfig", defaultValue: "From SSH Config (~/.ssh/config)"),
                systemImage: "doc.text"
            )
        }
        Button {
            runImportTailscale()
        } label: {
            Label(
                String(localized: "serverLibrary.import.tailscale", defaultValue: "From Tailscale"),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
        .disabled(!TailscaleDiscovery.isAvailable)
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if store.servers.isEmpty {
                emptyView
            } else {
                serverList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isAddingServer) {
            ServerEditorSheet(server: nil) { newServer in
                store.add(newServer)
            }
        }
        .sheet(item: $editingServer) { server in
            ServerEditorSheet(server: server) { updated in
                store.update(updated)
            }
        }
        .alert(
            String(localized: "serverLibrary.notice.title", defaultValue: "remux"),
            isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )
        ) {
            Button(String(localized: "serverLibrary.import.ok", defaultValue: "OK")) { importResult = nil }
        } message: {
            Text(importResult ?? "")
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 6) {
            Text(String(localized: "serverLibrary.title", defaultValue: "Servers"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer(minLength: 4)

            Button {
                isJoining = true
            } label: {
                Image(systemName: "person.2.wave.2")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(localized: "serverLibrary.join.help", defaultValue: "Join a shared session from an invite link"))
            .accessibilityLabel(String(localized: "serverLibrary.join.accessibilityLabel", defaultValue: "Join shared session"))
            .accessibilityIdentifier("ServerLibrary.joinButton")

            Menu {
                importMenuItems
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.small)
            .help(String(localized: "serverLibrary.import.help", defaultValue: "Import servers from SSH config or Tailscale"))
            .accessibilityLabel(String(localized: "serverLibrary.import.accessibilityLabel", defaultValue: "Import servers"))
            .accessibilityIdentifier("ServerLibrary.importButton")

            Button {
                isAddingServer = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(localized: "serverLibrary.add.help", defaultValue: "Add a server"))
            .accessibilityLabel(String(localized: "serverLibrary.add.accessibilityLabel", defaultValue: "Add Server"))
            .accessibilityIdentifier("ServerLibrary.addButton")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .sheet(item: $hostingServer) { server in
            HostSessionSheet(server: server) { session in
                RemuxCollabSession.host(server: server, session: session, store: store)
            }
        }
        .sheet(isPresented: $isJoining) {
            JoinSessionSheet { link in
                guard let invite = RemuxCollabSession.parseInvite(link) else { return false }
                return RemuxCollabSession.join(invite) != nil
            }
        }
        .sheet(item: $tmateServer) { server in
            TmateHostSheet(server: server)
        }
        .sheet(item: $sessionsServer) { server in
            RemoteSessionsSheet(server: server)
        }
    }

    // MARK: - List

    private var serverList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.grouped(), id: \.group) { section in
                    if let group = section.group, !group.isEmpty {
                        Text(group)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(section.servers) { server in
                        ServerRow(
                            snapshot: ServerRowSnapshot(server: server),
                            actions: rowActions(for: server.id)
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func rowActions(for id: SavedServer.ID) -> ServerRowActions {
        ServerRowActions(
            connect: { [weak store] in
                guard let store, let server = store.server(id: id) else { return }
                RemuxServerConnector.connect(to: server)
            },
            edit: { [weak store] in
                editingServer = store?.server(id: id)
            },
            delete: { [weak store] in
                store?.remove(id: id)
            },
            hostSession: { [weak store] in
                hostingServer = store?.server(id: id)
            },
            shareBeyondTailnet: { [weak store] in
                tmateServer = store?.server(id: id)
            },
            upload: { [weak store] urls in
                guard let store, let server = store.server(id: id) else { return }
                SFTPUpload.upload(localURLs: urls, to: server)
            },
            sessions: { [weak store] in
                sessionsServer = store?.server(id: id)
            },
            browseFiles: { [weak store] in
                if let server = store?.server(id: id) { FileTransferWindow.open(server: server) }
            }
        )
    }

    // MARK: - Empty state

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "serverLibrary.empty.title", defaultValue: "No Saved Servers"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(
                localized: "serverLibrary.empty.subtitle",
                defaultValue: "Add an SSH server to connect with one click."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button {
                    isAddingServer = true
                } label: {
                    Label(
                        String(localized: "serverLibrary.empty.add", defaultValue: "Add Server"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    importMenuItems
                } label: {
                    Label(
                        String(localized: "serverLibrary.empty.import", defaultValue: "Import"),
                        systemImage: "square.and.arrow.down"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row snapshot + actions

/// Immutable value snapshot fed to a `ServerRow`. Keeping the row off the
/// observable store avoids re-rendering every row when an unrelated server
/// mutates (the snapshot-boundary rule used by the Sessions panel).
private struct ServerRowSnapshot: Equatable {
    let id: SavedServer.ID
    let nickname: String
    let destination: String
    let status: ServerConnectionStatus

    init(server: SavedServer) {
        self.id = server.id
        let trimmedNickname = server.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nickname = trimmedNickname.isEmpty ? server.sshDestination : trimmedNickname
        // For alias-resolved servers, show the resolved user@host so the row
        // reveals where the nickname points; otherwise show the destination.
        self.destination = server.displayDetail
        self.status = ServerConnectionStatus(lastConnectedAt: server.lastConnectedAt)
    }
}

/// Closure bundle so the row carries no store reference.
private struct ServerRowActions {
    let connect: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let hostSession: () -> Void
    let shareBeyondTailnet: () -> Void
    let upload: ([URL]) -> Void
    let sessions: () -> Void
    let browseFiles: () -> Void
}

/// Coarse connection signal derived from `lastConnectedAt`. The data layer
/// stamps `lastConnectedAt` on connect but exposes no live per-server session
/// state, so the dot reflects recency rather than a live socket.
private enum ServerConnectionStatus: Equatable {
    /// Connected within the recent window.
    case recent
    /// Connected before, but not recently.
    case stale
    /// Never connected.
    case never

    /// Window within which a connection counts as "recent" for the dot.
    private static let recentWindow: TimeInterval = 60 * 60 // 1 hour

    init(lastConnectedAt: Date?) {
        guard let lastConnectedAt else {
            self = .never
            return
        }
        self = Date().timeIntervalSince(lastConnectedAt) <= Self.recentWindow ? .recent : .stale
    }

    var color: Color {
        switch self {
        case .recent: return .green
        case .stale: return .secondary
        case .never: return .secondary.opacity(0.4)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .recent:
            return String(localized: "serverLibrary.status.recent", defaultValue: "Recently connected")
        case .stale:
            return String(localized: "serverLibrary.status.stale", defaultValue: "Previously connected")
        case .never:
            return String(localized: "serverLibrary.status.never", defaultValue: "Never connected")
        }
    }
}

// MARK: - Row

private struct ServerRow: View {
    let snapshot: ServerRowSnapshot
    let actions: ServerRowActions

    @State private var isHovered = false
    @State private var isDropTargeted = false

    /// Loads file URLs from dropped item providers, then delivers them on main.
    private func loadDroppedURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
        var collected: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); collected.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(collected) }
    }

    var body: some View {
        Button(action: actions.connect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(snapshot.status.color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(snapshot.status.accessibilityLabel)

                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.nickname)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.primary)
                    Text(snapshot.destination)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.20)
                          : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 1.5 : 0)
                    .padding(.horizontal, 6)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(providers) { urls in
                if !urls.isEmpty { actions.upload(urls) }
            }
            return true
        }
        .help(String.localizedStringWithFormat(
            String(localized: "serverLibrary.row.connectHelp", defaultValue: "Connect to %@"),
            snapshot.destination
        ))
        .accessibilityIdentifier("ServerLibrary.row.\(snapshot.id.uuidString)")
        .contextMenu {
            Button {
                actions.connect()
            } label: {
                Label(String(localized: "serverLibrary.row.connect", defaultValue: "Connect"), systemImage: "bolt.horizontal")
            }
            Button {
                actions.sessions()
            } label: {
                Label(String(localized: "serverLibrary.row.sessions", defaultValue: "Sessions… (tmux / tmate)"), systemImage: "list.bullet.rectangle")
            }
            Button {
                actions.browseFiles()
            } label: {
                Label(String(localized: "serverLibrary.row.browseFiles", defaultValue: "Browse Files…"), systemImage: "folder")
            }
            Divider()
            Button {
                actions.hostSession()
            } label: {
                Label(String(localized: "serverLibrary.row.hostSession", defaultValue: "Host Shared Session…"), systemImage: "person.2.wave.2")
            }
            Button {
                actions.shareBeyondTailnet()
            } label: {
                Label(String(localized: "serverLibrary.row.shareWithTmate", defaultValue: "Share with tmate (public relay)…"), systemImage: "globe")
            }
            Button {
                actions.edit()
            } label: {
                Label(String(localized: "serverLibrary.row.edit", defaultValue: "Edit…"), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                actions.delete()
            } label: {
                Label(String(localized: "serverLibrary.row.delete", defaultValue: "Delete"), systemImage: "trash")
            }
        }
    }
}

// MARK: - Add / Edit sheet

/// Form sheet binding to the editable fields of a `SavedServer`. When `server`
/// is `nil` it creates a new entry; otherwise it edits an existing one and
/// preserves the original `id`.
private struct ServerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let existingID: SavedServer.ID?
    /// The original entry when editing, so fields not exposed by this form
    /// (sshOptions, sshConfigAlias, iconName, color, lastConnectedAt) survive a save.
    private let original: SavedServer?
    private let onSave: (SavedServer) -> Void

    @State private var nickname: String
    @State private var host: String
    @State private var username: String
    @State private var portText: String
    @State private var identityFile: String
    @State private var group: String
    @State private var useTailscaleSSH: Bool

    init(server: SavedServer?, onSave: @escaping (SavedServer) -> Void) {
        self.existingID = server?.id
        self.original = server
        self.onSave = onSave
        _nickname = State(initialValue: server?.nickname ?? "")
        _host = State(initialValue: server?.host ?? "")
        _username = State(initialValue: server?.username ?? "")
        _portText = State(initialValue: server?.port.map(String.init) ?? "")
        _identityFile = State(initialValue: server?.identityFile ?? "")
        _group = State(initialValue: server?.group ?? "")
        _useTailscaleSSH = State(initialValue: server?.usesTailscaleSSH ?? false)
    }

    private var isEditing: Bool { existingID != nil }

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing
                ? String(localized: "serverLibrary.editor.editTitle", defaultValue: "Edit Server")
                : String(localized: "serverLibrary.editor.addTitle", defaultValue: "Add Server"))
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 12)

            Form {
                TextField(
                    String(localized: "serverLibrary.editor.nickname", defaultValue: "Nickname"),
                    text: $nickname,
                    prompt: Text(String(localized: "serverLibrary.editor.nicknamePrompt", defaultValue: "Prod web 1"))
                )
                TextField(
                    String(localized: "serverLibrary.editor.host", defaultValue: "Host"),
                    text: $host,
                    prompt: Text(String(localized: "serverLibrary.editor.hostPrompt", defaultValue: "example.com or 10.0.0.1"))
                )
                TextField(
                    String(localized: "serverLibrary.editor.username", defaultValue: "Username"),
                    text: $username,
                    prompt: Text(String(localized: "serverLibrary.editor.usernamePrompt", defaultValue: "root"))
                )
                TextField(
                    String(localized: "serverLibrary.editor.port", defaultValue: "Port"),
                    text: $portText,
                    prompt: Text(String(localized: "serverLibrary.editor.portPrompt", defaultValue: "22"))
                )
                TextField(
                    String(localized: "serverLibrary.editor.identityFile", defaultValue: "Identity File"),
                    text: $identityFile,
                    prompt: Text(String(localized: "serverLibrary.editor.identityFilePrompt", defaultValue: "~/.ssh/id_ed25519"))
                )
                TextField(
                    String(localized: "serverLibrary.editor.group", defaultValue: "Group"),
                    text: $group,
                    prompt: Text(String(localized: "serverLibrary.editor.groupPrompt", defaultValue: "Production"))
                )
                Toggle(isOn: $useTailscaleSSH) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(localized: "serverLibrary.editor.tailscaleSSH", defaultValue: "Connect via Tailscale SSH"))
                        Text(String(localized: "serverLibrary.editor.tailscaleSSHHint", defaultValue: "Keyless — auth rides your tailnet"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!TailscaleDiscovery.isAvailable)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(String(localized: "serverLibrary.editor.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing
                    ? String(localized: "serverLibrary.editor.save", defaultValue: "Save")
                    : String(localized: "serverLibrary.editor.create", defaultValue: "Add")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }

        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdentity = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))

        let server = SavedServer(
            id: existingID ?? UUID(),
            nickname: trimmedNickname.isEmpty ? trimmedHost : trimmedNickname,
            host: trimmedHost,
            username: trimmedUsername.isEmpty ? nil : trimmedUsername,
            port: port,
            identityFile: trimmedIdentity.isEmpty ? nil : trimmedIdentity,
            sshOptions: original?.sshOptions ?? [],
            sshConfigAlias: original?.sshConfigAlias,
            useTailscaleSSH: useTailscaleSSH ? true : nil,
            group: trimmedGroup.isEmpty ? nil : trimmedGroup,
            iconName: original?.iconName,
            color: original?.color,
            lastConnectedAt: original?.lastConnectedAt
        )
        onSave(server)
        dismiss()
    }
}
