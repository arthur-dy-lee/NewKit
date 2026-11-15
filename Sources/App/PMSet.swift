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
    @MainActor private static var pendingSleep: Task<Void, Never>?

    /// Both sleep actions share one pending request. Repeated clicks replace
    /// it, so an older timer cannot put the screen back to sleep after a wake.
    @MainActor
    static func runWhenInputSettles(_ arguments: [String], label: String) {
        if pendingSleep != nil {
            Log.info("\(label): replacing pending sleep request")
            pendingSleep?.cancel()
        }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        Log.info("\(label): waiting for \(SleepInputSettler.quietInterval)s of idle input "
            + "(deadline \(SleepInputSettler.maximumWait)s)")
        pendingSleep = Task {
            var settler = SleepInputSettler(requestedAt: requestedAt)
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let input = SleepInputSnapshot.current()
                switch settler.decision(at: now, input: input) {
                case .ready:
                    pendingSleep = nil
                    Log.info("\(label): input settled after \(now - requestedAt)s "
                        + "idle=\(input.idleTime)s; invoking pmset \(arguments.joined(separator: " "))")
                    run(arguments, label: label)
                    return
                case .timedOut:
                    pendingSleep = nil
                    Log.info("\(label): cancelled sleep request because input stayed active "
                        + "idle=\(input.idleTime)s held=\(input.hasHeldInput)")
                    return
                case .wait:
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private static func run(_ arguments: [String], label: String) {
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
                } else {
                    Log.info("\(label): pmset \(arguments.joined(separator: " ")) succeeded")
                }
            } catch {
                Log.error("\(label): failed to invoke pmset: \(error)")
            }
        }
    }
}
