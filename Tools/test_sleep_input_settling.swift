import Foundation

// swiftc Sources/App/SleepInputSettler.swift Tools/test_sleep_input_settling.swift \
//   -o /tmp/newkit-sleep-input-checks && /tmp/newkit-sleep-input-checks
@main
enum SleepInputSettlingChecks {
    static func main() {
        var checks = 0

        func expect(_ actual: SleepInputSettler.Decision,
                    _ expected: SleepInputSettler.Decision, _ context: String) {
            precondition(actual == expected, context)
            checks += 1
        }
        func input(_ idle: TimeInterval, held: Bool = false) -> SleepInputSnapshot {
            SleepInputSnapshot(idleTime: idle, hasHeldInput: held)
        }

        // Even a programmatic request made after a long idle gets a settling
        // interval, giving the menu and any trailing input time to finish.
        var normal = SleepInputSettler(requestedAt: 0)
        expect(normal.decision(at: 0, input: input(60)), .wait, "no immediate sleep")
        expect(normal.decision(at: 0.5, input: input(60)), .wait, "old delay is insufficient")
        expect(normal.decision(at: 1.2, input: input(60)), .ready, "quiet request completes")

        // Reproduce the late mouse movement that woke the old implementation:
        // it arrived about 1.1 seconds after choosing the menu action.
        var lateMovement = SleepInputSettler(requestedAt: 0)
        expect(lateMovement.decision(at: 0.5, input: input(0.5)), .wait, "wait beyond old delay")
        expect(lateMovement.decision(at: 1.2, input: input(0.1)), .wait, "late movement resets idle")
        expect(lateMovement.decision(at: 2.2, input: input(1.1)), .wait, "full quiet interval required")
        expect(lateMovement.decision(at: 2.4, input: input(1.3)), .ready, "sleep after mouse settles")

        // A held button or key can be quiet according to the event clock.
        // Release must get its own quiet interval even if that clock is stale.
        var held = SleepInputSettler(requestedAt: 0)
        expect(held.decision(at: 1.5, input: input(20, held: true)), .wait, "held input blocks sleep")
        expect(held.decision(at: 1.6, input: input(20)), .wait, "do not sleep at release")
        expect(held.decision(at: 2.8, input: input(20)), .ready, "release settles")

        // Continuing to work cancels the request instead of leaving a timer
        // that can unexpectedly sleep the computer much later.
        var busy = SleepInputSettler(requestedAt: 0)
        for tick in 0..<50 {
            expect(busy.decision(at: Double(tick) / 10, input: input(0.05)),
                   .wait, "ongoing interaction tick \(tick)")
        }
        expect(busy.decision(at: 5, input: input(0.05)), .timedOut, "busy deadline")
        var atDeadline = SleepInputSettler(requestedAt: 10)
        expect(atDeadline.decision(at: 15, input: input(60)), .timedOut, "deadline beats readiness")

        // Invalid/unavailable event-clock samples must never authorize sleep.
        for idle in [Double.nan, .infinity, -.infinity, -1] {
            var unavailable = SleepInputSettler(requestedAt: 0)
            expect(unavailable.decision(at: 2, input: input(idle)), .wait, "invalid idle \(idle)")
        }

        // All timing is relative to monotonic uptime, including after a long
        // system uptime; wall-clock/time-zone changes cannot affect it.
        var longUptime = SleepInputSettler(requestedAt: 1_000_000)
        expect(longUptime.decision(at: 1_000_001, input: input(5)), .wait, "uptime minimum")
        expect(longUptime.decision(at: 1_000_001.3, input: input(5)), .ready, "uptime ready")

        let sample = SleepInputSnapshot.current()
        precondition(sample.idleTime.isFinite && sample.idleTime >= 0, "live event-clock sample")
        print("Sleep input settling: \(checks) checks passed; input API smoke check passed")
    }
}
