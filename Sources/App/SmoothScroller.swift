import AppKit
import CoreGraphics

/// Replaces the discrete "line-step" scroll wheel events that physical mice
/// produce on macOS with a stream of pixel-precise events generated from an
/// exponentially decaying animation curve. The result is a Mos / LinearMouse
/// style "silky" scroll without changing direction (that's `ScrollInverter`'s job).
///
/// Trackpad and Magic Mouse events arrive already pixel-precise (the
/// `kCGScrollWheelEventIsContinuous` field is 1) and are passed through
/// untouched so trackpad gestures still feel native.
///
/// Like `ScrollInverter`, the tap is created lazily and torn down when disabled
/// so users who never opt in pay no event-pipeline cost.
final class SmoothScroller: @unchecked Sendable {
    static let shared = SmoothScroller()
    private init() {}

    /// Sentinel written into `kCGEventSourceUserData` of every event we inject.
    /// Two consumers care: this tap's own callback uses it to skip its output
    /// without recursion, and `ScrollInverter` uses it to recognise an event
    /// that originated from a discrete mouse wheel even after we've converted
    /// it to a continuous pixel-precise event.
    static let injectedTag: Int64 = 0x4E_4B_53_4D_53_43_52_4C // "NKSMSCRL"

    /// One wheel "line" expands to this many pixels at multiplier 1.0. Picked to
    /// roughly match the pixel deltas the system would produce for a trackpad
    /// of equivalent travel.
    private static let pixelsPerLine: Double = 36.0

    private let lock = NSLock()
    private var enabled: Bool = false
    private var multiplier: Double = 1.0
    private var durationMs: Double = 220
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Pending pixel deltas accumulated from wheel notches; the timer drains
    /// them with exponential decay every tick. Vertical = axis1, horizontal = axis2.
    private var pendingY: Double = 0
    private var pendingX: Double = 0
    private var animTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "app.newkit.SmoothScroller.timer", qos: .userInteractive)
    /// 120 Hz tick. Even on 60 Hz displays this just means we hand the
    /// compositor two updates per frame, which it coalesces.
    private static let tickHz: Double = 120
    private static let tickInterval: TimeInterval = 1.0 / tickHz

    fileprivate var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    @MainActor
    func apply() {
        let on = Configuration.shared.smoothScrollEnabled
        let m = Configuration.shared.smoothScrollMultiplier
        let d = Configuration.shared.smoothScrollDurationMs
        lock.lock()
        enabled = on
        multiplier = m
        durationMs = d
        lock.unlock()

        Log.info("SmoothScroller.apply on=\(on) mult=\(m) dur=\(d)ms trusted=\(AccessibilityHelper.isTrusted) tapAlive=\(tap != nil)")

        if on {
            startIfNeeded()
        } else {
            stop()
            cancelTimer()
        }
    }

    fileprivate func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startIfNeeded() {
        if tap != nil { return }
        guard AccessibilityHelper.isTrusted else {
            Log.error("SmoothScroller: cannot start — Accessibility not granted")
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: smoothScrollCallback,
            userInfo: info
        ) else {
            Log.error("SmoothScroller: CGEvent.tapCreate returned nil — likely a TCC issue")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = source
        Log.info("SmoothScroller: tap created and enabled")
    }

    private func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
    }

    /// Adds the pixel deltas produced by a single wheel notch to the pending
    /// queue and ensures the animation timer is running.
    fileprivate func push(deltaY: Double, deltaX: Double) {
        lock.lock()
        pendingY += deltaY
        pendingX += deltaX
        let needTimer = abs(pendingY) > 0.5 || abs(pendingX) > 0.5
        lock.unlock()
        if needTimer {
            ensureTimer()
        }
    }

    /// Reads the live multiplier/duration. Cheap; called per-tick from the
    /// timer thread, so no main-thread hop.
    fileprivate func snapshotParams() -> (multiplier: Double, durationMs: Double) {
        lock.lock(); defer { lock.unlock() }
        return (multiplier, durationMs)
    }

    private func ensureTimer() {
        timerQueue.async { [weak self] in
            guard let self else { return }
            if self.animTimer != nil { return }
            let t = DispatchSource.makeTimerSource(queue: self.timerQueue)
            t.schedule(deadline: .now() + .milliseconds(Int(Self.tickInterval * 1000)),
                       repeating: Self.tickInterval)
            t.setEventHandler { [weak self] in self?.tick() }
            self.animTimer = t
            t.resume()
        }
    }

    private func cancelTimer() {
        timerQueue.async { [weak self] in
            guard let self else { return }
            self.animTimer?.cancel()
            self.animTimer = nil
            self.lock.lock()
            self.pendingY = 0
            self.pendingX = 0
            self.lock.unlock()
        }
    }

    /// Per-tick: emit a fraction of the remaining pixels using exponential
    /// decay (`1 - e^(-dt/tau)`). This mirrors what Mos does — it feels more
    /// natural than a fixed-length curve when the user spins the wheel
    /// repeatedly, because additional notches just bump the pending total.
    private func tick() {
        let (_, durMs) = snapshotParams()
        // Tau controls the visual "weight". 1/3 of total duration gives ~95%
        // of the distance covered within `durationMs`.
        let tau = max(0.030, durMs / 1000.0 * 0.33)
        let factor = 1.0 - exp(-Self.tickInterval / tau)

        lock.lock()
        let py = pendingY
        let px = pendingX
        var emitY = py * factor
        var emitX = px * factor
        // When the residual is sub-pixel, finish the animation in one frame so
        // we don't sit in a never-ending micro-decay.
        if abs(py - emitY) < 0.5 { emitY = py }
        if abs(px - emitX) < 0.5 { emitX = px }
        pendingY = py - emitY
        pendingX = px - emitX
        let stillRunning = abs(pendingY) > 0.0 || abs(pendingX) > 0.0
        lock.unlock()

        if abs(emitY) >= 0.5 || abs(emitX) >= 0.5 {
            postPixelEvent(deltaY: emitY, deltaX: emitX)
        }

        if !stillRunning {
            animTimer?.cancel()
            animTimer = nil
        }
    }

    /// Builds a continuous, pixel-precise scroll event and posts it at the HID
    /// tap so it traverses the same chain other apps see (including our own
    /// `ScrollInverter`, which inverts after this layer).
    private func postPixelEvent(deltaY: Double, deltaX: Double) {
        let intY = Int32(deltaY.rounded())
        let intX = Int32(deltaX.rounded())
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: intY,
            wheel2: intX,
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Keep the high-precision fixed-point fields filled in so SwiftUI /
        // AppKit views that use them get sub-pixel accuracy on each step.
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltaX)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(intY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(intX))
        event.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
        event.post(tap: .cghidEventTap)
    }

    fileprivate static var tagValue: Int64 { injectedTag }
    fileprivate static var pixelsPerWheelLine: Double { pixelsPerLine }
}

private func smoothScrollCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Log.error("SmoothScroller: tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"); re-enabling")
        if let refcon {
            let s = Unmanaged<SmoothScroller>.fromOpaque(refcon).takeUnretainedValue()
            s.reEnable()
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel, let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let scroller = Unmanaged<SmoothScroller>.fromOpaque(refcon).takeUnretainedValue()

    // Pass through our own re-injected events without re-processing.
    if event.getIntegerValueField(.eventSourceUserData) == SmoothScroller.tagValue {
        return Unmanaged.passUnretained(event)
    }

    if !scroller.isEnabled {
        return Unmanaged.passUnretained(event)
    }

    // Trackpad / Magic Mouse events are already continuous and feel native; let
    // them through unmodified so gestures, momentum, and rubber-banding are
    // preserved.
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
    if isContinuous != 0 {
        return Unmanaged.passUnretained(event)
    }

    // A modifier-held wheel turn (e.g. Cmd+wheel for zoom in many apps) should
    // stay discrete so apps treat it as a zoom-step rather than a smooth pan.
    let flags = event.flags
    if flags.contains(.maskCommand) || flags.contains(.maskControl)
        || flags.contains(.maskAlternate) || flags.contains(.maskShift) {
        return Unmanaged.passUnretained(event)
    }

    let lineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let lineX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    if lineY == 0 && lineX == 0 {
        return Unmanaged.passUnretained(event)
    }

    let (mult, _) = scroller.snapshotParams()
    let pxY = Double(lineY) * SmoothScroller.pixelsPerWheelLine * mult
    let pxX = Double(lineX) * SmoothScroller.pixelsPerWheelLine * mult
    scroller.push(deltaY: pxY, deltaX: pxX)

    // Swallow the original line-step event — replaced by the timer's pixel
    // stream above.
    return nil
}
