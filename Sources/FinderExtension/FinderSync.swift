import AppKit
import FinderSync
import os

@objc(NewKitFinderSync)
final class NewKitFinderSync: FIFinderSync {

    private static let appGroupID = "XVZHPD648U.com.codearthur.matrixapps.newkit"
    private static let logger = Logger(subsystem: "app.newkit", category: "ext")
    private let sharedDefaults = UserDefaults(suiteName: appGroupID)
    /// Maps `NSMenuItem.tag` → type ID. NSMenuItem's `representedObject` does NOT
    /// survive the XPC round-trip when Finder displays our menu, but `tag` does.
    private var tagToTypeID: [Int: String] = [:]
    /// Maps `NSMenuItem.tag` → action ID for non-create actions (e.g. open Terminal).
    private var tagToActionID: [Int: String] = [:]

    override init() {
        super.init()
        Self.logger.info("FinderSync init pid=\(getpid(), privacy: .public)")
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: - Toolbar item

    override var toolbarItemName: String { "NewKit" }
    override var toolbarItemToolTip: String { "Create new file with NewKit" }
    override var toolbarItemImage: NSImage {
        let img = NSImage(systemSymbolName: "plus.square.on.square",
                          accessibilityDescription: "NewKit") ?? NSImage()
        img.isTemplate = true
        return img
    }

    // MARK: - Menus

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let entries = resolveTypes()
        let summary = entries.map { $0.kind == "separator" ? "[sep]" : "[\($0.id)]" }.joined(separator: ",")
        Self.logger.info("menu(for:) kind=\(menuKind.rawValue, privacy: .public) entries=\(summary, privacy: .public)")
        let menu = NSMenu()
        tagToTypeID.removeAll()
        tagToActionID.removeAll()
        var nextTag = 1
        for entry in entries {
            // Finder's contextual menu (kind=1) merges our items into its own menu and breaks
            // when given a view-based menu item — the entire submenu vanishes. Falling back to
            // NSMenuItem.separator() keeps the file types visible; in this context it renders
            // as a thin gap rather than the styled line we use elsewhere.
            if entry.kind == "separator" {
                menu.addItem(.separator())
                continue
            }
            let tag = nextTag; nextTag += 1
            if entry.kind == "action" {
                tagToActionID[tag] = entry.id
            } else {
                tagToTypeID[tag] = entry.id
            }
            let item = NSMenuItem(title: entry.title, action: #selector(handle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            if let symbol = entry.symbolName,
               let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                item.image = img
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func handle(_ sender: NSMenuItem) {
        Self.logger.info("handle FIRED title=\(sender.title, privacy: .public) tag=\(sender.tag, privacy: .public)")
        let target = resolveTargetURL()
        let payloadID: String
        if let actionID = tagToActionID[sender.tag] {
            payloadID = actionID
        } else if let typeID = tagToTypeID[sender.tag],
                  resolveTypes().contains(where: { $0.id == typeID }) {
            payloadID = typeID
        } else {
            Self.logger.error("handle: cannot resolve entry for tag=\(sender.tag, privacy: .public)")
            return
        }
        Self.logger.info("handle id=\(payloadID, privacy: .public) target=\(target.path, privacy: .public)")
        let dropped = dropPendingCommand(typeID: payloadID, folderPath: target.path)
        Self.logger.info("dropped=\(dropped?.path ?? "nil", privacy: .public)")
        let appURL = URL(fileURLWithPath: "/Applications/NewKit.app")
        FIFinderSyncController.default().open(appURL) { ok in
            Self.logger.info("open(app) ok=\(ok, privacy: .public)")
        }
    }

    private func dropPendingCommand(typeID: String, folderPath: String) -> URL? {
        let fm = FileManager.default
        guard let group = fm.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            Self.logger.error("no app group container")
            return nil
        }
        Self.logger.info("group container=\(group.path, privacy: .public)")
        let pending = group.appendingPathComponent("Pending", isDirectory: true)
        do {
            try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("mkdir pending failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let payload: [String: String] = ["type": typeID, "path": folderPath]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let file = pending.appendingPathComponent(UUID().uuidString + ".json")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            Self.logger.error("write pending failed: \(error.localizedDescription, privacy: .public)")
            return nil
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
        let kind: String     // "type" or "separator" — old snapshots default to "type"
        let id: String
        let ext: String?
        let symbolName: String?
        let title: String
        let isFolder: Bool

        enum CodingKeys: String, CodingKey {
            case kind, id, ext, symbolName, title, isFolder
        }

        init(kind: String, id: String, ext: String?, symbolName: String?,
             title: String, isFolder: Bool) {
            self.kind = kind; self.id = id; self.ext = ext
            self.symbolName = symbolName; self.title = title; self.isFolder = isFolder
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = (try? c.decode(String.self, forKey: .kind)) ?? "type"
            self.id = try c.decode(String.self, forKey: .id)
            self.ext = try c.decodeIfPresent(String.self, forKey: .ext)
            self.symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
            self.title = try c.decode(String.self, forKey: .title)
            self.isFolder = try c.decode(Bool.self, forKey: .isFolder)
        }
    }

    private func resolveTypes() -> [Snapshot] {
        if let data = sharedDefaults?.data(forKey: "visibleTypesSnapshot"),
           let list = try? JSONDecoder().decode([Snapshot].self, from: data),
           !list.isEmpty {
            return list
        }
        // Fallback: minimal hardcoded list so the menu is never empty.
        return [
            Snapshot(kind: "type", id: "txt", ext: "txt", symbolName: "doc.text",
                     title: "Text File (.txt)", isFolder: false),
            Snapshot(kind: "type", id: "md",  ext: "md",  symbolName: "doc.richtext",
                     title: "Markdown (.md)", isFolder: false),
            Snapshot(kind: "type", id: "folder", ext: nil, symbolName: "folder",
                     title: "Folder", isFolder: true),
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
