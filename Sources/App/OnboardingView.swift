import SwiftUI

/// Shown automatically the first time NewKit launches. Walks the user through:
///   1. Granting Accessibility (for Control + Right-click).
///   2. Enabling the Finder extension (for the toolbar icon).
struct OnboardingView: View {
    @State private var step = 0
    let onClose: () -> Void
    @State private var trusted = AccessibilityHelper.isTrusted
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(L10n.string("onboarding.title")).font(.title.bold())

            Group {
                switch step {
                case 0: welcomeStep
                case 1: accessibilityStep
                case 2: finderExtensionStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step > 0 {
                    Button(L10n.string("common.back")) { step -= 1 }
                }
                Spacer()
                if step < 3 {
                    Button(L10n.string("common.next")) { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.string("common.done"), action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540, height: 440)
        .onReceive(timer) { _ in trusted = AccessibilityHelper.isTrusted }
    }

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            Text(L10n.string("onboarding.welcome.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.string("onboarding.feature.menubar"),  systemImage: "menubar.rectangle")
                Label(L10n.string("onboarding.feature.shortcut"), systemImage: "command")
                Label(L10n.string("onboarding.feature.rightclick"), systemImage: "cursorarrow.click.2")
                Label(L10n.string("onboarding.feature.toolbar"), systemImage: "macwindow")
            }
            .padding()
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 14) {
            Text(L10n.string("onboarding.acc.title")).font(.headline)
            Text(L10n.string("onboarding.acc.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? .green : .orange)
                Text(trusted
                     ? L10n.string("perm.acc.granted")
                     : L10n.string("perm.acc.missing"))
            }
            HStack {
                Button(L10n.string("perm.acc.request")) {
                    _ = AccessibilityHelper.requestTrustWithPrompt()
                }
                Button(L10n.string("perm.acc.opensettings")) {
                    AccessibilityHelper.openSystemSettings()
                }
            }
        }
    }

    private var finderExtensionStep: some View {
        VStack(spacing: 14) {
            Text(L10n.string("onboarding.ext.title")).font(.headline)
            Text(L10n.string("onboarding.ext.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button(L10n.string("onboarding.ext.open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extensionPointID:com.apple.FinderSync") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40)).foregroundStyle(.green)
            Text(L10n.string("onboarding.done.title")).font(.headline)
            Text(L10n.string("onboarding.done.body"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private static let didShowKey = "didShowOnboarding_v1"

    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didShowKey) else { return }
        showAlways()
    }

    func showAlways() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: OnboardingView { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.didShowKey)
            self?.window?.close()
            self?.window = nil
        })
        let window = NSWindow(contentViewController: host)
        window.title = L10n.string("onboarding.window.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
