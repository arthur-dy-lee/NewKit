// Compile this file concatenated after Sources/App/SmoothScroller.swift so
// its file-private wheel input is exercised without installing a global tap.
// The injected output sink captures events; nothing is posted to the desktop.
@MainActor final class Configuration {
    static let shared = Configuration()
    var smoothScrollEnabled = true
    var smoothScrollMultiplier = 1.0
    var smoothScrollDurationMs = 220.0
}
enum AccessibilityHelper { static let isTrusted = false }
enum Log {
    static func info(_ message: String) {}
    static func error(_ message: String) {}
}

private final class CapturedScrolls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var invalid = false

    func record(_ event: CGEvent) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        invalid = invalid || event.getIntegerValueField(.eventSourceUserData) != SmoothScroller.injectedTag
            || event.getIntegerValueField(.scrollWheelEventIsContinuous) != 1
    }

    var snapshot: (count: Int, valid: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (count, !invalid)
    }
}

@main
enum SmoothScrollHandoffChecks {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ context: String) {
            precondition(condition(), context)
            checks += 1
        }
        func wait(_ duration: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
        }
        let captured = CapturedScrolls()
        let scroller = SmoothScroller(postEvent: { captured.record($0) })
        scroller.apply(suspended: false)
        scroller.push(deltaY: 360, deltaX: 72)
        wait(0.06)
        expect(captured.snapshot.count > 0, "NK emits scroll animation while it owns input")
        scroller.apply(suspended: true)
        let pausedAt = captured.snapshot.count
        wait(0.08)
        expect(captured.snapshot.count == pausedAt, "no queued animation survives handoff to Smooze")
        scroller.push(deltaY: 360, deltaX: 72)
        wait(0.04)
        expect(captured.snapshot.count == pausedAt, "a stale wheel callback cannot restart a paused timer")
        expect(Configuration.shared.smoothScrollEnabled, "suspending does not erase the saved toggle")
        scroller.apply(suspended: false)
        wait(0.04)
        expect(captured.snapshot.count == pausedAt, "resuming does not replay old wheel input")

        for cycle in 0..<10 {
            scroller.push(deltaY: 120, deltaX: 0)
            wait(0.02)
            scroller.apply(suspended: true)
            let stoppedAt = captured.snapshot.count
            wait(0.02)
            expect(captured.snapshot.count == stoppedAt, "rapid switch \(cycle) leaves no trailing frames")
            scroller.apply(suspended: false)
        }
        scroller.apply(suspended: true)
        expect(captured.snapshot.valid, "captured animation retains its source tag and continuous format")

        // Hold a frame in the output sink to model an event post already in
        // progress. Pausing must drain it before the handoff returns.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let drained = CapturedScrolls()
        let busy = SmoothScroller(postEvent: { event in
            entered.signal()
            release.wait()
            drained.record(event)
        })
        busy.apply(suspended: false)
        busy.push(deltaY: 120, deltaX: 0)
        expect(entered.wait(timeout: .now() + 1) == .success, "an output frame is in flight")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { release.signal() }
        busy.apply(suspended: true)
        expect(drained.snapshot.count == 1, "handoff waits for an in-flight output frame")
        wait(0.04)
        expect(drained.snapshot.count == 1, "in-flight cancellation leaves no later outputs")
        print("Smooth-scroll handoff: \(checks) queue and cancellation checks passed; no desktop events posted")
    }
}
