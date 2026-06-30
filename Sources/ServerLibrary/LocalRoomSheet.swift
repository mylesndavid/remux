import AppKit
import SwiftUI

/// "Host on this Mac" — pair-program from your own machine with no Remote Login.
/// Shares a terminal via tmate (outbound link) and exposes local dev-server ports
/// via Cloudflare quick tunnels (outbound URLs). Everything killable.
struct LocalRoomSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var folder: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var links: LocalRoom.Links?
    @State private var starting = false
    @State private var errorText: String?
    @State private var tunnels: [LocalRoom.Tunnel] = []
    @State private var portText = ""
    @State private var exposing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Host a Room on This Mac").font(.system(size: 14, weight: .semibold))
            Text("Pair from your own machine — no Remote Login. The terminal shares over tmate; dev servers share over Cloudflare. Both outbound, nothing inbound.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2).padding(.bottom, 12)

            if !LocalRoom.isReady {
                Label("tmate isn't installed", systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text("Install it first (Homebrew): `brew install tmate`. The website/port sharing below works without it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2).padding(.bottom, 8)
            }

            // Terminal share
            Text("SHARED TERMINAL").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            if let links {
                linkRow("Pair (read-write)", links.readWrite, "person.2.fill")
                linkRow("Watch only", links.readOnly, "eye")
                Button(role: .destructive) { Task { await LocalRoom.stopTerminalShare(); self.links = nil } } label: {
                    Label("Stop terminal share", systemImage: "stop.circle")
                }.controlSize(.small).padding(.top, 4)
            } else {
                HStack(spacing: 6) {
                    Text(folder).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseFolder() }.controlSize(.small)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button { Task { await startShare() } } label: {
                    if starting { ProgressView().controlSize(.small) } else { Label("Start sharing this folder", systemImage: "play.circle") }
                }
                .controlSize(.small).padding(.top, 6).disabled(starting || !LocalRoom.isReady)
            }
            if let errorText { Text(errorText).font(.system(size: 10)).foregroundStyle(.red).padding(.top, 4) }

            Divider().padding(.vertical, 12)

            // Tunnels
            HStack {
                Text("DEV SERVERS / PORTS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(tunnels) { t in
                HStack(spacing: 6) {
                    Text(":\(t.port)").font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(t.url.replacingOccurrences(of: "https://", with: "")).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { LocalRoom.open(t) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).help("Open")
                    Button(role: .destructive) { Task { await LocalRoom.stopTunnel(t); tunnels = LocalRoom.listTunnels() } } label: { Image(systemName: "stop.circle") }.buttonStyle(.borderless).help("Stop")
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 6) {
                Text("localhost:").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                TextField("3000", text: $portText).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(width: 64)
                    .onSubmit { Task { await expose() } }
                Button { Task { await expose() } } label: {
                    if exposing { ProgressView().controlSize(.small) } else { Text("Expose") }
                }
                .controlSize(.small).disabled(exposing || Int(portText.trimmingCharacters(in: .whitespaces)) == nil || LocalRoom.cloudflaredPath() == nil)
            }
            .padding(.top, 4)

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(.top, 14)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { tunnels = LocalRoom.listTunnels() }
    }

    private func linkRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { let pb = NSPasteboard.general; pb.clearContents(); pb.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }.buttonStyle(.borderless).help("Copy")
            }
            Text(value).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
        .padding(.bottom, 6)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func startShare() async {
        starting = true; errorText = nil
        switch await LocalRoom.startTerminalShare(folder: folder) {
        case .success(let l):
            links = l
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(l.readWrite, forType: .string)
        case .failure(.noTmate): errorText = "tmate isn't installed (brew install tmate)."
        case .failure(.tmateFailed(let m)): errorText = "tmate failed: \(m.prefix(120))"
        case .failure: errorText = "Couldn't start the terminal share."
        }
        starting = false
    }

    private func expose() async {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        exposing = true; portText = ""
        switch await LocalRoom.exposePort(port) {
        case .success(let t): tunnels = LocalRoom.listTunnels(); LocalRoom.open(t)
        case .failure: errorText = "Couldn't expose :\(port)."
        }
        exposing = false
    }
}
