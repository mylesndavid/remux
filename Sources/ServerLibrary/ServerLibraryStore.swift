import Foundation
import Combine

/// File-backed, observable store for the Termius-style Server Library.
///
/// Holds the user's saved SSH servers in memory (`servers`), persists them as a
/// single JSON document under `Application Support/cmux/`, and exposes CRUD plus
/// grouping helpers for the library UI. Persistence mirrors the
/// `SessionSnapshotRepository` conventions: `JSONEncoder` with `.sortedKeys`,
/// atomic writes, an identical-content skip, and `createDirectory(...,
/// withIntermediateDirectories: true)` before each save.
///
/// Isolation: `@MainActor` because it is an `ObservableObject` whose `@Published`
/// state drives SwiftUI. Mutations save synchronously on the main actor; the
/// document is small (a handful of small records) so this stays cheap. Use the
/// `shared` singleton from UI code; tests can construct an instance with an
/// explicit `fileURL`.
@MainActor
public final class ServerLibraryStore: ObservableObject {
    /// Shared instance for app/UI access. Loads from disk on first touch.
    public static let shared = ServerLibraryStore()

    /// The saved servers, ordered as they should appear in the library.
    @Published public private(set) var servers: [SavedServer] = []

    private let fileURL: URL?
    // Justification: FileManager is documented thread-safe; Foundation does not
    // mark it Sendable. Confined to the main actor here regardless.
    private let fileManager: FileManager

    /// Current persisted schema version. Bump when the on-disk shape changes.
    public static let schemaVersion = 1

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - fileURL: Overrides the default Application Support location (tests
    ///     pass a temporary file). When `nil`, the default location is derived
    ///     from `bundleIdentifier`.
    ///   - bundleIdentifier: Bundle id used to derive the default file name.
    ///     Falls back to `com.cmuxterm.app` when nil or blank.
    ///   - fileManager: File system access, injected for testability.
    ///   - autoload: When `true` (default), loads persisted servers immediately.
    public init(
        fileURL: URL? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default,
        autoload: Bool = true
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(
            bundleIdentifier: bundleIdentifier,
            fileManager: fileManager
        )
        if autoload {
            load()
        }
    }

    // MARK: - CRUD

    /// Appends a new server and persists.
    public func add(_ server: SavedServer) {
        servers.append(server)
        save()
    }

    /// Replaces the server with the same `id` (no-op if absent) and persists.
    public func update(_ server: SavedServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        save()
    }

    /// Removes the server with the given id and persists.
    public func remove(id: SavedServer.ID) {
        let before = servers.count
        servers.removeAll { $0.id == id }
        if servers.count != before { save() }
    }

    /// Removes the given server and persists.
    public func remove(_ server: SavedServer) {
        remove(id: server.id)
    }

    /// Removes servers at the given offsets (SwiftUI `onDelete`) and persists.
    public func remove(atOffsets offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        servers.remove(atOffsets: offsets)
        save()
    }

    /// Reorders servers (SwiftUI `onMove`) and persists.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Imports servers from an OpenSSH client config (default `~/.ssh/config`),
    /// appending only entries not already present. Dedupes against existing
    /// `sshConfigAlias` values (case-insensitive) and, failing that, the SSH
    /// destination string. Persists once if anything new was added.
    ///
    /// - Returns: the number of newly added servers (0 if none / config absent).
    @discardableResult
    public func importFromSSHConfig(at url: URL? = nil) -> Int {
        mergeImported(SSHConfigParser.parse(configURL: url))
    }

    /// Imports devices from the user's Tailscale tailnet (`tailscale status`),
    /// appending only entries not already present. Discovery shells out to the
    /// `tailscale` CLI on a background task so the UI stays responsive.
    ///
    /// - Returns: the number of newly added servers (0 if none / Tailscale absent).
    @discardableResult
    public func importFromTailscale() async -> Int {
        let discovered = await Task.detached(priority: .userInitiated) {
            TailscaleDiscovery.discoverDevices()
        }.value
        return mergeImported(discovered)
    }

    /// Appends the imported servers not already present, deduping against
    /// existing `sshConfigAlias` values (case-insensitive) and SSH destinations.
    /// Persists once if anything was added. Returns the number added.
    @discardableResult
    private func mergeImported(_ imported: [SavedServer]) -> Int {
        guard !imported.isEmpty else { return 0 }

        var existingAliases = Set(servers.compactMap { $0.resolvedSSHConfigAlias?.lowercased() })
        var existingDestinations = Set(servers.map { $0.sshDestination.lowercased() })

        var additions: [SavedServer] = []
        for server in imported {
            if let alias = server.resolvedSSHConfigAlias?.lowercased() {
                if existingAliases.contains(alias) { continue }
                existingAliases.insert(alias)
            }
            let destination = server.sshDestination.lowercased()
            if existingDestinations.contains(destination) { continue }
            existingDestinations.insert(destination)
            additions.append(server)
        }

        guard !additions.isEmpty else { return 0 }
        servers.append(contentsOf: additions)
        save()
        return additions.count
    }

    /// Stamps `lastConnectedAt` to now for the given server id and persists.
    /// Call this when a connection to the server succeeds.
    public func markConnected(id: SavedServer.ID, at date: Date = Date()) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].lastConnectedAt = date
        save()
    }

    /// The server with the given id, if present.
    public func server(id: SavedServer.ID) -> SavedServer? {
        servers.first { $0.id == id }
    }

    /// The saved server whose SSH destination matches `destination`, if any.
    /// Used to map a live remote workspace's configuration back to its library
    /// entry at session-snapshot capture time. Comparison is case-insensitive on
    /// the trimmed `user@host`/`host` destination string.
    public func server(matchingDestination destination: String) -> SavedServer? {
        let needle = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return servers.first { $0.sshDestination.lowercased() == needle }
    }

    // MARK: - Grouping

    /// Servers bucketed by `group`, preserving the in-list order within each
    /// bucket. Ungrouped servers use `nil` as the key.
    public func grouped() -> [(group: String?, servers: [SavedServer])] {
        var order: [String?] = []
        var buckets: [String?: [SavedServer]] = [:]
        for server in servers {
            let key = server.group
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(server)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// The distinct group names present in the library, in first-seen order.
    public var groupNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for case let group? in servers.map(\.group) where !seen.contains(group) {
            seen.insert(group)
            result.append(group)
        }
        return result
    }

    // MARK: - Persistence

    /// Loads servers from disk, replacing in-memory state. Silently keeps the
    /// current state on any read/decode/version-mismatch failure.
    public func load() {
        guard let fileURL,
              fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(ServerLibraryDocument.self, from: data),
              document.version == Self.schemaVersion else {
            return
        }
        servers = document.servers
    }

    /// Persists the current servers to disk atomically. Returns `false` on
    /// failure (no path resolvable, encode error, or write error).
    @discardableResult
    public func save() -> Bool {
        guard let fileURL else { return false }
        let document = ServerLibraryDocument(version: Self.schemaVersion, servers: servers)
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(document)
            if let existing = try? Data(contentsOf: fileURL), existing == data {
                return true
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - File location

    private static func defaultFileURL(
        bundleIdentifier: String?,
        fileManager: FileManager
    ) -> URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("server-library-\(safeBundleId).json", isDirectory: false)
    }
}

/// On-disk envelope: a schema version plus the server list. Keeping the version
/// out of `SavedServer` lets the record shape evolve independently.
private struct ServerLibraryDocument: Codable {
    let version: Int
    let servers: [SavedServer]
}
