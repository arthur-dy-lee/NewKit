import Foundation

/// User-selectable UI language. `system` follows the OS preference; the others pin a
/// specific lproj bundle so menus, settings and templates render in that language.
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Displayed in the language picker. Each option shows its name in its own language so
    /// users can recognise the right one even if the current UI is the wrong language.
    var displayName: String {
        switch self {
        case .system:  return L10n.string("language.system")
        case .zhHans:  return "简体中文"
        case .english: return "English"
        }
    }
}

/// Localized string lookup with optional per-user language override.
///
/// Reads `uiLanguage` from shared defaults so every call honours the latest selection
/// without restarting the app (and so non-MainActor contexts can localize too).
enum L10n {
    static let preferenceKey = "uiLanguage"

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func tab(_ key: String) -> String {
        string("settings.tab.\(key)")
    }

    private static var bundle: Bundle {
        let raw = SharedDefaults.store.string(forKey: preferenceKey)
            ?? AppLanguage.system.rawValue
        switch raw {
        case AppLanguage.zhHans.rawValue:  return lproj("zh-Hans") ?? .main
        case AppLanguage.english.rawValue: return lproj("en") ?? .main
        default:                           return .main
        }
    }

    private static let bundleCache = BundleCache()

    private static func lproj(_ name: String) -> Bundle? {
        bundleCache.bundle(for: name)
    }
}

private final class BundleCache: @unchecked Sendable {
    private var cache: [String: Bundle] = [:]
    private let lock = NSLock()

    func bundle(for name: String) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        cache[name] = bundle
        return bundle
    }
}
