import AppKit

/// Returns an SF Symbol image marked as a template so AppKit re-tints it for
/// the menu's current appearance — black-on-light, white-on-dark — instead of
/// rendering the original symbol bitmap as-is.
///
/// Without `isTemplate = true`, `NSImage(systemSymbolName:)` images stay black
/// in dark-mode menus, which the user perceives as "the icons didn't follow
/// the theme."
@MainActor
enum MenuIcon {
    static func symbol(_ name: String) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        img.isTemplate = true
        return img
    }
}
