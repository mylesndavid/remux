import Foundation

/// Discovers devices on the user's Tailscale tailnet for the Server Library
/// "Import from Tailscale" action.
///
/// Shells out to the `tailscale` CLI (`tailscale status --json`) and maps each
/// real, addressable peer to a `SavedServer` whose `host` is the device's
/// MagicDNS name (e.g. `agentos.tailnet.ts.net`) — so connecting works anywhere
/// the tailnet is up, with NAT traversal handled by Tailscale. Infra nodes with
/// no MagicDNS name / no CGNAT IPv4 (funnel ingress, subnet routers) are skipped.
///
/// Runs synchronously and is `nonisolated` so callers invoke it off the main
/// actor (the store wraps it in a detached task). Returns `[]` when the CLI is
/// absent, the daemon is unreachable, or the output cannot be parsed — import is
/// best-effort and never throws into the UI.
public enum TailscaleDiscovery {
    /// Candidate locations for the `tailscale` CLI. The GUI app bundles a CLI
    /// binary that accepts the same arguments as the standalone tool.
    private static let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// The resolved `tailscale` binary path, or `nil` if none is present.
    public static func locateBinary(fileManager: FileManager = .default) -> String? {
        candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Whether Tailscale appears available (CLI present). Used to decide whether
    /// to surface the "Import from Tailscale" affordance.
    public static var isAvailable: Bool { locateBinary() != nil }

    /// Enumerates tailnet devices as importable servers. Best-effort; `[]` on any
    /// failure. Safe to call off the main thread.
    public static func discoverDevices() -> [SavedServer] {
        guard let binary = locateBinary() else { return [] }
        guard let data = runStatusJSON(binary: binary) else { return [] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }

        var nodes: [[String: Any]] = []
        // Skip Self (this machine — not a useful SSH target from itself).
        if let peerMap = root["Peer"] as? [String: Any] {
            for value in peerMap.values {
                if let node = value as? [String: Any] { nodes.append(node) }
            }
        }

        var servers: [SavedServer] = []
        var seenHosts = Set<String>()
        // Stable order: by hostname.
        let mapped = nodes.compactMap { savedServer(from: $0) }
        for server in mapped.sorted(by: { $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending }) {
            let key = server.host.lowercased()
            guard !key.isEmpty, !seenHosts.contains(key) else { continue }
            seenHosts.insert(key)
            servers.append(server)
        }
        return servers
    }

    // MARK: - Internals

    private static func runStatusJSON(binary: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json", "--peers"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        // `tailscale status --json` returns promptly; read to EOF then wait.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    /// OS values that cannot be SSH targets and are excluded from discovery.
    private static let nonSSHOperatingSystems: Set<String> = ["ios", "ipados", "android", "tvos"]

    /// Maps one tailnet node dictionary to a `SavedServer`, or `nil` if it is not
    /// a usable SSH target (no MagicDNS name and no CGNAT IPv4, or a non-SSH OS
    /// like iOS/Android).
    private static func savedServer(from node: [String: Any]) -> SavedServer? {
        let os = ((node["OS"] as? String) ?? "").lowercased()
        guard !nonSSHOperatingSystems.contains(os) else { return nil }

        let dnsName = ((node["DNSName"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let ipv4 = (node["TailscaleIPs"] as? [String])?.first { $0.hasPrefix("100.") }
        // Prefer the readable MagicDNS name; fall back to the CGNAT IPv4.
        let host = dnsName.isEmpty ? (ipv4 ?? "") : dnsName
        guard !host.isEmpty else { return nil }

        // Nickname: device HostName, unless it's empty or a useless "localhost"
        // (common on phones/tablets), in which case use the MagicDNS first label.
        let hostName = ((node["HostName"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let firstLabel = dnsName.split(separator: ".").first.map(String.init) ?? host
        let nickname = (hostName.isEmpty || hostName.lowercased() == "localhost") ? firstLabel : hostName

        // Best-effort default login user: Linux tailnet boxes almost always want
        // `root` (Tailscale SSH rejects an unknown local user); the user's own
        // Macs map to this machine's login name. Editable per server afterward.
        let username: String?
        switch os {
        case "linux": username = "root"
        case "macos": username = NSUserName()
        default: username = nil
        }

        return SavedServer(
            nickname: nickname,
            host: host,
            username: username,
            port: nil,
            identityFile: nil,
            group: "Tailnet"
        )
    }
}
