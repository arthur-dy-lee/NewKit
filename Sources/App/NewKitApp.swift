import AppKit
import KeyboardShortcuts

@main
final class NewKitAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var configObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.purgeOldLogs()
        statusBar = StatusBarController()
        registerGlobalShortcuts()
        ServicesProvider.register()
        URLSchemeHandler.register()
        PendingCommandWatcher.shared.start()
        if AccessibilityHelper.isTrusted {
            RightClickMonitor.shared.start()
        }
        ScrollInverter.shared.apply()
        SleepGuard.shared.apply()
        AppAppearance.apply(Configuration.shared.appearance)
        configObserver = NotificationCenter.default.addObserver(
            forName: Configuration.didChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ScrollInverter.shared.apply()
                SleepGuard.shared.apply()
                AppAppearance.apply(Configuration.shared.appearance)
            }
        }
        OnboardingWindowController.shared.showIfNeeded()

        // If the user has hidden the menu bar icon and dismissed onboarding,
        // open Preferences on launch so there's an obvious way back in.
        if !Configuration.shared.showMenuBarIcon
            && UserDefaults.standard.bool(forKey: "didShowOnboarding_v1") {
            SettingsWindowController.shared.show()
        }
    }

    /// Called when the user re-opens the app (e.g. double-clicks it in Finder while it's running).
    /// Show Preferences — there's no main window, so this is the natural reopen UX.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    private func registerGlobalShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleFloatingPanel) {
            FloatingPanelController.shared.toggle()
        }
    }
}
