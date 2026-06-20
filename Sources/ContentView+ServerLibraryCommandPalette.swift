import AppKit
import CmuxCommandPalette
import Foundation

/// Command-palette provider for the Termius-style Server Library.
///
/// Surfaces a keyboard-first "Connect to Server…" experience: one fuzzy-matchable
/// palette command per saved server (`Connect to <nickname>`), built live from
/// `ServerLibraryStore.shared.servers`. Activating a row hands the entry to
/// `RemuxServerConnector.connect(to:)`, the single connect entry point shared with
/// the Server Library row tap / context-menu "Connect" surfaces.
///
/// These commands are emitted dynamically (not as static
/// `CommandPaletteCommandContribution`s) because the server set changes at runtime
/// and each row needs its own captured `SavedServer`. The integrator appends the
/// result of ``commandPaletteServerLibraryCommands(startingRank:)`` into the
/// dynamic command list built by `commandPaletteCommands(commandsContext:)` — see
/// the one-line registration note at the bottom of this file.
extension ContentView {
    /// Stable prefix for per-server connect command identifiers.
    static let commandPaletteConnectServerCommandIdPrefix = "palette.server.connect."

    /// One `CommandPaletteCommand` per saved server, fuzzy-listed under a shared
    /// "Connect to Server" label.
    ///
    /// - Parameter startingRank: Tie-break rank for the first emitted command;
    ///   subsequent commands increment from it. Pass the caller's running rank so
    ///   these interleave correctly with the rest of the palette.
    /// - Returns: Connect commands ordered most-recently-connected first, then by
    ///   the library's stored order.
    @MainActor
    static func commandPaletteServerLibraryCommands(
        startingRank: Int = 0,
        store: ServerLibraryStore = .shared
    ) -> [CommandPaletteCommand] {
        let servers = commandPaletteServerLibraryOrderedServers(store.servers)
        guard !servers.isEmpty else { return [] }

        let connectLabel = String(
            localized: "commandPalette.server.connect.label",
            defaultValue: "Connect to Server"
        )

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(servers.count)
        var rank = startingRank

        for server in servers {
            let nickname = server.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = nickname.isEmpty ? server.sshDestination : nickname
            let title = String(
                format: String(
                    localized: "commandPalette.server.connect.title",
                    defaultValue: "Connect to %@"
                ),
                displayName
            )

            commands.append(
                CommandPaletteCommand(
                    id: commandPaletteConnectServerCommandId(for: server),
                    rank: rank,
                    title: title,
                    subtitle: connectLabel,
                    shortcutHint: nil,
                    kindLabel: connectLabel,
                    keywords: commandPaletteServerLibraryKeywords(for: server, label: connectLabel),
                    dismissOnRun: true,
                    action: {
                        if RemuxServerConnector.connect(to: server, store: store) == nil {
                            NSSound.beep()
                        }
                    }
                )
            )
            rank += 1
        }

        return commands
    }

    /// Stable command id for a server's connect command.
    static func commandPaletteConnectServerCommandId(for server: SavedServer) -> String {
        "\(commandPaletteConnectServerCommandIdPrefix)\(server.id.uuidString.lowercased())"
    }

    /// Servers ordered most-recently-connected first (entries without a timestamp
    /// keep their stored order, after the recently-connected ones).
    private static func commandPaletteServerLibraryOrderedServers(
        _ servers: [SavedServer]
    ) -> [SavedServer] {
        servers.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastConnectedAt, rhs.element.lastConnectedAt) {
            case let (l?, r?):
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    /// Fuzzy-search keywords for a server's connect command: the connect verb plus
    /// the entry's nickname, host, destination, and group.
    private static func commandPaletteServerLibraryKeywords(
        for server: SavedServer,
        label: String
    ) -> [String] {
        var keywords = ["connect", "ssh", "server", "remote", label]
        let candidates = [
            server.nickname,
            server.host,
            server.sshDestination,
            server.username,
            server.group
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                keywords.append(trimmed)
            }
        }
        return keywords
    }
}

// MARK: - Integrator registration
//
// Append these commands into the dynamic palette list. In
// `commandPaletteCommands(commandsContext:)` (Sources/ContentView.swift), just
// before `return commands`, add:
//
//     commands.append(
//         contentsOf: Self.commandPaletteServerLibraryCommands(startingRank: nextRank)
//     )
//
// No handler-registry or static-contribution changes are required; each command
// carries its own captured action.
