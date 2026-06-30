import AppKit
import SwiftUI

/// Sheet that shares a Room with a friend over a Cloudflare quick tunnel: runs the
/// setup on appear, shows the copy-paste invite, and offers a one-click Stop that
/// tears everything down (kills the tunnel + removes the scoped key).
struct CloudflareShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: SavedServer
    let roomSocket: String

    private enum Phase: Equatable {
        case working
        case ready(RemuxCloudflareShare.Share)
        case failed(String)
        case stopped
    }
    @State private var phase: Phase = .working
    @State private var stopping = false

    private var roomName: String { RemoteRooms.displayName(forSocket: roomSocket) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Share “\(roomName)” over Cloudflare")
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 4)
            Text("A friend can join this room from anywhere — no tailnet. They get a one-time key scoped to this room only (no shell), and everything is killable.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            switch phase {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Setting up tunnel (installing cloudflared on the box if needed)… ~30–60s")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

            case .ready(let share):
                Label("Invite link copied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                Text("Send this link to your friend. They open it and remux drops them straight into this room — nothing else.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
                Text(RemuxCloudflareShare.joinLink(share))
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .padding(.top, 8)
                HStack {
                    Button { copyLink(share) } label: { Label("Copy Link", systemImage: "link") }
                        .controlSize(.small)
                    Menu {
                        Button { copyTerminalCommand(share) } label: {
                            Label("Copy terminal command (no remux)", systemImage: "terminal")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Other ways to share")
                    Spacer()
                    Button(role: .destructive) { stop(share) } label: {
                        if stopping { ProgressView().controlSize(.small) }
                        else { Label("Stop Sharing", systemImage: "stop.circle") }
                    }
                    .controlSize(.small).disabled(stopping)
                }
                .padding(.top, 10)

            case .failed(let message):
                Label("Couldn't start the share", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
                Text(message.isEmpty ? "The server couldn't be reached or cloudflared couldn't be installed. Connect to the server first if it needs a password." : message)
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)

            case .stopped:
                Label("Stopped. Tunnel killed and the key removed.", systemImage: "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 460)
        .task {
            let result = await RemuxCloudflareShare.share(server: server, roomSocket: roomSocket)
            switch result {
            case .success(let share): phase = .ready(share)
            case .failure(.unreachable(let m)): phase = .failed(m)
            case .failure(.cloudflaredInstallFailed): phase = .failed("Couldn't install cloudflared on the box.")
            case .failure(.noTunnelURL): phase = .failed("The tunnel started but Cloudflare didn't return a hostname.")
            case .failure(.keygenFailed): phase = .failed("Couldn't generate the one-time key locally.")
            }
        }
    }

    private func copyLink(_ share: RemuxCloudflareShare.Share) {
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(RemuxCloudflareShare.joinLink(share), forType: .string)
    }

    private func copyTerminalCommand(_ share: RemuxCloudflareShare.Share) {
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(RemuxCloudflareShare.terminalCommand(share), forType: .string)
    }

    private func stop(_ share: RemuxCloudflareShare.Share) {
        stopping = true
        Task {
            _ = await RemuxCloudflareShare.stop(share)
            stopping = false
            phase = .stopped
        }
    }
}
