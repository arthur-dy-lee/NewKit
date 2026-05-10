import Combine
import Foundation

/// What happens after a file is created.
enum PostCreateBehavior: String, Codable, CaseIterable, Identifiable {
    case revealAndRename
    case openInDefaultApp

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .revealAndRename: return L10n.string("post.reveal")
        case .openInDefaultApp: return L10n.string("post.open")
        }
    }
}

/// One row in the user's ordered "new file" list — either a real file type or a separator
/// the user inserted to group entries visually.
enum MenuEntry: Identifiable {
    case fileType(FileType)
    case separator(id: String, label: String?)

    var id: String {
        switch self {
        case .fileType(let t):       return t.id
        case .separator(let id, _):  return id
        }
    }

    var isSeparator: Bool {
        if case .separator = self { return true }
        return false
    }
}

/// Persisted user configuration. Source of truth is UserDefaults; values are mirrored to
/// `@Published` properties so SwiftUI views can bind directly. Changes are also broadcast via
/// `NotificationCenter` so non-SwiftUI subscribers (e.g. `StatusBarController`) can react.
@MainActor
final class Configuration: ObservableObject {
    static let shared = Configuration()
    static let didChange = Notification.Name("NewKit.ConfigurationDidChange")

    /// Prefix used for separator entries inside `orderedIDs`. Anything starting with this is
    /// treated as a divider rather than a file type.
    static let separatorIDPrefix = "__separator__."

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
        static let language          = L10n.preferenceKey       // String (AppLanguage raw)
        static let defaultNameOverrides = "defaultNameOverrides" // Data ([String:String])
        static let separatorLabels   = "separatorLabels"        // Data ([String:String])
        static let showSeparatorsInRightClick = "showSeparatorsInRightClickMenu" // Bool
        static let showOpenTerminal  = "showOpenTerminal"        // Bool (default true)
        // Legacy keys (pre-split). Read once at init for migration, then ignored.
        static let legacyInvertVertical   = "invertVerticalScroll"
        static let legacyInvertHorizontal = "invertHorizontalScroll"
        static let legacyInvertTrackpad   = "invertTrackpadScroll"
        static let invertMouseScroll              = "invertMouseScroll"             // Bool (default false) — mouse wheel, vertical only
        static let invertTrackpadVerticalScroll   = "invertTrackpadVerticalScroll"  // Bool (default false)
        static let invertTrackpadHorizontalScroll = "invertTrackpadHorizontalScroll"// Bool (default false)
        static let preventSleep        = "preventSleep"        // Bool (default false)
        static let preventDisplaySleep = "preventDisplaySleep" // Bool (default false)
        static let appearance          = "appearance"          // String (AppAppearance raw)
        static let smoothScrollEnabled       = "smoothScrollEnabled"        // Bool (default false)
        static let smoothScrollMultiplier    = "smoothScrollMultiplier"     // Double (default 1.0)
        static let smoothScrollDurationMs    = "smoothScrollDurationMs"     // Double (default 220)
        static let linearPointerEnabled      = "linearPointerEnabled"       // Bool (default false)
        static let pointerSpeedMultiplier    = "pointerSpeedMultiplier"     // Double (default 1.0)
    }

    /// Canonical display order of every known type (enabled or disabled, built-in or custom)
    /// plus any user-inserted separator IDs.
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

    /// User-selected UI language. Defaults to following the system.
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            broadcast()
        }
    }

    /// Per-type default filename overrides keyed by FileType id. When set and non-empty,
    /// new files of that type use the override instead of the localized default.
    @Published var defaultNameOverrides: [String: String] {
        didSet {
            let data = (try? JSONEncoder().encode(defaultNameOverrides)) ?? Data()
            defaults.set(data, forKey: Key.defaultNameOverrides)
            broadcast()
        }
    }

    /// Optional labels for separators, keyed by separator ID. Empty/missing values render as
    /// a plain divider; non-empty values render as a disabled section header above the divider.
    @Published var separatorLabels: [String: String] {
        didSet {
            let data = (try? JSONEncoder().encode(separatorLabels)) ?? Data()
            defaults.set(data, forKey: Key.separatorLabels)
            broadcast()
        }
    }

    /// Whether separators are rendered in the Control + right-click menu. Other entry points
    /// (status bar, Finder toolbar) always show separators.
    @Published var showSeparatorsInRightClickMenu: Bool {
        didSet {
            defaults.set(showSeparatorsInRightClickMenu, forKey: Key.showSeparatorsInRightClick)
            broadcast()
        }
    }

    /// Whether the built-in "Open Terminal" action is shown across all menus.
    @Published var showOpenTerminal: Bool {
        didSet {
            defaults.set(showOpenTerminal, forKey: Key.showOpenTerminal)
            broadcast()
        }
    }

    /// Reverse mouse-wheel vertical direction. Horizontal is intentionally not
    /// exposed — almost no one tilts a mouse wheel sideways, and lumping it in
    /// would produce surprises for the few that do.
    @Published var invertMouseScroll: Bool {
        didSet {
            defaults.set(invertMouseScroll, forKey: Key.invertMouseScroll)
            broadcast()
        }
    }

    /// Reverse trackpad / Magic Mouse vertical direction.
    @Published var invertTrackpadVerticalScroll: Bool {
        didSet {
            defaults.set(invertTrackpadVerticalScroll, forKey: Key.invertTrackpadVerticalScroll)
            broadcast()
        }
    }

    /// Reverse trackpad / Magic Mouse horizontal direction.
    @Published var invertTrackpadHorizontalScroll: Bool {
        didSet {
            defaults.set(invertTrackpadHorizontalScroll, forKey: Key.invertTrackpadHorizontalScroll)
            broadcast()
        }
    }

    /// Prevent the system from going to idle sleep (Caffeine-style).
    @Published var preventSleep: Bool {
        didSet {
            defaults.set(preventSleep, forKey: Key.preventSleep)
            broadcast()
        }
    }

    /// Also keep the display awake while preventing sleep. Only meaningful when
    /// `preventSleep` is true.
    @Published var preventDisplaySleep: Bool {
        didSet {
            defaults.set(preventDisplaySleep, forKey: Key.preventDisplaySleep)
            broadcast()
        }
    }

    /// Light/dark/system appearance override.
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            broadcast()
        }
    }

    /// Smooth out discrete mouse-wheel scrolling into pixel-precise animated steps.
    /// Trackpad and Magic Mouse continuous scrolls are left untouched.
    @Published var smoothScrollEnabled: Bool {
        didSet {
            defaults.set(smoothScrollEnabled, forKey: Key.smoothScrollEnabled)
            broadcast()
        }
    }

    /// Distance multiplier applied to each wheel notch (1.0 = default ~30 px per line).
    /// Range 0.25–3.0.
    @Published var smoothScrollMultiplier: Double {
        didSet {
            defaults.set(smoothScrollMultiplier, forKey: Key.smoothScrollMultiplier)
            broadcast()
        }
    }

    /// Approximate animation length for one wheel notch, in milliseconds.
    /// Range 80–600. Higher = floatier; lower = snappier.
    @Published var smoothScrollDurationMs: Double {
        didSet {
            defaults.set(smoothScrollDurationMs, forKey: Key.smoothScrollDurationMs)
            broadcast()
        }
    }

    /// Disable Mac's pointer acceleration for plugged-in mice (linear movement,
    /// like Windows). Trackpad acceleration is intentionally left intact.
    @Published var linearPointerEnabled: Bool {
        didSet {
            defaults.set(linearPointerEnabled, forKey: Key.linearPointerEnabled)
            broadcast()
        }
    }

    /// Mouse pointer speed multiplier when linearization is on.
    /// Range 0.25–3.0; 1.0 = system default resolution.
    @Published var pointerSpeedMultiplier: Double {
        didSet {
            defaults.set(pointerSpeedMultiplier, forKey: Key.pointerSpeedMultiplier)
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
        self.language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "")
            ?? .system
        if let data = defaults.data(forKey: Key.defaultNameOverrides),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            self.defaultNameOverrides = dict
        } else {
            self.defaultNameOverrides = [:]
        }
        if let data = defaults.data(forKey: Key.separatorLabels),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            self.separatorLabels = dict
        } else {
            self.separatorLabels = [:]
        }
        self.showSeparatorsInRightClickMenu =
            defaults.object(forKey: Key.showSeparatorsInRightClick) as? Bool ?? true
        self.showOpenTerminal =
            defaults.object(forKey: Key.showOpenTerminal) as? Bool ?? true
        // Migrate older shapes of the toggle:
        //   - Pre-split (one V/H pair for everything) → mouse vertical follows
        //     the legacy V flag.
        //   - Combined-trackpad (single trackpad on/off) → both V and H trackpad
        //     follow it.
        let legacyMouseV = defaults.object(forKey: Key.legacyInvertVertical) as? Bool ?? false
        let legacyTrackpadCombined = defaults.object(forKey: Key.legacyInvertTrackpad) as? Bool ?? false
        self.invertMouseScroll =
            defaults.object(forKey: Key.invertMouseScroll) as? Bool ?? legacyMouseV
        self.invertTrackpadVerticalScroll =
            defaults.object(forKey: Key.invertTrackpadVerticalScroll) as? Bool ?? legacyTrackpadCombined
        self.invertTrackpadHorizontalScroll =
            defaults.object(forKey: Key.invertTrackpadHorizontalScroll) as? Bool ?? legacyTrackpadCombined
        self.preventSleep =
            defaults.object(forKey: Key.preventSleep) as? Bool ?? false
        self.preventDisplaySleep =
            defaults.object(forKey: Key.preventDisplaySleep) as? Bool ?? false
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "")
            ?? .system
        self.smoothScrollEnabled =
            defaults.object(forKey: Key.smoothScrollEnabled) as? Bool ?? false
        self.smoothScrollMultiplier =
            (defaults.object(forKey: Key.smoothScrollMultiplier) as? Double).map { max(0.25, min(3.0, $0)) } ?? 1.0
        self.smoothScrollDurationMs =
            (defaults.object(forKey: Key.smoothScrollDurationMs) as? Double).map { max(80, min(600, $0)) } ?? 220
        self.linearPointerEnabled =
            defaults.object(forKey: Key.linearPointerEnabled) as? Bool ?? false
        self.pointerSpeedMultiplier =
            (defaults.object(forKey: Key.pointerSpeedMultiplier) as? Double).map { max(0.25, min(3.0, $0)) } ?? 1.0

        reconcileOrder()
        publishVisibleSnapshot()
    }

    // MARK: - Computed views

    /// All known types, resolved and sorted by orderedIDs (separator entries skipped).
    var allOrderedTypes: [FileType] {
        let pool: [String: FileType] = Dictionary(
            uniqueKeysWithValues: (FileTypeRegistry.builtIns + customTypes).map { ($0.id, $0) }
        )
        return orderedIDs.compactMap { pool[$0] }
    }

    /// All entries in display order — file types interleaved with separators.
    var allOrderedEntries: [MenuEntry] {
        let pool: [String: FileType] = Dictionary(
            uniqueKeysWithValues: (FileTypeRegistry.builtIns + customTypes).map { ($0.id, $0) }
        )
        return orderedIDs.compactMap { id in
            if Self.isSeparatorID(id) {
                return .separator(id: id, label: separatorLabels[id])
            }
            return pool[id].map { .fileType($0) }
        }
    }

    /// Types currently visible in the menu (ordered, enabled only).
    var visibleTypes: [FileType] {
        allOrderedTypes.filter { !disabledIDs.contains($0.id) }
    }

    /// Visible entries (enabled types and all separators) in display order. Leading and
    /// trailing separators are stripped so menus never start or end with a divider.
    var visibleEntries: [MenuEntry] {
        let kept: [MenuEntry] = allOrderedEntries.compactMap { entry in
            switch entry {
            case .fileType(let t):
                return disabledIDs.contains(t.id) ? nil : entry
            case .separator:
                return entry
            }
        }
        return Self.trimAndCollapseSeparators(kept)
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

    /// Sets/clears the per-type default filename. Empty trimmed values clear the override.
    func setDefaultNameOverride(_ name: String, for typeID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaultNameOverrides.removeValue(forKey: typeID)
        } else {
            defaultNameOverrides[typeID] = trimmed
        }
    }

    /// Inserts a new separator. When `beforeID` is non-nil and present in `orderedIDs`, the
    /// separator is inserted directly above that row (so users can put a line before, e.g.,
    /// "New Text File" to mark the start of NewKit's right-click items). Otherwise it is
    /// appended at the end.
    @discardableResult
    func addSeparator(beforeID: String? = nil) -> String {
        let id = Self.separatorIDPrefix + UUID().uuidString
        if let beforeID, let idx = orderedIDs.firstIndex(of: beforeID) {
            orderedIDs.insert(id, at: idx)
        } else {
            orderedIDs.append(id)
        }
        return id
    }

    /// Reorders `id` to sit immediately before `targetID`. No-op when either is missing or
    /// the move would be a self-drop. Used by drag-and-drop in the file types list.
    func moveEntry(_ id: String, before targetID: String) {
        guard id != targetID,
              let from = orderedIDs.firstIndex(of: id),
              let toRaw = orderedIDs.firstIndex(of: targetID) else { return }
        let item = orderedIDs.remove(at: from)
        let to = from < toRaw ? toRaw - 1 : toRaw
        orderedIDs.insert(item, at: to)
    }

    /// Moves the entry with `id` up or down by one slot. No-op at the boundaries.
    func moveEntry(id: String, direction: Int) {
        guard let idx = orderedIDs.firstIndex(of: id) else { return }
        let target = idx + direction
        guard target >= 0, target < orderedIDs.count else { return }
        orderedIDs.swapAt(idx, target)
    }

    func removeSeparator(id: String) {
        guard Self.isSeparatorID(id) else { return }
        orderedIDs.removeAll { $0 == id }
        separatorLabels.removeValue(forKey: id)
    }

    func setSeparatorLabel(_ label: String, for id: String) {
        guard Self.isSeparatorID(id) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            separatorLabels.removeValue(forKey: id)
        } else {
            separatorLabels[id] = trimmed
        }
    }

    static func isSeparatorID(_ id: String) -> Bool {
        id.hasPrefix(separatorIDPrefix)
    }

    // MARK: - Internal

    private var allTypeIDs: Set<String> {
        Set(FileTypeRegistry.builtIns.map(\.id) + customTypes.map(\.id))
    }

    /// Ensures orderedIDs contains exactly the union of built-ins + custom types (preserving
    /// user order, appending newcomers) plus any user-inserted separator IDs.
    private func reconcileOrder() {
        let known = allTypeIDs
        var next = orderedIDs.filter { known.contains($0) || Self.isSeparatorID($0) }
        for id in (FileTypeRegistry.builtIns.map(\.id) + customTypes.map(\.id))
            where !next.contains(id) {
            next.append(id)
        }
        if next != orderedIDs {
            orderedIDs = next
        }
        // Drop orphaned separator labels.
        let liveSeps = Set(orderedIDs.filter { Self.isSeparatorID($0) })
        for k in separatorLabels.keys where !liveSeps.contains(k) {
            separatorLabels.removeValue(forKey: k)
        }
    }

    /// Collapses adjacent separators into one, but keeps leading and trailing separators —
    /// users intentionally place a line before the first item to mark the start of NewKit's
    /// section in Finder's contextual menu.
    private static func trimAndCollapseSeparators(_ entries: [MenuEntry]) -> [MenuEntry] {
        var result: [MenuEntry] = []
        for entry in entries {
            if entry.isSeparator, result.last?.isSeparator == true { continue }
            result.append(entry)
        }
        return result
    }

    private func broadcast() {
        publishVisibleSnapshot()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Writes a JSON snapshot of the current visible entries into shared defaults so the
    /// Finder Sync extension (which can't import our types) can render the same menu.
    func publishVisibleSnapshot() {
        struct Snapshot: Codable {
            let kind: String      // "type" or "separator"
            let id: String
            let ext: String?
            let symbolName: String?
            let title: String     // type title or separator label ("" if none)
            let isFolder: Bool
        }
        var snapshot: [Snapshot] = visibleEntries.map { entry in
            switch entry {
            case .fileType(let t):
                return Snapshot(kind: "type", id: t.id, ext: t.ext,
                                symbolName: t.symbolName, title: t.menuTitle,
                                isFolder: t.isFolder)
            case .separator(let id, let label):
                return Snapshot(kind: "separator", id: id, ext: nil,
                                symbolName: nil, title: label ?? "", isFolder: false)
            }
        }
        // Built-in "Open Terminal" action — appended without a leading separator so it
        // sits flush against the file types list.
        if showOpenTerminal {
            snapshot.append(Snapshot(kind: "action",
                                     id: TerminalOpener.actionID,
                                     ext: nil,
                                     symbolName: "terminal",
                                     title: L10n.string("menu.openterminal"),
                                     isFolder: false))
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: "visibleTypesSnapshot")
        }
    }
}
