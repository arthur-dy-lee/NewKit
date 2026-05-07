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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
        } catch {
            Log.error("DisplaySleeper: failed to invoke pmset: \(error)")
        }
    }
}
