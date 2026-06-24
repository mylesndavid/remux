import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        case "servers":
            return .servers
        case "rooms":
            return .rooms
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    static func availableModes(feedEnabled: Bool, dockEnabled: Bool) -> [RightSidebarMode] {
        allCases.filter { $0.isAvailable(feedEnabled: feedEnabled, dockEnabled: dockEnabled) }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    func isAvailable(feedEnabled: Bool, dockEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .sessions, .servers:
            return true
        case .rooms:
            // Rooms lives in the LEFT sidebar as a collapsible section, not as a
            // right-sidebar mode tab. Keep the case (other switches reference it)
            // but never surface it in the right mode bar.
            return false
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        }
    }
}
