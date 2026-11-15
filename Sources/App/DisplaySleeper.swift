import AppKit

/// Immediately puts all displays to sleep — equivalent to running
/// `pmset displaysleepnow` from a shell. Useful for "I'm walking away,
/// don't wait the 10 minutes for the idle timeout."
///
/// `pmset displaysleepnow` is a public Apple CLI that works on Intel and
/// Apple Silicon, requires no root, and respects all attached displays. We
/// shell out instead of using the private IODisplayWrangler trick because
/// the wrangler service was renamed/removed on Apple Silicon and the public
/// CLI keeps working across macOS versions.
@MainActor
enum DisplaySleeper {
    private static var observers: [NSObjectProtocol] = []
    private static var sleptAt: TimeInterval?

    static func sleepNow() {
        observeDisplayTransitionsIfNeeded()
        PMSet.runWhenInputSettles(["displaysleepnow"], label: "DisplaySleeper")
    }

    private static func observeDisplayTransitionsIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                sleptAt = ProcessInfo.processInfo.systemUptime
                Log.info("DisplaySleeper: displays did sleep")
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let elapsed = sleptAt.map { ProcessInfo.processInfo.systemUptime - $0 }
                let input = SleepInputSnapshot.current()
                Log.info("DisplaySleeper: displays did wake sleptFor=\(elapsed.map { String($0) } ?? "unknown")s "
                    + "inputIdle=\(input.idleTime)s held=\(input.hasHeldInput)")
                sleptAt = nil
            }
        })
    }
}
