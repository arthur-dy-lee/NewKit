import AppKit

/// User-selectable interface appearance. `system` lets macOS pick (and follow
/// the user's automatic light/dark schedule); the other two pin a theme.
enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.string("appearance.system")
        case .light:  return L10n.string("appearance.light")
        case .dark:   return L10n.string("appearance.dark")
        }
    }

    /// Maps to the `NSAppearance` value assigned to `NSApp.appearance`.
    /// `nil` means "follow the system" — assigning nil restores the default.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the appearance globally. Affects the preferences window, status
    /// bar menu, floating panel, dialogs and any other AppKit chrome.
    @MainActor
    static func apply(_ value: AppAppearance) {
        NSApp.appearance = value.nsAppearance
    }
}
