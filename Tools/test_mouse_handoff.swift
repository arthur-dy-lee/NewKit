import AppKit

// swiftc Sources/App/MouseEnhancementCoordinator.swift Sources/App/PointerPropertyLease.swift \
//   Tools/test_mouse_handoff.swift -o /tmp/newkit-mouse-handoff && /tmp/newkit-mouse-handoff
@MainActor final class SmoothScroller {
    static let shared = SmoothScroller()
    func apply(suspended: Bool) {}
}
@MainActor final class ScrollInverter {
    static let shared = ScrollInverter()
    func apply(suspended: Bool) {}
}
@MainActor final class PointerLinearizer {
    static let shared = PointerLinearizer()
    func apply(suspended: Bool) {}
}
enum Log { static func info(_ message: String) {} }

@main
enum MouseHandoffChecks {
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
        func smooze(_ pid: pid_t) -> MouseEnhancementCoordinator.CompanionProcess {
            .init(bundleIdentifier: "co.smoozepro.macos", processIdentifier: pid)
        }
        @MainActor final class Fixture {
            var running: [MouseEnhancementCoordinator.CompanionProcess] = []
            var suspended: [Bool] = []
            let notifications = NotificationCenter()
            func make() -> MouseEnhancementCoordinator {
                MouseEnhancementCoordinator(processes: { self.running },
                    applyEnhancements: { self.suspended.append($0) },
                    resumeDelay: 0.03, pollInterval: 0.025, notificationCenter: notifications,
                    workspaceToObserve: nil)
            }
        }

        let absent = Fixture()
        let nk = absent.make()
        nk.start()
        expect(nk.state == .newKit && absent.suspended == [false], "NK owns input when Smooze is absent")
        nk.start()
        expect(absent.suspended == [false], "starting twice does not install duplicate observers")
        nk.configurationDidChange()
        expect(absent.suspended == [false, false], "NK preference changes apply normally")
        nk.stop()
        expect(absent.suspended.last == true, "quitting NK releases its mouse enhancements")

        let present = Fixture()
        present.running = [smooze(100)]
        let coordinator = present.make()
        coordinator.start()
        expect(coordinator.state == .smooze && present.suspended == [true], "startup never enables NK over Smooze")
        coordinator.configurationDidChange()
        present.notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(present.suspended.allSatisfy { $0 }, "settings and wake cannot bypass Smooze priority")

        present.running = []
        coordinator.refresh(reason: "test-exit")
        expect(coordinator.state == .resuming && present.suspended.last == true,
               "give Smooze time to release its event hooks before NK resumes")
        wait(0.08)
        expect(coordinator.state == .newKit && present.suspended.last == false,
               "NK automatically resumes after Smooze quits")

        present.running = [smooze(101)]
        coordinator.refresh(reason: "test-launch")
        expect(coordinator.state == .smooze && present.suspended.last == true, "a new Smooze process suspends NK")
        let enabledBeforeRestart = present.suspended.filter { !$0 }.count
        present.running = []
        coordinator.refresh(reason: "test-restart-exit")
        present.running = [smooze(102)]
        coordinator.refresh(reason: "test-restart-launch")
        wait(0.08)
        expect(coordinator.state == .smooze, "rapid Smooze relaunch cancels an old resume timer")
        expect(present.suspended.filter { !$0 }.count == enabledBeforeRestart,
               "rapid relaunch never briefly enables NK")

        present.running = [smooze(102), smooze(103)]
        coordinator.refresh(reason: "two-copies")
        present.running = [smooze(103)]
        coordinator.refresh(reason: "one-copy-exited")
        wait(0.06)
        expect(coordinator.state == .smooze, "one remaining Smooze copy keeps NK suspended")

        present.running = [] // No lifecycle notification: simulate a missed event/crash.
        wait(0.1)
        expect(coordinator.state == .newKit, "periodic probe recovers a missed exit notification")
        present.running = [smooze(104)]
        wait(0.06)
        expect(coordinator.state == .smooze, "periodic probe recovers a missed launch notification")

        present.running = []
        coordinator.refresh(reason: "exit-before-nk-stop")
        coordinator.stop()
        let countAtStop = present.suspended.count
        wait(0.08)
        expect(present.suspended.count == countAtStop, "stop cancels timers and pending resume work")
        present.notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(present.suspended.count == countAtStop, "stop removes notification observers")

        present.running = [smooze(105)]
        coordinator.start()
        expect(coordinator.state == .smooze && present.suspended.last == true, "restart probes fresh process state")
        coordinator.stop()
        expect(!MouseEnhancementCoordinator.isSmooze("co.smoozepro.macos.helper"), "helper identity is not the main app")
        expect(!MouseEnhancementCoordinator.isSmooze("com.example.Smooze"), "display-name lookalikes do not seize ownership")

        var acceleration = PointerPropertyLease(originalValue: 32768)
        expect(acceleration.valueToRestore(currentValue: 32768) == nil, "unwritten property must not be restored")
        acceleration.didApply(-65536)
        expect(acceleration.valueToRestore(currentValue: -65536) == 32768, "restore a value NK still owns")
        expect(acceleration.valueToRestore(currentValue: 65536) == nil, "preserve Smooze's newer acceleration")
        expect(acceleration.valueToRestore(currentValue: nil) == nil, "unreadable device property is left untouched")
        var resolution = PointerPropertyLease(originalValue: 26_214_400)
        resolution.didApply(13_107_200)
        resolution.didApply(6_553_600)
        expect(resolution.originalValue == 26_214_400, "speed adjustments do not compound the saved baseline")
        expect(resolution.valueToRestore(currentValue: 6_553_600) == 26_214_400, "latest NK speed can be reverted")
        expect(resolution.valueToRestore(currentValue: 30_000_000) == nil, "preserve Smooze's newer resolution")
        var mouseAcceleration = PointerPropertyLease(originalValue: 49152)
        mouseAcceleration.didApply(-65536)
        expect(mouseAcceleration.valueToRestore(currentValue: -65536) == 49152,
               "mouse and pointer acceleration have independent original values")
        print("Mouse handoff: \(checks) lifecycle and property-ownership checks passed")
    }
}
