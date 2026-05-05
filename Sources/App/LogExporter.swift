import AppKit
import Foundation

/// Zips up `~/Library/Logs/NewKit/*` into the user's Desktop and reveals it in Finder.
@MainActor
enum LogExporter {
    enum ExportError: Error { case noLogs, zipFailed(Int32) }

    @discardableResult
    static func exportToDesktop() throws -> URL {
        let logsDir = Log.logsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: logsDir.path)) ?? []
        guard !files.isEmpty else { throw ExportError.noLogs }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let zipName = "NewKit-logs-\(formatter.string(from: Date())).zip"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let zipURL = desktop.appendingPathComponent(zipName)

        // Use /usr/bin/zip — simplest reliable way to produce a portable zip from arbitrary content.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zipURL.path, "."]
        process.currentDirectoryURL = logsDir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.zipFailed(process.terminationStatus)
        }
        NSWorkspace.shared.activateFileViewerSelecting([zipURL])
        return zipURL
    }
}
