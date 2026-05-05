import Combine
import Foundation

/// What happens after a file is created.
enum PostCreateBehavior: String, Codable, CaseIterable, Identifiable {
    case revealAndRename
    case openInDefaultApp

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .revealAndRename: return NSLocalizedString("post.reveal", comment: "")
        case .openInDefaultApp: return NSLocalizedString("post.open", comment: "")
        }
    }
}

/// Persisted user configuration. Source of truth is UserDefaults; values are mirrored to
/// `@Published` properties so SwiftUI views can bind directly. Changes are also broadcast via
/// `NotificationCenter` so non-SwiftUI subscribers (e.g. `StatusBarController`) can react.
@MainActor
final class Configuration: ObservableObject {
    static let shared = Configuration()
    static let didChange = Notification.Name("NewKit.ConfigurationDidChange")

    private let defaults: UserDefaults
    private enum Key {
        static let orderedIDs        = "orderedFileTypeIDs"     // [String] full canonical order
        static let disabledIDs       = "disabledFileTypeIDs"    // [String] subset that is hidden
        static let customTypes       = "customFileTypes"        // Data (encoded [FileType])
        static let postCreateBehavior = "postCreateBehavior"    // String (PostCreateBehavior raw)
        static let author            = "author"                 // String (used for {{author}})
        static let templateOverrides = "templateOverrides"      // Data (encoded [String:String])
        static let showMenuBarIcon   = "showMenuBarIcon"        // Bool (default true)
        static let didSeed           = "didSeedDefaults_v2"     // Bool
    }

    /// Canonical display order of every known type (enabled or disabled, built-in or custom).
    @Published var orderedIDs: [String] {
        didSet {
            defaults.set(orderedIDs, forKey: Key.orderedIDs)
            broadcast()
        }
    }

    /// IDs that are hidden from menus.
    @Published var disabledIDs: Set<String> {
        didSet {
            defaults.set(Array(disabledIDs), forKey: Key.disabledIDs)
            broadcast()
        }
    }

    @Published var customTypes: [FileType] {
        didSet {
            let data = (try? JSONEncoder().encode(customTypes)) ?? Data()
            defaults.set(data, forKey: Key.customTypes)
            reconcileOrder()
            broadcast()
        }
    }

    @Published var postCreateBehavior: PostCreateBehavior {
        didSet {
            defaults.set(postCreateBehavior.rawValue, forKey: Key.postCreateBehavior)
            broadcast()
        }
    }

    /// Used to fill the `{{author}}` placeholder in templates.
    @Published var author: String {
        didSet {
            defaults.set(author, forKey: Key.author)
            broadcast()
        }
    }

    /// Per-type template overrides keyed by FileType id. Built-ins use these to override their
    /// default template; custom types already store their template inline.
    @Published var templateOverrides: [String: String] {
        didSet {
            let data = (try? JSONEncoder().encode(templateOverrides)) ?? Data()
            defaults.set(data, forKey: Key.templateOverrides)
            broadcast()
        }
    }

    /// Whether to show the menu bar icon. When false, users must rely on Finder integration
    /// (right-click / toolbar) or the global shortcut.
    @Published var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon)
            broadcast()
        }
    }

    private init(defaults: UserDefaults = SharedDefaults.store) {
        self.defaults = defaults

        // Seed first run with all built-ins enabled in registry order.
        if !defaults.bool(forKey: Key.didSeed) {
            defaults.set(FileTypeRegistry.builtIns.map(\.id), forKey: Key.orderedIDs)
            defaults.set([String](), forKey: Key.disabledIDs)
            defaults.set(PostCreateBehavior.revealAndRename.rawValue, forKey: Key.postCreateBehavior)
            defaults.set(true, forKey: Key.didSeed)
        }

        // Load.
        self.orderedIDs = defaults.stringArray(forKey: Key.orderedIDs)
            ?? FileTypeRegistry.builtIns.map(\.id)
        self.disabledIDs = Set(defaults.stringArray(forKey: Key.disabledIDs) ?? [])
        if let data = defaults.data(forKey: Key.customTypes),
           let list = try? JSONDecoder().decode([FileType].self, from: data) {
            self.customTypes = list
        } else {
            self.customTypes = []
        }
        let raw = defaults.string(forKey: Key.postCreateBehavior) ?? ""
        self.postCreateBehavior = PostCreateBehavior(rawValue: raw) ?? .revealAndRename
        self.author = defaults.string(forKey: Key.author) ?? NSFullUserName()
        if let data = defaults.data(forKey: Key.templateOverrides),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            self.templateOverrides = dict
        } else {
            self.templateOverrides = [:]
        }
        self.showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true

        reconcileOrder()
        publishVisibleSnapshot()
    }

    // MARK: - Computed views

    /// All known types, resolved and sorted by orderedIDs.
    var allOrderedTypes: [FileType] {
        let pool: [String: FileType] = Dictionary(
            uniqueKeysWithValues: (FileTypeRegistry.builtIns + customTypes).map { ($0.id, $0) }
        )
        return orderedIDs.compactMap { pool[$0] }
    }

    /// Types currently visible in the menu (ordered, enabled only).
    var visibleTypes: [FileType] {
        allOrderedTypes.filter { !disabledIDs.contains($0.id) }
    }

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    func setEnabled(_ enabled: Bool, for id: String) {
        if enabled {
            disabledIDs.remove(id)
        } else {
            disabledIDs.insert(id)
        }
    }

    // MARK: - Mutations

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        orderedIDs.move(fromOffsets: source, toOffset: destination)
    }

    /// Adds a new custom type to the end of the order list.
    func addCustomType(_ type: FileType) {
        guard !type.isBuiltIn else { return }
        guard !allTypeIDs.contains(type.id) else { return }
        customTypes.append(type)            // triggers reconcileOrder via didSet
    }

    /// Removes a custom type by ID. Built-ins are ignored.
    func removeCustomType(id: String) {
        guard customTypes.contains(where: { $0.id == id }) else { return }
        customTypes.removeAll { $0.id == id }
        orderedIDs.removeAll { $0 == id }
        disabledIDs.remove(id)
    }

    func updateCustomType(_ type: FileType) {
        guard let idx = customTypes.firstIndex(where: { $0.id == type.id }) else { return }
        customTypes[idx] = type
    }

    // MARK: - Internal

    private var allTypeIDs: Set<String> {
        Set(FileTypeRegistry.builtIns.map(\.id) + customTypes.map(\.id))
    }

    /// Ensures orderedIDs contains exactly the union of built-ins + custom types,
    /// preserving the user's existing order, and appending any newcomers.
    private func reconcileOrder() {
        let known = allTypeIDs
        var next = orderedIDs.filter { known.contains($0) }
        for id in (FileTypeRegistry.builtIns.map(\.id) + customTypes.map(\.id))
            where !next.contains(id) {
            next.append(id)
        }
        if next != orderedIDs {
            orderedIDs = next
        }
    }

    private func broadcast() {
        publishVisibleSnapshot()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Writes a JSON snapshot of the current visible types into shared defaults so the
    /// Finder Sync extension (which can't import our types) can render the same menu.
    func publishVisibleSnapshot() {
        struct Snapshot: Codable {
            let id: String
            let ext: String?
            let symbolName: String?
            let title: String
            let isFolder: Bool
        }
        let snapshot = visibleTypes.map {
            Snapshot(id: $0.id, ext: $0.ext, symbolName: $0.symbolName,
                     title: $0.menuTitle, isFolder: $0.isFolder)
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: "visibleTypesSnapshot")
        }
    }
}
