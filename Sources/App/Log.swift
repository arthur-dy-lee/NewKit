import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "app.newkit", category: "main")
    private static let fileQueue = DispatchQueue(label: "app.newkit.log.file")

    static func info(_ message: String)  { write("INFO",  message); logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

    /// `~/Library/Logs/NewKit/` — same as `URL.logsDirectory` but writeable from any actor.
    static var logsDirectory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let dir = lib.appendingPathComponent("Logs/NewKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Path of the current day's log file.
    static var currentLogFile: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return logsDirectory.appendingPathComponent("\(formatter.string(from: Date())).log")
    }

    /// Removes log files older than 14 days.
    static func purgeOldLogs(retentionDays: Int = 14) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in files where url.pathExtension == "log" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mtime < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] \(message)\n"
        let url = currentLogFile
        fileQueue.async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path),
                   let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
