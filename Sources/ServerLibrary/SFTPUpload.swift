import AppKit
import Foundation

/// Drag-and-drop file/folder upload to a server over `scp`.
///
/// Dropping local files/folders onto a server row calls `upload(localURLs:to:)`,
/// which asks for the destination directory and opens a terminal running
/// `scp -r … user@host:<dir>` so transfer progress (and any auth prompt) is
/// visible. Recursive by default so whole folders go up.
@MainActor
enum SFTPUpload {
    /// Uploads the dropped local items to `server` after prompting for the remote
    /// destination directory. No-op if cancelled or the app graph isn't ready.
    static func upload(localURLs: [URL], to server: SavedServer) {
        guard !localURLs.isEmpty, AppDelegate.shared?.tabManager != nil else { return }
        guard let remoteDir = promptForRemoteDirectory(server: server, count: localURLs.count) else { return }
        upload(localURLs: localURLs, to: server, remoteDirectory: remoteDir)
    }

    /// Uploads to an explicit remote directory (used by the file browser, which
    /// already knows the destination — no prompt).
    static func upload(localURLs: [URL], to server: SavedServer, remoteDirectory: String) {
        guard !localURLs.isEmpty, let tabManager = AppDelegate.shared?.tabManager else { return }
        let dir = remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = dir.isEmpty ? "~" : dir

        let q = RemuxCollabSession.shellQuote
        var parts = ["scp", "-r"]
        parts += RemuxCollabSession.controlOptionArgs(for: server.sshDestination) // reuse the connected session's auth
        if let port = server.port { parts += ["-P", String(port)] } // scp uses -P (capital)
        if let identity = server.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty {
            parts += ["-i", q(identity)]
        }
        for url in localURLs { parts.append(q(url.path)) }
        // Remote target left unquoted so a leading `~` expands on the remote side
        // (destination is a simple path; the directory prompt avoids spaces).
        parts.append("\(server.sshDestination):\(destination)")

        let command = RemuxCollabSession.holdOnError(parts.joined(separator: " "))
        _ = tabManager.addWorkspace(
            title: "↑ \(server.nickname)",
            initialTerminalCommand: command,
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false
        )
    }

    /// Prompts for the remote destination directory (default `~`).
    private static func promptForRemoteDirectory(server: SavedServer, count: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = String.localizedStringWithFormat(
            String(localized: "sftp.dest.title", defaultValue: "Upload %1$d item(s) to %2$@"),
            count, server.nickname
        )
        alert.informativeText = String(
            localized: "sftp.dest.body",
            defaultValue: "Destination directory on the server (it must already exist)."
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "~"
        field.placeholderString = "~/uploads"
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "sftp.dest.upload", defaultValue: "Upload"))
        alert.addButton(withTitle: String(localized: "sftp.dest.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
