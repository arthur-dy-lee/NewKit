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
    /// Apple Silicon-friendly variant. When present, prefer it over
    /// `DisplayServicesSetBrightness` because it skips the gamma-curved
    /// animation that loses the race against the OS's own brightness write
    /// during lid-open / wake.
    private let setLinearBrightness: SetBrightnessFunc?

    private static let recoveryFlagKey   = "BuiltInDisplayDisabledNeedsRecovery"
    private static let savedBrightnessKey = "BuiltInDisplaySavedBrightness"
    private let defaults = UserDefaults.standard

    private(set) var isBuiltInDisabled = false

    /// True between `willSleepNotification` and `didWakeNotification`. While
    /// set, display reconfig callbacks fired by the sleep transition (the
    /// external panel briefly drops out of the active list) must NOT cause us
    /// to auto re-enable the built-in — otherwise on wake we'd come back with
    /// the LCD lit even though the external is still plugged in.
    private var isSystemSleeping = false
    /// Snapshot of `isBuiltInDisabled` taken at `willSleepNotification`, so we
    /// can re-apply the mirror+brightness=0 on wake if the OS tore it down.
    private var wasDisabledBeforeSleep = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// Coalesces bursts of CG reconfig callbacks (lid open in clamshell mode
    /// fires many in a row). We only act after the burst settles, so our
    /// `CGConfigureDisplayMirrorOfDisplay` call doesn't race the OS's own
    /// reconfiguration and get immediately undone.
    private var pendingReconfigWork: DispatchWorkItem?
    /// Apple Silicon's `DisplayServicesSetBrightness` is animated, and the OS
    /// itself rewrites brightness during lid-open / wake. A single 0-write
    /// loses the race and the LCD flashes. Instead we pin brightness=0 by
    /// rewriting it on a tick for `pinDeadline` seconds after any trigger.
    private var brightnessPinDeadline: Date = .distantPast
    private var brightnessPinScheduled = false

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_LAZY)
        self.setBrightness = handle
            .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightnessFunc.self) }
        self.getBrightness = handle
            .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightnessFunc.self) }
        self.setLinearBrightness = handle
            .flatMap { dlsym($0, "DisplayServicesSetLinearBrightness") }
            .map { unsafeBitCast($0, to: SetBrightnessFunc.self) }
        Log.info("BuiltInDisplayDisabler: symbols set=\(setBrightness != nil) get=\(getBrightness != nil) linear=\(setLinearBrightness != nil)")

        recoverFromCrashIfNeeded()

        let cb: CGDisplayReconfigurationCallBack = { display, flags, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    BuiltInDisplayDisabler.shared.handleDisplayReconfig(display: display, flags: flags)
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

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BuiltInDisplayDisabler.shared.handleWillSleep()
            }
        }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BuiltInDisplayDisabler.shared.handleDidWake()
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
            _ = (setLinearBrightness ?? setBrightness)?(displayID, 0.0)
        } else {
            let saved = defaults.object(forKey: Self.savedBrightnessKey) as? Double ?? 1.0
            _ = (setLinearBrightness ?? setBrightness)?(displayID, Float(saved))
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

    private func handleDisplayReconfig(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        Log.info("BuiltInDisplayDisabler: reconfig display=\(display) flags=\(flags.rawValue) sleeping=\(isSystemSleeping) disabled=\(isBuiltInDisabled)")

        NotificationCenter.default.post(name: Self.didChange, object: nil)

        guard isBuiltInDisabled else { return }

        // Start pinning brightness=0 — a single write loses to the OS's own
        // brightness restoration on lid-open. The pin keeps writing 0 every
        // ~30ms for ~1.5s, long enough to dominate the OS's animated rewrite.
        extendBrightnessPin(by: 1.5)

        // Mirror reapplication only on the "end" half (the OS has finished
        // its reconfig) and only when we're awake — during system sleep the
        // external is gone from the active list and re-mirroring would fail.
        // The wake handler picks it up.
        if flags.contains(.beginConfigurationFlag) { return }
        if isSystemSleeping { return }
        applyDesiredState(reason: "reconfig-end")
    }

    /// Reconcile the OS's current display state with our desired state.
    /// Idempotent — safe to call from the reconfig debouncer or wake handler.
    private func applyDesiredState(reason: String) {
        guard isBuiltInDisabled else { return }

        if !hasExternalDisplay {
            Log.info("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — external gone, restoring built-in")
            _ = setDisabled(false)
            return
        }

        guard let displayID = Self.builtInDisplayID() else {
            Log.error("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — built-in ID not found")
            return
        }
        guard let target = Self.firstExternalActiveDisplay() else {
            Log.error("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — no external active")
            return
        }

        let currentMirror = CGDisplayMirrorsDisplay(displayID)
        if currentMirror != target {
            // Mirror was dropped by the OS (clamshell open is the usual
            // culprit — it brings the built-in back as a separate logical
            // screen and the cursor can wander onto it). Re-mirror now;
            // that's what blocks the cursor, not the brightness.
            let ok = mirror(builtIn: displayID, onto: target)
            Log.info("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — re-mirrored built-in onto \(target), ok=\(ok) (was=\(currentMirror))")
        } else {
            Log.info("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — mirror intact onto \(target)")
        }

        _ = (setLinearBrightness ?? setBrightness)?(displayID, 0.0)

        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func handleWillSleep() {
        isSystemSleeping = true
        wasDisabledBeforeSleep = isBuiltInDisabled
    }

    private func handleDidWake() {
        Log.info("BuiltInDisplayDisabler: didWake (wasDisabledBeforeSleep=\(wasDisabledBeforeSleep))")
        isSystemSleeping = false
        wasDisabledBeforeSleep = false
        NotificationCenter.default.post(name: Self.didChange, object: nil)

        // Pin brightness for longer on wake — the post-wake reconfig burst
        // can stretch over 1+ seconds, and the OS's brightness restoration
        // animation is more aggressive here than on a simple lid-open.
        extendBrightnessPin(by: 2.0)
        applyDesiredState(reason: "wake")

        pendingReconfigWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.applyDesiredState(reason: "wake-fallback")
            }
        }
        pendingReconfigWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func extendBrightnessPin(by duration: TimeInterval) {
        let newDeadline = Date().addingTimeInterval(duration)
        if newDeadline > brightnessPinDeadline {
            brightnessPinDeadline = newDeadline
        }
        if !brightnessPinScheduled {
            brightnessPinScheduled = true
            Log.info("BuiltInDisplayDisabler: brightness pin started, holding 0 until \(brightnessPinDeadline)")
            tickBrightnessPin()
        }
    }

    private var pinTickCount = 0

    private func tickBrightnessPin() {
        guard isBuiltInDisabled else {
            brightnessPinScheduled = false
            brightnessPinDeadline = .distantPast
            pinTickCount = 0
            return
        }
        if Date() >= brightnessPinDeadline {
            brightnessPinScheduled = false
            brightnessPinDeadline = .distantPast
            Log.info("BuiltInDisplayDisabler: brightness pin ended after \(pinTickCount) ticks")
            pinTickCount = 0
            return
        }
        if let displayID = Self.builtInDisplayID() {
            // Prefer linear brightness on Apple Silicon — skips the animated
            // gamma curve that loses the race against the OS's brightness
            // restoration on lid-open.
            let writeFn = setLinearBrightness ?? setBrightness
            let usedLinear = (setLinearBrightness != nil)
            if let writeFn {
                let rc = writeFn(displayID, 0.0)
                if rc != 0 {
                    Log.error("BuiltInDisplayDisabler: setBrightness rc=\(rc) linear=\(usedLinear)")
                }
            }
            // Read back every ~10 ticks (~300ms). If write returned success
            // but readback is non-zero, the API is being clobbered by the OS
            // (or doesn't actually drive hardware backlight on this machine).
            if pinTickCount % 10 == 0, let getBrightness {
                var current: Float = -1
                _ = getBrightness(displayID, &current)
                Log.info("BuiltInDisplayDisabler: pin tick=\(pinTickCount) brightness readback=\(current) linear=\(usedLinear)")
            }
        }
        pinTickCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                self?.tickBrightnessPin()
            }
        }
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
