import AppKit
import SwiftUI

/// Owns the lifetime of the Settings window so it survives close-and-reopen.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingController(rootView: SettingsView(config: Configuration.shared))
        let window = NSWindow(contentViewController: host)
        window.title = L10n.string("settings.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        window.setFrameAutosaveName("NewKitSettings")
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
