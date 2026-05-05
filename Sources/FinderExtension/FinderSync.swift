import AppKit
import FinderSync

/// Finder Sync extension that adds a NewKit toolbar button and right-click submenu.
/// We don't use sync features (no badges, no observed directories), only the UI extension surface.
final class FinderSync: FIFinderSync {

    private static let appBundleID = "app.newkit.NewKit"
    private static let menuTypeIDsKey = "menuTypeIDs"

    override init() {
        super.init()

        let controller = FIFinderSyncController.default()
        // Observe the entire user home so the toolbar button is active everywhere a typical user works.
        // Users can refine this via System Settings → Login Items & Extensions if they want.
        let home = FileManager.default.homeDirectoryForCurrentUser
        controller.directoryURLs = [home]

        let image = NSImage(systemSymbolName: "plus.square.on.square",
                            accessibilityDescription: "NewKit") ?? NSImage()
        image.isTemplate = true
        controller.setBadgeImage(image, label: "NewKit", forBadgeIdentifier: "newkit")
        // Toolbar item appearance is provided by Info.plist (NSExtensionAttributes) when present.
    }

    // MARK: - Menus

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu()
        switch menuKind {
        case .toolbarItemMenu, .contextualMenuForContainer, .contextualMenuForItems:
            populate(menu)
        default:
            populate(menu)
        }
        return menu
    }

    private func populate(_ menu: NSMenu) {
        let header = NSMenuItem(title: NSLocalizedString("ext.menu.header", comment: ""),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for entry in resolveTypes() {
            let item = NSMenuItem(title: entry.title, action: #selector(handle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            if let symbol = entry.symbolName,
               let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                item.image = img
            }
            menu.addItem(item)
        }
    }

    @objc private func handle(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MenuEntry else { return }
        let target = resolveTargetURL()
        // Hand off to the main app via a custom URL — extension itself can't sandbox-write
        // anywhere reliably and is capability-limited. The main app does the actual creation.
        let payload = "newkit://create?type=\(entry.id)&path=\(target.path.urlEncoded)"
        if let url = URL(string: payload) {
            NSWorkspace.shared.open(url)
        }
    }

    private func resolveTargetURL() -> URL {
        if let target = FIFinderSyncController.default().targetedURL() { return target }
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        if let first = selected.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir),
               isDir.boolValue { return first }
            return first.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Configuration via shared App Group is added in M3 with proper provisioning.
    //         For now, we ship a hard-coded default list mirroring FileTypeRegistry's built-ins.

    private struct MenuEntry: Codable {
        let id: String
        let title: String
        let symbolName: String?
    }

    private func resolveTypes() -> [MenuEntry] {
        [
            MenuEntry(id: "txt",    title: localized("menu.newfile.txt"),    symbolName: "doc.text"),
            MenuEntry(id: "md",     title: localized("menu.newfile.md"),     symbolName: "doc.richtext"),
            MenuEntry(id: "py",     title: localized("menu.newfile.py"),     symbolName: "chevron.left.forwardslash.chevron.right"),
            MenuEntry(id: "js",     title: localized("menu.newfile.js"),     symbolName: "curlybraces"),
            MenuEntry(id: "ts",     title: localized("menu.newfile.ts"),     symbolName: "curlybraces"),
            MenuEntry(id: "json",   title: localized("menu.newfile.json"),   symbolName: "curlybraces.square"),
            MenuEntry(id: "html",   title: localized("menu.newfile.html"),   symbolName: "globe"),
            MenuEntry(id: "css",    title: localized("menu.newfile.css"),    symbolName: "paintbrush"),
            MenuEntry(id: "sh",     title: localized("menu.newfile.sh"),     symbolName: "terminal"),
            MenuEntry(id: "xlsx",   title: localized("menu.newfile.xlsx"),   symbolName: "tablecells"),
            MenuEntry(id: "docx",   title: localized("menu.newfile.docx"),   symbolName: "doc.text.fill"),
            MenuEntry(id: "pptx",   title: localized("menu.newfile.pptx"),   symbolName: "rectangle.on.rectangle"),
            MenuEntry(id: "folder", title: localized("menu.newfile.folder"), symbolName: "folder"),
        ]
    }

    private func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
