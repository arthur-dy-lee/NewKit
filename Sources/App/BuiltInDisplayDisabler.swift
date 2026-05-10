import AppKit

/// "Disable the built-in display" in the BetterDisplay sense:
///   1. Mirror the built-in panel onto an external display via the *public*
///      `CGConfigureDisplayMirrorOfDisplay` API. While mirrored, the built-in
///      is no longer a separate logical screen, so the cursor cannot wander
///      onto it — that is the user's hard requirement, and we get it from a
///      documented API.
///   2. Drop the built-in panel's brightness to 0 via the private
///      `DisplayServicesSetBrightness` so the LCD is actually dark, not just
///      "showing the same content as the external."
///
/// We resolve the brightness symbol with `dlsym`, so if Apple ever removes
/// `DisplayServices` the app still launches; only the brightness step is
/// skipped (mirroring alone still hides the built-in from the cursor).
///
/// Mirroring is configured with `kCGConfigureForAppOnly`, which tells CoreGraphics
/// to revert the change automatically when our process dies. So a crash or
/// SIGKILL cannot leave the user's built-in display permanently mirrored.
/// Brightness *can* persist across our death, so we additionally write a
/// recovery breadcrumb to UserDefaults and restore on next launch.
///
/// We also refuse to disable when there is no external display (would brick
/// the session), and a CG reconfiguration callback re-enables automatically
/// if the only external is unplugged.
@MainActor
final class BuiltInDisplayDisabler {
    static let shared = BuiltInDisplayDisabler()
    static let didChange = Notification.Name("NewKit.BuiltInDisplayDisablerDidChange")

    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private let setBrightness: SetBrightnessFunc?
    private let getBrightness: GetBrightnessFunc?

    private static let recoveryFlagKey   = "BuiltInDisplayDisabledNeedsRecovery"
    private static let savedBrightnessKey = "BuiltInDisplaySavedBrightness"
    private let defaults = UserDefaults.standard

    private(set) var isBuiltInDisabled = false

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_LAZY)
        self.setBrightness = handle
            .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightnessFunc.self) }
        self.getBrightness = handle
            .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightnessFunc.self) }

        recoverFromCrashIfNeeded()

        let cb: CGDisplayReconfigurationCallBack = { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    BuiltInDisplayDisabler.shared.handleDisplayReconfig()
                }
            }
        }
        CGDisplayRegisterReconfigurationCallback(cb, nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if BuiltInDisplayDisabler.shared.isBuiltInDisabled {
                    _ = BuiltInDisplayDisabler.shared.setDisabled(false)
                }
            }
        }
    }

    var hasBuiltInDisplay: Bool { Self.builtInDisplayID() != nil }

    var hasExternalDisplay: Bool {
        Self.firstExternalActiveDisplay() != nil
    }

    /// Always permits re-enabling. To disable, requires both a built-in panel
    /// and an external display to mirror to.
    var canToggle: Bool {
        if isBuiltInDisabled { return true }
        return hasBuiltInDisplay && hasExternalDisplay
    }

    func toggle() { _ = setDisabled(!isBuiltInDisabled) }

    @discardableResult
    func setDisabled(_ disabled: Bool) -> Bool {
        guard let displayID = Self.builtInDisplayID() else { return false }

        if disabled {
            guard let target = Self.firstExternalActiveDisplay() else {
                Log.error("BuiltInDisplayDisabler: refused — no external display")
                NSSound.beep()
                return false
            }
            // Save brightness and set the breadcrumb *before* changing anything,
            // so a crash mid-call still leaves something to recover from.
            var current: Float = 1.0
            _ = getBrightness?(displayID, &current)
            defaults.set(Double(current), forKey: Self.savedBrightnessKey)
            defaults.set(true, forKey: Self.recoveryFlagKey)

            guard mirror(builtIn: displayID, onto: target) else {
                defaults.removeObject(forKey: Self.recoveryFlagKey)
                defaults.removeObject(forKey: Self.savedBrightnessKey)
                return false
            }
            _ = setBrightness?(displayID, 0.0)
        } else {
            // Restore brightness first so the panel lights up before the
            // cursor can land on it again.
            let saved = defaults.object(forKey: Self.savedBrightnessKey) as? Double ?? 1.0
            _ = setBrightness?(displayID, Float(saved))
            _ = unmirror(builtIn: displayID)
            defaults.removeObject(forKey: Self.recoveryFlagKey)
            defaults.removeObject(forKey: Self.savedBrightnessKey)
        }

        if isBuiltInDisabled != disabled {
            isBuiltInDisabled = disabled
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        return true
    }

    private func handleDisplayReconfig() {
        // Last external got unplugged while built-in was off → bring it back.
        if isBuiltInDisabled, !hasExternalDisplay {
            _ = setDisabled(false)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Restores brightness on next launch if the previous session ended
    /// unexpectedly. Mirroring auto-reverts on process death thanks to
    /// `kCGConfigureForAppOnly`, so we only need to fix brightness here.
    private func recoverFromCrashIfNeeded() {
        guard defaults.bool(forKey: Self.recoveryFlagKey) else { return }
        defaults.removeObject(forKey: Self.recoveryFlagKey)
        let saved = defaults.object(forKey: Self.savedBrightnessKey) as? Double ?? 1.0
        defaults.removeObject(forKey: Self.savedBrightnessKey)
        if let setBrightness, let displayID = Self.builtInDisplayID() {
            _ = setBrightness(displayID, Float(saved))
            Log.info("BuiltInDisplayDisabler: restored built-in brightness after unclean exit")
        }
    }

    // MARK: - CG plumbing

    private func mirror(builtIn: CGDirectDisplayID, onto target: CGDirectDisplayID) -> Bool {
        var configRef: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&configRef)
        guard err == .success, let configRef else { return false }
        err = CGConfigureDisplayMirrorOfDisplay(configRef, builtIn, target)
        guard err == .success else {
            CGCancelDisplayConfiguration(configRef)
            return false
        }
        // forAppOnly = mirroring is automatically undone when our process dies.
        err = CGCompleteDisplayConfiguration(configRef, .forAppOnly)
        return err == .success
    }

    private func unmirror(builtIn: CGDirectDisplayID) -> Bool {
        var configRef: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&configRef)
        guard err == .success, let configRef else { return false }
        err = CGConfigureDisplayMirrorOfDisplay(configRef, builtIn, kCGNullDirectDisplay)
        guard err == .success else {
            CGCancelDisplayConfiguration(configRef)
            return false
        }
        err = CGCompleteDisplayConfiguration(configRef, .forAppOnly)
        return err == .success
    }

    /// Looks at the *online* list (not just active) so the built-in is found
    /// even when it's currently mirrored away.
    private static func builtInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Picks an external display to mirror onto. Prefers the current main
    /// display when it is external; otherwise the first non-built-in active
    /// display we find.
    private static func firstExternalActiveDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let externals = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
        let main = CGMainDisplayID()
        if externals.contains(main) { return main }
        return externals.first
    }
}
