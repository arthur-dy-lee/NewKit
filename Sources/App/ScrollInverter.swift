import AppKit
import CoreGraphics

/// Intercepts scroll wheel events via CGEventTap and flips the vertical and/or
/// horizontal deltas. Requires Accessibility permission (the same permission the
/// right-click monitor already needs).
///
/// The tap is created lazily — only when at least one direction is enabled — and
/// torn down when both are off, so the app does not sit in the event pipeline
/// for users who never opt in.
final class ScrollInverter: @unchecked Sendable {
    static let shared = ScrollInverter()
    private init() {}

    private let lock = NSLock()
    private var _invertMouseV: Bool = false
    private var _invertTrackpadV: Bool = false
    private var _invertTrackpadH: Bool = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Decremented from 5 → 0 as the C callback fires, with one detailed log
    /// per remaining sample. Reset on every (re)create so each fresh tap gives
    /// us a quick look at how it's deciding. Bounded so a session only ever
    /// produces a handful of lines per toggle, not one per scroll event.
    fileprivate var diagSamplesRemaining: Int = 0

    /// Read by the C callback on the run-loop thread; protected by `lock` so the
    /// main-thread writer (`apply()`) and the event-tap reader don't race.
    fileprivate func snapshot() -> (mouseV: Bool, padV: Bool, padH: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_invertMouseV, _invertTrackpadV, _invertTrackpadH)
    }

    /// Pulls the current toggle state from `Configuration` and starts/stops the
    /// tap to match. Safe to call repeatedly.
    @MainActor
    func apply() {
        let mv = Configuration.shared.invertMouseScroll
        let tv = Configuration.shared.invertTrackpadVerticalScroll
        let th = Configuration.shared.invertTrackpadHorizontalScroll
        lock.lock()
        _invertMouseV = mv
        _invertTrackpadV = tv
        _invertTrackpadH = th
        lock.unlock()

        Log.info("ScrollInverter.apply mouseV=\(mv) padV=\(tv) padH=\(th) trusted=\(AccessibilityHelper.isTrusted) tapAlive=\(tap != nil)")

        if mv || tv || th {
            startIfNeeded()
        } else {
            stop()
        }
    }

    /// Re-enable the tap after the system has disabled it (timeout or user input
    /// dropping it). Called from the C callback.
    fileprivate func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startIfNeeded() {
        if tap != nil { return }
        guard AccessibilityHelper.isTrusted else {
            Log.error("ScrollInverter: cannot start — Accessibility not granted")
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollEventCallback,
            userInfo: info
        ) else {
            Log.error("ScrollInverter: CGEvent.tapCreate returned nil — likely a TCC issue. Try removing NewKit from Accessibility and re-adding it.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = source
        diagSamplesRemaining = 5
        Log.info("ScrollInverter: tap created and enabled")
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
}

private func scrollEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Log.error("ScrollInverter: tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"); re-enabling")
        if let refcon {
            let inverter = Unmanaged<ScrollInverter>.fromOpaque(refcon).takeUnretainedValue()
            inverter.reEnable()
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel, let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let inverter = Unmanaged<ScrollInverter>.fromOpaque(refcon).takeUnretainedValue()
    let (mouseV, padV, padH) = inverter.snapshot()

    // Decide what physical device this event came from. SmoothScroller may
    // have already converted a discrete mouse-wheel event into a continuous
    // pixel-precise stream — in that case `isContinuous` is misleading, so
    // we trust the SmoothScroller tag first.
    let isInjectedByScroller =
        event.getIntegerValueField(.eventSourceUserData) == SmoothScroller.injectedTag
    let isContinuousField = event.getIntegerValueField(.scrollWheelEventIsContinuous)
    let isFromMouseWheel: Bool
    if isInjectedByScroller {
        isFromMouseWheel = true
    } else {
        isFromMouseWheel = isContinuousField == 0
    }

    // Tap-order independence: if a raw (untagged) discrete wheel event arrives
    // while SmoothScroller is on, SmoothScroller will swallow it and re-emit
    // a tagged pixel-precise event at HID. We MUST NOT flip the raw one too,
    // or the re-emission flips again and the two cancel out (net: no
    // inversion). This case fires whenever ScrollInverter's tap was inserted
    // ahead of SmoothScroller's in the cgSession chain — which depends on the
    // order each subsystem last (re)started, so we cannot rely on it.
    let smoothOn = SmoothScroller.shared.isEnabledForInverter
    let deferToSmoothScroller =
        !isInjectedByScroller && isContinuousField == 0 && smoothOn

    let invertVertical = !deferToSmoothScroller && (isFromMouseWheel ? mouseV : padV)
    let invertHorizontal = !deferToSmoothScroller && (isFromMouseWheel ? false : padH)

    // First few events after each (re)create: log the full decision so a
    // future "toggle is on but scroll doesn't flip" report can be diagnosed
    // from the log alone without rebuilding with extra instrumentation.
    if inverter.diagSamplesRemaining > 0 {
        inverter.diagSamplesRemaining -= 1
        let dyRaw = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        Log.info("ScrollInverter[diag] cont=\(isContinuousField) tagged=\(isInjectedByScroller) wheel=\(isFromMouseWheel) mouseV=\(mouseV) padV=\(padV) padH=\(padH) smoothOn=\(smoothOn) defer=\(deferToSmoothScroller) flipV=\(invertVertical) flipH=\(invertHorizontal) dy=\(dyRaw)")
    }

    if deferToSmoothScroller {
        return Unmanaged.passUnretained(event)
    }

    // Three parallel fields describe the same scroll: line-step, fixed-point,
    // and pixel-precise. Flip all three on whichever axes apply so apps
    // reading any of them see a consistent direction.
    if invertVertical {
        let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let fy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let py = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: -dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fy)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -py)
    }
    if invertHorizontal {
        let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let fx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let px = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: -dx)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fx)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -px)
    }
    return Unmanaged.passUnretained(event)
}
