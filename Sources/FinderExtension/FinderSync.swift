import AppKit
import FinderSync

@objc(NewKitFinderSync)
final class NewKitFinderSync: FIFinderSync {

    private static let appGroupID = "XVZHPD648U.com.codearthur.matrixapps.newkit"
    private let sharedDefaults = UserDefaults(suiteName: appGroupID)

    override init() {
        super.init()
        NSLog("[NewKit] FinderSync init")
        let controller = FIFinderSyncController.default()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: Set<URL> = [home]
        if let volume = URL(string: "file:///") { roots.insert(volume) }
        controller.directoryURLs = roots

        // Toolbar item: image + tooltip. KVC-style setting is used so we don't depend on
        // SDK-version-specific property declarations (Apple has shuffled these around).
        let image = NSImage(systemSymbolName: "plus.square.on.square",
                            accessibilityDescription: "NewKit") ?? NSImage()
        image.isTemplate = true
        controller.setValue(image, forKey: "toolbarItemImage")
        controller.setValue("NewKit", forKey: "toolbarItemName")
        controller.setValue("Create new file with NewKit", forKey: "toolbarItemToolTip")
    }

    // MARK: - Menus

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        NSLog("[NewKit] menu(for:) kind=\(menuKind.rawValue)")
        let menu = NSMenu()
        let parent = NSMenuItem(title: "NewKit", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for entry in resolveTypes() {
            let item = NSMenuItem(title: entry.title, action: #selector(handle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            if let symbol = entry.symbolName,
               let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                item.image = img
            }
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    @objc private func handle(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? Snapshot else { return }
        let target = resolveTargetURL()
        let payload = "newkit://create?type=\(entry.id)&path=\(target.path.urlEncoded)"
        NSLog("[NewKit] handle id=\(entry.id) → \(target.path)")
        if let url = URL(string: payload) {
            NSWorkspace.shared.open(url)
        }
    }

    private func resolveTargetURL() -> URL {
        if let target = FIFinderSyncController.default().targetedURL() { return target }
        if let selected = FIFinderSyncController.default().selectedItemURLs(), let first = selected.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir),
               isDir.boolValue { return first }
            return first.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Snapshot from shared defaults

    private struct Snapshot: Codable {
        let id: String
        let ext: String?
        let symbolName: String?
        let title: String
        let isFolder: Bool
    }

    private func resolveTypes() -> [Snapshot] {
        if let data = sharedDefaults?.data(forKey: "visibleTypesSnapshot"),
           let list = try? JSONDecoder().decode([Snapshot].self, from: data),
           !list.isEmpty {
            return list
        }
        // Fallback: minimal hardcoded list so the menu is never empty.
        return [
            Snapshot(id: "txt", ext: "txt", symbolName: "doc.text", title: "Text File (.txt)", isFolder: false),
            Snapshot(id: "md",  ext: "md",  symbolName: "doc.richtext", title: "Markdown (.md)", isFolder: false),
            Snapshot(id: "folder", ext: nil, symbolName: "folder", title: "Folder", isFolder: true),
        ]
    }

    override func beginObservingDirectory(at url: URL) {
        NSLog("[NewKit] beginObservingDirectory: \(url.path)")
    }

    override func endObservingDirectory(at url: URL) { }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
