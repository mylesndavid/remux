import Foundation
import CmuxCore

/// A persisted SSH server entry in the Termius-style Server Library.
///
/// This is a pure value type: `Codable` for JSON persistence (the
/// `ServerLibraryStore` encodes with `.sortedKeys` and atomic writes, mirroring
/// the session-snapshot repository convention), `Identifiable` for SwiftUI list
/// rendering, and `Sendable` so it can cross actor boundaries freely.
///
/// `host` is the bare hostname or IP; `username` is optional and, when present,
/// is folded into the SSH destination (`user@host`). Everything needed to start
/// a connection is captured here so the UI can hand a `WorkspaceRemoteConfiguration`
/// straight to the existing remote-workspace machinery.
public struct SavedServer: Codable, Identifiable, Sendable, Equatable, Hashable {
    /// Stable identity for persistence and SwiftUI diffing.
    public let id: UUID
    /// User-facing display name (e.g. "Prod web 1").
    public var nickname: String
    /// Bare hostname or IP address (no `user@`, no port).
    public var host: String
    /// Optional login user; folded into the SSH destination when present.
    public var username: String?
    /// Explicit SSH port, when the server is not on 22.
    public var port: Int?
    /// Explicit identity file path (`~/.ssh/id_ed25519`, etc.).
    public var identityFile: String?
    /// Extra `-o` SSH options applied to connections to this server.
    public var sshOptions: [String]
    /// When set, this server resolves through `~/.ssh/config` under this `Host`
    /// alias: the connection uses the bare alias as the SSH destination and lets
    /// OpenSSH resolve HostName/User/Port/IdentityFile/ProxyJump from the config.
    /// Populated when importing from `~/.ssh/config`. `host`/`username`/`port` are
    /// still captured for display, but the alias takes precedence for the actual
    /// connection so advanced config directives are honored ("connect by nickname").
    public var sshConfigAlias: String?
    /// When `true`, connect via `tailscale ssh <dest>` instead of plain `ssh` —
    /// authentication rides the tailnet (no SSH keys), and Tailscale handles
    /// NAT traversal. Set automatically for servers imported from Tailscale.
    /// Optional for Codable forward/backward compatibility (`nil` == off).
    public var useTailscaleSSH: Bool?
    /// When `true`, connect through a Cloudflare Tunnel by injecting
    /// `ProxyCommand=cloudflared access ssh --hostname %h` — reaches hosts behind
    /// Cloudflare Access (no public IP), authenticated by your Zero Trust policy.
    /// Optional for Codable compatibility (`nil` == off).
    public var useCloudflared: Bool?
    /// Optional grouping/folder name for the library sidebar.
    public var group: String?
    /// Optional SF Symbol / asset name for the row icon.
    public var iconName: String?
    /// Optional hex/asset color token for the row accent.
    public var color: String?
    /// Timestamp of the most recent successful connection, for sort-by-recent.
    public var lastConnectedAt: Date?

    /// Creates a saved server. `id` defaults to a fresh UUID so callers
    /// constructing a brand-new entry do not have to mint one.
    public init(
        id: UUID = UUID(),
        nickname: String,
        host: String,
        username: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        sshOptions: [String] = [],
        sshConfigAlias: String? = nil,
        useTailscaleSSH: Bool? = nil,
        useCloudflared: Bool? = nil,
        group: String? = nil,
        iconName: String? = nil,
        color: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.nickname = nickname
        self.host = host
        self.username = username
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.sshConfigAlias = sshConfigAlias
        self.useTailscaleSSH = useTailscaleSSH
        self.useCloudflared = useCloudflared
        self.group = group
        self.iconName = iconName
        self.color = color
        self.lastConnectedAt = lastConnectedAt
    }

    /// The trimmed `~/.ssh/config` alias when this server resolves through the
    /// config (non-empty `sshConfigAlias`), else `nil`.
    public var resolvedSSHConfigAlias: String? {
        guard let alias = sshConfigAlias?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty else { return nil }
        return alias
    }

    /// The SSH destination string. When the server resolves through `~/.ssh/config`
    /// (`sshConfigAlias` set), this is the bare alias so OpenSSH does the lookup.
    /// Otherwise it is `user@host` (or `host` when no username), trimmed.
    public var sshDestination: String {
        if let alias = resolvedSSHConfigAlias {
            return alias
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let username = username?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty else {
            return trimmedHost
        }
        return "\(username)@\(trimmedHost)"
    }

    /// A human-readable detail line for the row subtitle. For alias-resolved
    /// servers, shows the resolved `user@host`/`host` (or just the alias when the
    /// config only carried the alias) so the row still reveals where it points.
    public var displayDetail: String {
        guard resolvedSSHConfigAlias != nil else { return sshDestination }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty { return sshDestination }
        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return "\(username)@\(trimmedHost)"
        }
        return trimmedHost
    }

    /// Whether this server connects via Tailscale SSH (`nil` == off).
    public var usesTailscaleSSH: Bool { useTailscaleSSH ?? false }

    /// Whether this server connects through a Cloudflare Tunnel (`nil` == off).
    public var usesCloudflared: Bool { useCloudflared ?? false }

    /// The shell command that opens this server in a terminal via Tailscale SSH:
    /// `<tailscale> ssh <dest>`. `tailscaleBinary` is the resolved CLI path
    /// (single-quoted in case it lives in an app bundle with spaces).
    public func tailscaleSSHCommand(tailscaleBinary: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "\(q(tailscaleBinary)) ssh \(q(sshDestination))"
    }

    /// Builds a `WorkspaceRemoteConfiguration` for an SSH connection to this server.
    ///
    /// Maps the library entry onto the existing remote-workspace config used by the
    /// rest of cmux. When the server resolves through `~/.ssh/config`, the explicit
    /// port/identity are left unset so OpenSSH's config directives win; otherwise the
    /// captured SSH-identity fields are used. Relay/daemon wiring stays at defaults.
    public func makeRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        let usesConfig = resolvedSSHConfigAlias != nil
        return WorkspaceRemoteConfiguration(
            transport: .ssh,
            destination: sshDestination,
            port: usesConfig ? nil : port,
            identityFile: usesConfig ? nil : identityFile,
            sshOptions: sshOptions,
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
    }
}
