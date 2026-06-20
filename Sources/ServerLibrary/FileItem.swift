import Foundation

/// One entry in a file pane (local or remote), with the columns the browser
/// shows: name, kind, size, modified.
struct FileItem: Identifiable, Equatable {
    let name: String
    let isDirectory: Bool
    let size: Int64?          // bytes; nil for directories / unknown
    let modified: String      // pre-formatted display string

    var id: String { name }

    var kind: String { isDirectory ? "folder" : (name.contains(".") ? String(name.split(separator: ".").last ?? "file") : "file") }

    var sizeDisplay: String {
        guard let size, !isDirectory else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Local filesystem listing via `FileManager`.
@MainActor
enum LocalFiles {
    static func homePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    static func list(path: String) -> (path: String, items: [FileItem]) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var items: [FileItem] = []
        if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) {
            for child in contents {
                let values = try? child.resourceValues(forKeys: keys)
                let isDir = values?.isDirectory ?? false
                items.append(FileItem(
                    name: child.lastPathComponent,
                    isDirectory: isDir,
                    size: isDir ? nil : Int64(values?.fileSize ?? 0),
                    modified: Self.formatter.string(for: values?.contentModificationDate) ?? ""
                ))
            }
        }
        items.sort(by: FileSort.compare)
        return (url.standardizedFileURL.path, items)
    }

    static func childPath(_ directory: String, _ name: String) -> String {
        URL(fileURLWithPath: directory).appendingPathComponent(name).path
    }

    static func parentPath(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// Shared sort: directories first, then case-insensitive by name.
enum FileSort {
    static func compare(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
