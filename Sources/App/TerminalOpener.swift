import AppKit
import Foundation

enum TerminalOpener {
    static let actionID = "__action.openterminal"

    private static let candidatePaths = [
        "/System/Applications/Utilities/Terminal.app",
        "/Applications/Utilities/Terminal.app",
    ]

    static func open(at folder: URL) {
        let terminalURL = candidatePaths
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            ?? URL(fileURLWithPath: candidatePaths[0])

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(
            [folder], withApplicationAt: terminalURL, configuration: cfg
        ) { _, error in
            if let error {
                Log.error("Open Terminal failed: \(error.localizedDescription)")
            }
        }
    }
}
