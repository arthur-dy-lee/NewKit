import AppKit
import Foundation

enum FinderHelper {

    /// Returns the path of the frontmost Finder window, or the Desktop if no window is open.
    static func currentTargetPath() -> URL {
        let script = """
        tell application "Finder"
            try
                if (count of windows) > 0 then
                    return POSIX path of (target of front window as alias)
                end if
            end try
            return POSIX path of (path to desktop folder as alias)
        end tell
        """
        if let path = runAppleScript(script), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Selects the file in Finder and triggers rename mode (requires Accessibility permission).
    static func revealAndRename(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            triggerRenameKeystroke()
        }
    }

    private static func triggerRenameKeystroke() {
        let script = """
        tell application "System Events"
            tell process "Finder"
                key code 36
            end tell
        end tell
        """
        _ = runAppleScript(script)
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            Log.error("AppleScript error: \(error)")
            return nil
        }
        return descriptor.stringValue
    }
}
