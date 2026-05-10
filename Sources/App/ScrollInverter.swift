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
    /// Toggled to true the first time the C callback fires; used to confirm the tap is alive.
    fileprivate var didLogFirstEvent = false

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
        didLogFirstEvent = false
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
    if !inverter.didLogFirstEvent {
        inverter.didLogFirstEvent = true
        Log.info("ScrollInverter: first scroll event intercepted (tap is alive)")
    }
    let (mouseV, padV, padH) = inverter.snapshot()


    // Decide what physical device this event came from. SmoothScroller may
    // have already converted a discrete mouse-wheel event into a continuous
    // pixel-precise stream — in that case `isContinuous` is misleading, so
    // we trust the SmoothScroller tag first.
    let isFromMouseWheel: Bool
    if event.getIntegerValueField(.eventSourceUserData) == SmoothScroller.injectedTag {
        isFromMouseWheel = true
    } else {
        isFromMouseWheel = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
    }

    // Three parallel fields describe the same scroll: line-step, fixed-point,
    // and pixel-precise. Flip all three on whichever axes apply so apps
    // reading any of them see a consistent direction.
    let invertVertical = isFromMouseWheel ? mouseV : padV
    let invertHorizontal = isFromMouseWheel ? false : padH

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
