import AppKit

/// Provides NSServices entries that appear in Finder's right-click → Services submenu.
/// This is the no-permission fallback for users who don't grant Accessibility access.
@MainActor
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    /// Registers the provider with NSApp. Call once at launch.
    static func register() {
        NSApp.servicesProvider = ServicesProvider.shared
        NSUpdateDynamicServices()
    }

    /// Selector wired to "NewKit/Create New File…" service entry. Resolves the target folder
    /// from the pasteboard (Finder selection) and presents the floating panel anchored there.
    @objc func createNewFile(_ pboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let folder = resolveTargetFolder(from: pboard)
        FloatingPanelController.shared.showOverriding(folder: folder)
    }

    private func resolveTargetFolder(from pboard: NSPasteboard) -> URL {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                return first
            }
            return first.deletingLastPathComponent()
        }
        return FinderHelper.currentTargetPath()
    }
}
