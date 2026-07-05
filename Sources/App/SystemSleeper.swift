import Foundation

/// Immediately puts the whole system to sleep — equivalent to choosing
///  → Sleep from the Apple menu, or running `pmset sleepnow` in a shell.
///
/// On macOS there is only one user-facing "sleep" action: the OS itself
/// decides between RAM standby and on-disk hibernation based on power
/// state and idle duration (especially on Apple Silicon, where classic
/// `hibernatemode` no longer applies). So a single "Sleep Now" entry
/// covers both 立即睡眠 and 立即休眠.
///
/// `pmset sleepnow` is a public Apple CLI, runs without root, and works
/// across Intel and Apple Silicon — same rationale as `DisplaySleeper`.
@MainActor
enum SystemSleeper {
    static func sleepNow() {
        // Delay so the triggering click's HID event drains first — otherwise
        // it can cancel the pending sleep. See PMSet.settleDelay.
        PMSet.run(["sleepnow"], label: "SystemSleeper", delay: PMSet.settleDelay)
    }
}
