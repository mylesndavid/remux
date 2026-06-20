import SwiftUI

/// Lists the tmux + tmate sessions on a server with Attach and Kill actions —
/// "join a server, see its sessions, pop into one," plus cleanup so no stray
/// tmate session is left running.
struct RemoteSessionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: SavedServer

    @State private var sessions: [RemoteSessions.Session] = []
    @State private var loading = true
    @State private var reachable = true
    @State private var busy: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(String.localizedStringWithFormat(
                    String(localized: "sessions.title", defaultValue: "Sessions on %@"),
                    server.nickname
                ))
                .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "sessions.refresh", defaultValue: "Refresh"))
            }
            .padding(.bottom, 12)

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "sessions.loading", defaultValue: "Listing sessions…"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else if !reachable {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "sessions.unreachable", defaultValue: "Couldn't reach this server."), systemImage: "lock")
                        .font(.system(size: 12, weight: .medium))
                    Text(String(localized: "sessions.unreachableHint", defaultValue: "Connect once (enter its password if asked) and keep that tab open, then Refresh — the list reuses that authenticated connection."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Button {
                        RemuxServerConnector.connect(to: server)
                    } label: {
                        Label(String(localized: "sessions.connect", defaultValue: "Connect"), systemImage: "bolt.horizontal")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .padding(.vertical, 12)
            } else if sessions.isEmpty {
                Text(String(localized: "sessions.empty", defaultValue: "No tmux or tmate sessions running on this server."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sessions) { session in
                            row(session)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack {
                Spacer()
                Button(String(localized: "sessions.done", defaultValue: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 460)
        .task { await reload() }
    }

    @ViewBuilder
    private func row(_ session: RemoteSessions.Session) -> some View {
        HStack(spacing: 8) {
            Text(session.kind.rawValue.uppercased())
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(
                    session.kind == .tmate ? Color.orange.opacity(0.22) : Color.blue.opacity(0.18)))

            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(String.localizedStringWithFormat(
                    String(localized: "sessions.meta", defaultValue: "%1$d window(s)%2$@"),
                    session.windows,
                    session.attached ? " · " + String(localized: "sessions.attached", defaultValue: "attached") : ""
                ))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Spacer()

            if busy.contains(session.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    RemoteSessions.attach(server: server, session: session)
                    dismiss()
                } label: {
                    Label(String(localized: "sessions.attach", defaultValue: "Attach"), systemImage: "bolt.horizontal")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    kill(session)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help(String(localized: "sessions.kill", defaultValue: "Kill session"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func reload() async {
        loading = true
        if let result = await RemoteSessions.list(server: server) {
            sessions = result; reachable = true
        } else {
            sessions = []; reachable = false
        }
        loading = false
    }

    private func kill(_ session: RemoteSessions.Session) {
        busy.insert(session.id)
        Task {
            _ = await RemoteSessions.kill(server: server, session: session)
            busy.remove(session.id)
            await reload()
        }
    }
}
