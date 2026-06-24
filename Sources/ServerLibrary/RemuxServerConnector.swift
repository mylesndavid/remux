import AppKit
import Foundation
import CmuxCore

/// Glue between a persisted `SavedServer` and cmux's existing remote-session
/// machinery.
///
/// This is the single entry point the Server Library UI (row tap, context-menu
/// "Connect", etc.) should call. It performs no SSH work of its own: it builds a
/// `WorkspaceRemoteConfiguration` from the saved entry, opens a fresh workspace
/// through the same `TabManager.addWorkspace` path every other workspace-creation
/// flow uses, and hands the configuration to `Workspace.configureRemoteConnection`
/// — the exact method the session-restore and fork paths drive (see
/// `Workspace.swift`). On success it stamps `lastConnectedAt` so the library can
/// sort by most-recently-used.
///
/// Isolation: `@MainActor` because it touches `AppDelegate.shared`, the
/// `TabManager`/`Workspace` UI graph, and `ServerLibraryStore` — all main-actor
/// state. Mirrors `RemoteTmuxController`'s use of `AppDelegate.shared?.tabManager`.
@MainActor
enum RemuxServerConnector {
    /// Opens a new workspace and connects it to `server` over SSH.
    ///
    /// Reuses the established connect path: `TabManager.addWorkspace` to create
    /// the workspace, then `Workspace.configureRemoteConnection(_:autoConnect:)`
    /// with the configuration derived from the saved entry. The workspace title
    /// defaults to the server's nickname so the sidebar reads naturally.
    ///
    /// No-op (returns `nil`) when the app isn't ready (no `AppDelegate.shared` /
    /// `tabManager`), mirroring the guard `RemoteTmuxController.mirrorHost` uses.
    ///
    /// - Parameters:
    ///   - server: The library entry to connect to.
    ///   - store: The library store to stamp `lastConnectedAt` on. Defaults to
    ///     the shared singleton; tests can inject a temporary store.
    ///   - select: Whether to select/focus the new workspace. Defaults to `true`.
    /// - Returns: The newly created `Workspace`, or `nil` if the app graph is not
    ///   yet available.
    @discardableResult
    static func connect(
        to server: SavedServer,
        store: ServerLibraryStore = .shared,
        select: Bool = true
    ) -> Workspace? {
        guard let tabManager = AppDelegate.shared?.tabManager else {
            return nil
        }

        // First connect with no saved login user: ask which user to SSH in as,
        // then remember it on the entry. SSH itself handles auth in the terminal
        // (key → straight in; otherwise its `Password:` prompt appears in the pane).
        var server = server
        if (server.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            guard let entered = promptForUsername(server: server) else {
                return nil // user cancelled
            }
            let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                server.username = trimmed
                store.update(server) // persist so we don't ask again
            }
        }

        // The nickname becomes the tab title.
        let nickname = server.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = nickname.isEmpty ? server.sshDestination : nickname

        // Open a plain interactive SSH terminal (`ssh -t user@host`, or
        // `tailscale ssh` when opted in). This is the robust Termius-style path:
        // it needs no daemon bootstrap on the target, always gets a TTY, and holds
        // the pane open on error so auth prompts / failures are visible. (The
        // heavier `configureRemoteConnection` cmuxd path only suits cmux's own
        // cloud VMs and fails on ordinary servers.)
        let command = RemuxCollabSession.interactiveCommand(server: server)
        let workspace = tabManager.addWorkspace(
            title: title,
            initialTerminalCommand: command,
            inheritWorkingDirectory: false,
            select: select,
            autoWelcomeIfNeeded: false
        )
        // Reuse this command for new tabs (⌘T) so they open another session on
        // the same server instead of a local shell.
        workspace.remuxReconnectCommand = command

        // Record the connection attempt for sort-by-recent. We stamp on initiate
        // (not on a confirmed handshake) because the connector has no async
        // success callback here; this matches "last connected" being the last
        // time the user opened the server.
        store.markConnected(id: server.id)

        return workspace
    }

    /// Prompts for the SSH login user for `server` (shown on first connect when no
    /// user is saved). Returns the entered string, or `nil` if the user cancelled.
    private static func promptForUsername(server: SavedServer) -> String? {
        let alert = NSAlert()
        alert.messageText = String.localizedStringWithFormat(
            String(localized: "serverLibrary.userPrompt.title", defaultValue: "Log in to %@"),
            server.nickname
        )
        alert.informativeText = String(
            localized: "serverLibrary.userPrompt.body",
            defaultValue: "Enter the username to SSH in as. It's saved so you won't be asked again — change it anytime in the server's settings."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "root"
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "serverLibrary.userPrompt.connect", defaultValue: "Connect"))
        alert.addButton(withTitle: String(localized: "serverLibrary.userPrompt.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
