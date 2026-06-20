import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens the dual-pane file manager in its own resizable window (Local | Server),
/// Termius-style: browse both sides and drag files across to transfer.
@MainActor
enum FileTransferWindow {
    private static var windows: [NSWindow] = []

    static func open(server: SavedServer) {
        let hosting = NSHostingController(rootView: DualPaneFileBrowser(server: server))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Files — \(server.nickname)"
        window.setContentSize(NSSize(width: 1040, height: 660))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            windows.removeAll { $0 === window }
        }
    }
}

// MARK: - Icon cache (native macOS file-type icons, computed once)

/// Caches `NSWorkspace` file icons so we don't hit Launch Services for every row
/// on every redraw. Remote/local files are keyed by extension (type icon); app
/// bundles and extension-less files key by path (each has its own icon).
@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]
    private static let iconSize = NSSize(width: 16, height: 16)

    static func icon(for item: FileItem, isRemote: Bool, localDirectory: String) -> NSImage {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let key: String
        if item.isDirectory {
            key = "dir"
        } else if isRemote {
            key = "rext:\(ext)"
        } else if ext == "app" || ext.isEmpty {
            key = "lpath:\(LocalFiles.childPath(localDirectory, item.name))"
        } else {
            key = "lext:\(ext)"
        }
        if let cached = cache[key] { return cached }

        let image: NSImage
        if item.isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if isRemote {
            let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(forFile: LocalFiles.childPath(localDirectory, item.name))
        }
        image.size = iconSize
        cache[key] = image
        return image
    }
}

// MARK: - Pane model

@MainActor
final class FilePaneModel: ObservableObject {
    enum Source: Equatable { case local; case remote(SavedServer) }

    let source: Source
    @Published var path: String = ""
    @Published var items: [FileItem] = []
    @Published var loading = false
    @Published var failed = false
    @Published var status: String?

    init(_ source: Source) { self.source = source }

    var isRemote: Bool { if case .remote = source { return true }; return false }
    var server: SavedServer? { if case .remote(let s) = source { return s }; return nil }
    var title: String { isRemote ? (server?.nickname ?? "Server") : "Local" }

    private var listingCache: [String: [FileItem]] = [:]

    func load(path requested: String?) async {
        // Instant: show a cached folder immediately, then refresh quietly behind it.
        if let requested, requested.hasPrefix("/"), let cached = listingCache[requested] {
            path = requested; items = cached; failed = false; loading = false
            await performLoad(path: requested, quiet: true)
            return
        }
        loading = true; failed = false
        await performLoad(path: requested, quiet: false)
        loading = false
    }

    /// Force a fresh fetch of the current directory (keeps showing current items).
    func refresh() async {
        loading = items.isEmpty
        failed = false
        await performLoad(path: path.isEmpty ? nil : path, quiet: false)
        loading = false
    }

    private func performLoad(path requested: String?, quiet: Bool) async {
        switch source {
        case .local:
            let p = requested ?? (path.isEmpty ? LocalFiles.homePath() : path)
            let result = LocalFiles.list(path: p)
            path = result.path; items = result.items
            listingCache[result.path] = result.items
        case .remote(let server):
            if let result = await RemoteFiles.list(server: server, path: requested ?? (path.isEmpty ? nil : path)) {
                path = result.path; items = result.items
                listingCache[result.path] = result.items
            } else if !quiet {
                failed = true
            }
        }
    }

    func navigate(into item: FileItem) async {
        guard item.isDirectory else { return }
        let child = isRemote ? RemoteFiles.childPath(path, item.name) : LocalFiles.childPath(path, item.name)
        await load(path: child)
    }

    func up() async {
        let parent = isRemote ? RemoteFiles.parentPath(path) : LocalFiles.parentPath(path)
        await load(path: parent)
    }
}

// MARK: - Dual pane

struct DualPaneFileBrowser: View {
    let server: SavedServer
    @StateObject private var local = FilePaneModel(.local)
    @StateObject private var remote: FilePaneModel

    init(server: SavedServer) {
        self.server = server
        _remote = StateObject(wrappedValue: FilePaneModel(.remote(server)))
    }

    var body: some View {
        HStack(spacing: 0) {
            FilePaneView(model: local)
            Divider()
            FilePaneView(model: remote)
        }
        .frame(minWidth: 760, minHeight: 380)
        .task {
            await local.load(path: nil)
            await remote.load(path: nil)
        }
    }
}

// MARK: - One pane

struct FilePaneView: View {
    @ObservedObject var model: FilePaneModel
    @State private var dropTargeted = false

    private var dropTypes: [UTType] {
        model.isRemote ? [UTType.fileURL] : [UTType.utf8PlainText, UTType.plainText]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnHeader
            Divider()
            content
            if let status = model.status {
                Divider()
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.10) : Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle().strokeBorder(Color.accentColor, lineWidth: dropTargeted ? 2 : 0)
        )
        .onDrop(of: dropTypes, isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: model.isRemote ? "server.rack" : "desktopcomputer")
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await model.up() } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).help("Up")
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            Text(model.path.isEmpty ? "…" : model.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: 80, alignment: .trailing)
            Text("Modified").frame(width: 130, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.failed {
            VStack(spacing: 8) {
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text("Couldn't list files").font(.system(size: 12, weight: .medium))
                Text("Connect to this server once (it may need a password), then refresh — the browser reuses that session.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)
                if let server = model.server {
                    Button {
                        RemuxServerConnector.connect(to: server)
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal")
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        rowView(item)
                    }
                }
            }
        }
    }

    private func rowView(_ item: FileItem) -> some View {
        Button {
            if item.isDirectory { Task { await model.navigate(into: item) } }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: FileIconCache.icon(for: item, isRemote: model.isRemote, localDirectory: model.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(item.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.sizeDisplay).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Text(item.modified).foregroundStyle(.secondary).frame(width: 130, alignment: .leading).lineLimit(1)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { dragProvider(item) }
    }

    // MARK: - Drag out

    private func dragProvider(_ item: FileItem) -> NSItemProvider {
        if model.isRemote, let server = model.server {
            let payload = "remux-remote:\(server.id.uuidString):\(RemoteFiles.childPath(model.path, item.name))"
            return NSItemProvider(object: payload as NSString)
        }
        let url = URL(fileURLWithPath: LocalFiles.childPath(model.path, item.name))
        return NSItemProvider(object: url as NSURL)
    }

    // MARK: - Drop in

    private func handleDrop(_ providers: [NSItemProvider]) {
        if model.isRemote, let server = model.server {
            loadFileURLs(providers) { urls in
                guard !urls.isEmpty else { return }
                let dir = model.path
                model.status = "Uploading \(urls.count) item(s)…"
                Task {
                    let ok = await SFTPTransfer.upload(localPaths: urls.map { $0.path }, to: server, remoteDirectory: dir)
                    model.status = ok ? nil : "Upload failed (connect to the server first if it needs a password)."
                    await model.refresh()
                }
            }
        } else {
            loadStrings(providers) { payloads in
                let parsed = payloads.compactMap(parseRemotePayload)
                guard let server = parsed.first?.server, !parsed.isEmpty else { return }
                let dir = model.path
                model.status = "Downloading \(parsed.count) item(s)…"
                Task {
                    let ok = await SFTPTransfer.download(remotePaths: parsed.map { $0.path }, from: server, localDirectory: dir)
                    model.status = ok ? nil : "Download failed."
                    await model.refresh()
                }
            }
        }
    }

    private func parseRemotePayload(_ payload: String) -> (server: SavedServer, path: String)? {
        let prefix = "remux-remote:"
        guard payload.hasPrefix(prefix) else { return nil }
        let rest = payload.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let idString = String(rest[..<colon])
        let path = String(rest[rest.index(after: colon)...])
        guard let uuid = UUID(uuidString: idString),
              let server = ServerLibraryStore.shared.server(id: uuid) else { return nil }
        return (server, path)
    }

    private func loadFileURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    private func loadStrings(_ providers: [NSItemProvider], _ completion: @escaping ([String]) -> Void) {
        var strings: [String] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                if let s = value as? String { lock.lock(); strings.append(s); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(strings) }
    }
}
