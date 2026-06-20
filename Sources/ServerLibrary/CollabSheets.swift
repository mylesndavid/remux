import AppKit
import SwiftUI

/// Sheet to start hosting a shared tmux session on a server, and show the
/// generated `remux://join` invite (auto-copied to the clipboard).
struct HostSessionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: SavedServer
    /// Returns the invite URL after opening the host terminal, or `nil` on failure.
    let onHost: (_ session: String) -> URL?

    @State private var session: String = "pairing"
    @State private var invite: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "collab.host.title", defaultValue: "Host a Shared Session"))
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 4)
            Text(String.localizedStringWithFormat(
                String(localized: "collab.host.subtitle", defaultValue: "Everyone who joins shares one live tmux session on %@."),
                server.nickname
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)

            if let invite {
                Text(String(localized: "collab.host.linkReady", defaultValue: "Invite link (copied to clipboard):"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(invite.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .padding(.bottom, 8)
                if server.usesTailscaleSSH {
                    Label(
                        String(localized: "collab.host.tailnetHint", defaultValue: "On your tailnet they can join directly. For others, share this device in Tailscale (node sharing), then send the link."),
                        systemImage: "person.2.badge.gearshape"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            } else {
                Form {
                    TextField(
                        String(localized: "collab.host.sessionName", defaultValue: "Session name"),
                        text: $session,
                        prompt: Text("pairing")
                    )
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button(String(localized: "collab.host.close", defaultValue: invite == nil ? "Cancel" : "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if invite == nil {
                    Button(String(localized: "collab.host.start", defaultValue: "Host Session")) {
                        invite = onHost(session)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(String(localized: "collab.host.copyAgain", defaultValue: "Copy Link")) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(invite!.absoluteString, forType: .string)
                    }
                }
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Sheet that hosts a "share beyond the tailnet" session via tmate: runs setup on
/// appear, then shows the read-write (pair) and read-only (watch) links.
struct TmateHostSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: SavedServer

    private enum Phase: Equatable {
        case working
        case ready(RemuxTmateHosting.Links)
        case failed(String)
    }
    @State private var phase: Phase = .working

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "tmate.title", defaultValue: "Share with tmate (public relay)"))
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 4)
            Text(String.localizedStringWithFormat(
                String(localized: "tmate.subtitle", defaultValue: "A tmate session on %@ that anyone can join from any terminal — no tailnet needed. Heads up: traffic routes through tmate.io's public relay."),
                server.nickname
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.bottom, 14)

            switch phase {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "tmate.working", defaultValue: "Setting up tmate (installing if needed)… ~30s"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

            case .ready(let links):
                linkRow(
                    title: String(localized: "tmate.pair", defaultValue: "Pair (read-write)"),
                    subtitle: String(localized: "tmate.pair.hint", defaultValue: "They can type in the session with you"),
                    value: links.readWriteSSH,
                    symbol: "person.2.fill"
                )
                linkRow(
                    title: String(localized: "tmate.watch", defaultValue: "Watch only (read-only)"),
                    subtitle: String(localized: "tmate.watch.hint", defaultValue: "They see everything, can't touch your terminal"),
                    value: links.readOnlySSH,
                    symbol: "eye"
                )
                if !links.webReadOnly.isEmpty {
                    linkRow(
                        title: String(localized: "tmate.web", defaultValue: "Watch in a browser"),
                        subtitle: "",
                        value: links.webReadOnly,
                        symbol: "globe"
                    )
                }
                Text(String(localized: "tmate.copied", defaultValue: "The pair link is on your clipboard. Send the matching link to whoever should join."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Text(String(localized: "tmate.failHint", defaultValue: "tmate needs to install on the host. Ensure the server is reachable as a user that can install packages (e.g. root)."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            HStack {
                Spacer()
                Button(String(localized: "tmate.done", defaultValue: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 460)
        .task {
            let result = await RemuxTmateHosting.host(server: server)
            switch result {
            case .success(let links): phase = .ready(links)
            case .failure(.tmateInstallFailed): phase = .failed(String(localized: "tmate.err.install", defaultValue: "Couldn't install tmate on the host."))
            case .failure(.noLinks): phase = .failed(String(localized: "tmate.err.noLinks", defaultValue: "tmate started but returned no links."))
            case .failure(.sshFailed(let m)): phase = .failed(m)
            }
        }
    }

    @ViewBuilder
    private func linkRow(title: String, subtitle: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary).font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "tmate.copy", defaultValue: "Copy"))
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
        .padding(.bottom, 8)
    }
}

/// Sheet to join a shared session from a pasted `remux://join` invite link.
struct JoinSessionSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Returns `true` if the pasted text parsed into a valid invite and a join
    /// was started.
    let onJoin: (_ link: String) -> Bool

    @State private var link: String = ""
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "collab.join.title", defaultValue: "Join a Shared Session"))
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 4)
            Text(String(localized: "collab.join.subtitle", defaultValue: "Paste a remux:// invite link to drop into the same live session."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            Form {
                TextField(
                    String(localized: "collab.join.link", defaultValue: "Invite link"),
                    text: $link,
                    prompt: Text("remux://join?host=…&session=…")
                )
            }
            .formStyle(.grouped)

            if showError {
                Label(
                    String(localized: "collab.join.invalid", defaultValue: "That doesn't look like a remux invite link."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .padding(.top, 4)
            }

            HStack {
                Button(String(localized: "collab.join.paste", defaultValue: "Paste")) {
                    if let s = NSPasteboard.general.string(forType: .string) { link = s }
                }
                .controlSize(.small)
                Spacer()
                Button(String(localized: "collab.join.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "collab.join.go", defaultValue: "Join")) {
                    if onJoin(link) { dismiss() } else { showError = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 380)
    }
}
