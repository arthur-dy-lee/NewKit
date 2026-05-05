import ApplicationServices
import AppKit

enum AccessibilityHelper {
    /// Whether NewKit currently has Accessibility permission.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Returns trust state and, if not trusted, opens the system prompt.
    @discardableResult
    static func requestTrustWithPrompt() -> Bool {
        // Avoid the shared-mutable-global symbol; pass the documented key string directly.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Privacy & Security → Accessibility pane.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
