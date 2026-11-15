import AppKit

/// Applies position changes through macOS's menu bar preferences. The file
/// picker grants access to this one file, and CFPreferences notifies MenuBarAgent.
@MainActor
enum MenuBarSystemOrder {
    private static let bookmarkKey = "menuBarLayoutBookmark"
    private static let positionsKey = "TrailingItemPreferredPositions" as CFString
    private static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    enum Result {
        case updated(Int)
        case unchanged
        case accessNeeded
        case failed
    }

    static var hasBookmark: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    static func chooseFile() -> Bool {
        let panel = NSOpenPanel()
        panel.title = L10n.string("settings.iconmanager.layout.access")
        panel.message = L10n.string("settings.iconmanager.layout.choose")
        panel.directoryURL = file.deletingLastPathComponent()
        panel.prompt = L10n.string("settings.iconmanager.layout.grant")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL.path == file.path,
              url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }
        guard readPositions(domain(for: url)) != nil,
              let bookmark = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
              ) else { return false }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return true
    }

    static func apply(_ plan: MenuBarPhysicalOrder.Plan) -> Result {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return .accessNeeded }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.standardizedFileURL.path == file.path,
              url.startAccessingSecurityScopedResource() else { return .accessNeeded }
        defer { url.stopAccessingSecurityScopedResource() }
        if stale, let replacement = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(replacement, forKey: bookmarkKey)
        }

        let domain = domain(for: url)
        guard let current = readPositions(domain) else { return .accessNeeded }
        var positions = current
        for _ in 0..<2 {
            let values = positions.mapValues(\.doubleValue)
            guard values.values.allSatisfy({ $0.isFinite }) else { return .failed }
            let changes = plan.updates(positions: values, keys: positionKeys(in: positions.keys))
            guard !changes.isEmpty else { return .unchanged }
            // MenuBarAgent can add or update entries while a plan is prepared.
            guard let latest = readPositions(domain) else { return .accessNeeded }
            if latest != positions {
                positions = latest
                continue
            }
            for (key, value) in changes { positions[key] = NSNumber(value: value) }
            CFPreferencesSetValue(positionsKey, positions as CFDictionary, domain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
                return .failed
            }
            return .updated(changes.count)
        }
        return .failed
    }

    private static func domain(for url: URL) -> CFString {
        url.deletingPathExtension().path as CFString
    }

    private static func readPositions(_ domain: CFString) -> [String: NSNumber]? {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return nil
        }
        return CFPreferencesCopyValue(positionsKey, domain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: NSNumber]
    }

    private static func positionKeys(in keys: Dictionary<String, NSNumber>.Keys) -> [String: String] {
        var byOwner: [String: [String]] = [:]
        var dividerKeys: [String] = []
        for key in keys where key.hasPrefix("status:") {
            let parts = key.dropFirst("status:".count).components(separatedBy: "::")
            guard parts.count == 2 else { continue }
            byOwner[parts[0], default: []].append(key)
            if parts[1] == "NewKit.MenuBarOrganizer" { dividerKeys.append(key) }
        }
        var unique = byOwner.compactMapValues { $0.count == 1 ? $0.first : nil }
        if let bundle = Bundle.main.bundleIdentifier {
            let divider = dividerKeys.first { $0 == "status:\(bundle)::NewKit.MenuBarOrganizer" }
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            unique[MenuBarPhysicalOrder.dividerID] = divider ?? name.flatMap {
                let key = "status:\($0)::NewKit.MenuBarOrganizer"
                return dividerKeys.contains(key) ? key : nil
            }
        }
        return unique
    }
}
