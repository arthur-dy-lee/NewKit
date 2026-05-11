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
    /// Delayed task that flips the toggle off when the external display has
    /// been gone for a sustained period. We do NOT auto-restore the built-in
    /// the first time `hasExternalDisplay` reads false — lid movement (even
    /// without a full close) produces brief sub-second windows where the
    /// external is missing from `CGGetActiveDisplayList`. Acting on those
    /// flickers is what made the built-in spontaneously light up. Only after
    /// the external is confirmed absent across the settle delay do we
    /// actually restore.
    private var externalGoneConfirmWork: DispatchWorkItem?
    private static let externalGoneConfirmDelay: TimeInterval = 2.0
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
        // Any explicit user-facing transition supersedes a pending
        // confirmation timer — drop it.
        externalGoneConfirmWork?.cancel()
        externalGoneConfirmWork = nil

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
            blackoutGamma(displayID)
        } else {
            restoreGamma(displayID)
            let saved = defaults.object(forKey: Self.savedBrightnessKey) as? Double ?? 1.0
            _ = (setLinearBrightness ?? setBrightness)?(displayID, Float(saved))
            _ = unmirror(builtIn: displayID)
            defaults.removeObject(forKey: Self.recoveryFlagKey)
            defaults.removeObject(forKey: Self.savedBrightnessKey)
        }

        if isBuiltInDisabled != disabled {
            isBuiltInDisabled = disabled
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            if disabled {
                // Kick off the continuous gamma/brightness pin now so the
                // very first reconfig event after toggling has us already
                // ticking. Without this we'd only start the pin on the next
                // reconfig callback, and the user would see a flash on the
                // first lid open.
                extendBrightnessPin(by: 0)
            }
        }
        return true
    }

    private func handleDisplayReconfig(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        Log.info("BuiltInDisplayDisabler: reconfig display=\(display) flags=\(flags.rawValue) sleeping=\(isSystemSleeping) disabled=\(isBuiltInDisabled)")

        NotificationCenter.default.post(name: Self.didChange, object: nil)

        guard isBuiltInDisabled else { return }
        if isSystemSleeping { return }

        // Start (or extend) the gamma/brightness pin at the EARLIEST sign of
        // a reconfig — including the begin callback, before the OS has
        // finished its own reconfiguration. The lid-open flash happens
        // because the OS resets gamma and lights the backlight as part of
        // bringing the built-in back online, slightly before our CG callback
        // is invoked. We can't run before the OS, but pinning here means our
        // 30 ms tick reapplies gamma=0 as soon as the panel is addressable,
        // shrinking the visible flash window to one or two frames.
        extendBrightnessPin(by: 3.0)

        // Mirror reapplication only on the "end" half (the OS has finished
        // its reconfig) — re-mirroring on `begin` races the OS's own
        // configuration and tends to be silently undone.
        if flags.contains(.beginConfigurationFlag) { return }

        // Reconcile immediately. The auto-restore decision (external gone →
        // turn built-in back on) is now gated by a delayed confirmation
        // inside applyDesiredState, so running it on every event is safe and
        // means we re-mirror as soon as the OS drops our config.
        applyDesiredState(reason: "reconfig-end")
    }

    /// Reconcile the OS's current display state with our desired state.
    /// Idempotent — safe to call from the reconfig handler or wake handler.
    ///
    /// Critical invariant: this never calls `setDisabled(false)` directly on
    /// a "missing external" reading. The active-display list flickers during
    /// reconfig bursts (lid wiggle, mode change, sleep transitions), and a
    /// single dropped frame is not enough evidence that the user unplugged
    /// the external. Auto-restore goes through `scheduleExternalGoneCheck`
    /// instead, which only fires after the external has been absent for the
    /// full settle delay.
    private func applyDesiredState(reason: String) {
        guard isBuiltInDisabled else { return }

        guard let displayID = Self.builtInDisplayID() else {
            Log.info("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — built-in ID not found, deferring")
            return
        }

        guard let target = Self.firstExternalActiveDisplay() else {
            Log.info("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — no external active right now, scheduling confirmation")
            scheduleExternalGoneCheck(reason: reason)
            return
        }

        // External is here — cancel any pending "external gone" pessimism
        // from a previous flicker.
        externalGoneConfirmWork?.cancel()
        externalGoneConfirmWork = nil

        let currentMirror = CGDisplayMirrorsDisplay(displayID)
        if currentMirror != target {
            // Mirror was dropped by the OS (lid open in clamshell mode is the
            // usual culprit — it brings the built-in back as a separate
            // logical screen and the cursor can wander onto it). Re-mirror
            // now; that's what blocks the cursor, not the brightness.
            let ok = mirror(builtIn: displayID, onto: target)
            Log.info("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — re-mirrored built-in onto \(target), ok=\(ok) (was=\(currentMirror))")
        } else {
            Log.info("BuiltInDisplayDisabler: applyDesiredState(\(reason)) — mirror intact onto \(target)")
        }

        _ = (setLinearBrightness ?? setBrightness)?(displayID, 0.0)
        blackoutGamma(displayID)

        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Drives the built-in panel's gamma table to all-zero, so every pixel
    /// renders as black regardless of backlight level. `DisplayServicesSet*Brightness`
    /// gets clamped to ~6.25% after lid/reconfig events on Apple Silicon —
    /// the LCD glows visibly even when we keep writing 0. Gamma is per-display,
    /// applied at the framebuffer→panel stage (so it works with mirroring),
    /// and survives reconfig events better than brightness.
    private func blackoutGamma(_ id: CGDirectDisplayID) {
        let rc = CGSetDisplayTransferByFormula(
            id,
            0, 0, 1,
            0, 0, 1,
            0, 0, 1
        )
        if rc != .success {
            Log.error("BuiltInDisplayDisabler: gamma blackout rc=\(rc.rawValue)")
        }
    }

    private func restoreGamma(_ id: CGDirectDisplayID) {
        // Identity gamma: min=0, max=1, gamma=1.
        let rc = CGSetDisplayTransferByFormula(
            id,
            0, 1, 1,
            0, 1, 1,
            0, 1, 1
        )
        if rc != .success {
            Log.error("BuiltInDisplayDisabler: gamma restore rc=\(rc.rawValue)")
        }
    }

    /// Defer the "external gone, restore built-in" decision. Reset on every
    /// call — if the external comes back before the delay elapses, the
    /// applyDesiredState path will cancel us and we'll never fire.
    private func scheduleExternalGoneCheck(reason: String) {
        externalGoneConfirmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.externalGoneConfirmWork = nil
                guard self.isBuiltInDisabled else { return }
                if self.hasExternalDisplay {
                    // External came back during the wait — re-apply mirror.
                    self.applyDesiredState(reason: "external-back-after-flicker")
                    return
                }
                Log.info("BuiltInDisplayDisabler: external confirmed gone (\(reason)), restoring built-in")
                _ = self.setDisabled(false)
            }
        }
        externalGoneConfirmWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.externalGoneConfirmDelay, execute: work
        )
    }

    private func handleWillSleep() {
        isSystemSleeping = true
        wasDisabledBeforeSleep = isBuiltInDisabled
        pendingReconfigWork?.cancel()
        pendingReconfigWork = nil
        // System sleep makes every external "gone" — but we must not let
        // that turn the feature off, otherwise the user wakes up with the
        // built-in lit. Cancel any pending confirmation.
        externalGoneConfirmWork?.cancel()
        externalGoneConfirmWork = nil
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

    /// Ensures the brightness/gamma pin loop is running. Idempotent. The
    /// `duration` parameter is retained for callsite clarity but no longer
    /// gates the pin — the pin now runs continuously while the toggle is on,
    /// because the lid-open flash is too fast to catch with a deadline-based
    /// pin that starts only after a reconfig callback.
    private func extendBrightnessPin(by duration: TimeInterval) {
        guard isBuiltInDisabled else { return }
        if !brightnessPinScheduled {
            brightnessPinScheduled = true
            Log.info("BuiltInDisplayDisabler: brightness/gamma pin started (continuous)")
            tickBrightnessPin()
        }
    }

    private var pinTickCount = 0

    private func tickBrightnessPin() {
        // Pin runs continuously while disabled, not just within a deadline.
        // The lid-open flash happens because the OS resets the panel state
        // (backlight on + gamma to identity) slightly before any callback we
        // can hook. By ticking every ~16 ms (one frame at 60 Hz) all the
        // time, we keep gamma=0 reapplied within a single frame of any OS
        // intervention — flash window shrinks to a single frame at worst.
        guard isBuiltInDisabled else {
            brightnessPinScheduled = false
            brightnessPinDeadline = .distantPast
            Log.info("BuiltInDisplayDisabler: brightness pin stopped after \(pinTickCount) ticks (toggle off)")
            pinTickCount = 0
            return
        }
        if let displayID = Self.builtInDisplayID() {
            // Prefer linear brightness on Apple Silicon — skips the animated
            // gamma curve that loses the race against the OS's brightness
            // restoration on lid-open. Note that on Apple Silicon the OS
            // clamps brightness at ~6.25%; gamma is what actually achieves
            // a black panel here.
            let writeFn = setLinearBrightness ?? setBrightness
            let usedLinear = (setLinearBrightness != nil)
            if let writeFn {
                let rc = writeFn(displayID, 0.0)
                if rc != 0, pinTickCount % 60 == 0 {
                    Log.error("BuiltInDisplayDisabler: setBrightness rc=\(rc) linear=\(usedLinear)")
                }
            }
            blackoutGamma(displayID)
            // Readback every ~60 ticks (~1s) — diagnostic only, low spam.
            if pinTickCount % 60 == 0, let getBrightness {
                var current: Float = -1
                _ = getBrightness(displayID, &current)
                Log.info("BuiltInDisplayDisabler: pin tick=\(pinTickCount) brightness readback=\(current) linear=\(usedLinear)")
            }
        }
        pinTickCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
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
