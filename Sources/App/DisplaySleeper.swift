import Foundation

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
    static func sleepNow() {
        // Delay so the triggering click's HID event drains first — otherwise
        // it wakes the just-slept display. See PMSet.settleDelay.
        PMSet.run(["displaysleepnow"], label: "DisplaySleeper", delay: PMSet.settleDelay)
    }
}
