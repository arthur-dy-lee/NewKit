import Foundation

/// Fire-and-forget wrapper around the public `/usr/bin/pmset` CLI for the
/// immediate "do it now" actions (`sleepnow`, `displaysleepnow`).
///
/// Two reasons this runs on a background queue instead of inline:
///  - `waitUntilExit()` blocks until pmset returns, which we don't want on the
///    main thread.
///  - For `sleepnow` the main thread is about to be suspended by the impending
///    system sleep anyway.
///
/// Unlike a bare `process.run()` (which only throws when the binary itself
/// can't be *launched*), this also inspects the exit status and surfaces
/// pmset's own stderr. So a silent no-op — e.g. a future macOS privilege or
/// policy change that makes the command fail — leaves a trace in the log
/// instead of vanishing.
enum PMSet {
    static func run(_ arguments: [String], label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = arguments
            let errPipe = Pipe()
            process.standardError = errPipe
            do {
                try process.run()
                // Drain stderr before waiting: reading to EOF blocks until pmset
                // closes the pipe (i.e. exits), which sidesteps the pipe-buffer
                // deadlock and makes the subsequent waitUntilExit() immediate.
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let stderr = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let suffix = stderr.isEmpty ? "" : ": \(stderr)"
                    Log.error("\(label): pmset \(arguments.joined(separator: " ")) "
                        + "exited \(process.terminationStatus)\(suffix)")
                }
            } catch {
                Log.error("\(label): failed to invoke pmset: \(error)")
            }
        }
    }
}
