import CryptoKit
import Foundation

/// Lossless snapshots of both preference domains, including unknown future keys.
/// Domain names in an imported file never select where preferences are written.
struct ConfigurationBackup {
    enum Role: String, Codable, CaseIterable { case shared, application }

    struct Archive: Codable {
        struct Domain: Codable {
            let role: Role
            let payload: Data
            let sha256: String
        }

        var format = "com.codearthur.matrixapps.newkit.configuration-backup"
        var schemaVersion = 1
        let bundleIdentifier: String
        let createdAt: Date
        let createdWithVersion: String
        let createdWithBuild: String
        var domains: [Domain]
    }

    struct Store {
        let role: Role
        let name: String
        let defaults: UserDefaults
    }

    enum Failure: String, LocalizedError {
        case invalid, incompatible, checksum, unavailable, writeFailed
        var errorDescription: String? { L10n.string("backup.error.\(rawValue)") }
    }

    let bundleIdentifier: String
    let stores: [Store]

    // These are crash-recovery breadcrumbs for the current hardware session,
    // not user choices. Back them up, but preserve the live values on restore.
    private static let runtimeKeys = [
        "BuiltInDisplayDisabledNeedsRecovery", "BuiltInDisplaySavedBrightness"
    ]

    static func current() throws -> Self {
        guard let bundle = Bundle.main.bundleIdentifier else { throw Failure.unavailable }
#if DEBUG
        let sharedName = bundle
        let shared = UserDefaults.standard
#else
        let sharedName = SharedDefaults.appGroupID
        guard let shared = UserDefaults(suiteName: sharedName),
              FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: sharedName) != nil else {
            throw Failure.unavailable
        }
#endif
        return Self(bundleIdentifier: bundle, stores: [
            Store(role: .shared, name: sharedName, defaults: shared),
            Store(role: .application, name: bundle, defaults: .standard)
        ])
    }

    func capture() throws -> Archive {
        let domains = try stores.map { store in
            // UserDefaults maintains the in-process snapshot automatically.
            // synchronize() can return false in a live AppKit app even when
            // its preferences are readable; that is not a read-success flag.
            let persisted = store.defaults.persistentDomain(forName: store.name)
            let values = persisted ?? [:]
            guard store.role != .shared || !values.isEmpty else { throw Failure.unavailable }
            let payload = try PropertyListSerialization.data(
                fromPropertyList: values, format: .binary, options: 0)
            return Archive.Domain(role: store.role, payload: payload, sha256: Self.digest(payload))
        }
        return Archive(
            bundleIdentifier: bundleIdentifier, createdAt: Date(),
            createdWithVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            createdWithBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            domains: domains
        )
    }

    func validate(_ archive: Archive) throws -> [Role: [String: Any]] {
        guard archive.format == Archive.formatIdentifier, archive.schemaVersion == 1,
              archive.bundleIdentifier == bundleIdentifier else { throw Failure.incompatible }
        guard archive.domains.count == Role.allCases.count,
              Set(archive.domains.map(\.role)) == Set(Role.allCases) else { throw Failure.invalid }
        var result: [Role: [String: Any]] = [:]
        for domain in archive.domains {
            guard domain.sha256 == Self.digest(domain.payload) else { throw Failure.checksum }
            guard let values = try PropertyListSerialization.propertyList(
                from: domain.payload, options: [], format: nil) as? [String: Any] else {
                throw Failure.invalid
            }
            result[domain.role] = values
        }
        // Reject a damaged menu-bar assignment rather than quietly losing a
        // hidden group when MenuBarOrganizer decodes its saved configuration.
        if let shared = result[.shared] {
            if let order = shared["menuBarOrganizerOrder"], !(order is [String]) {
                throw Failure.invalid
            }
            if let assignments = shared["menuBarOrganizerAssignments"] {
                guard let data = assignments as? Data,
                      let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      entries.allSatisfy({ entry in
                          entry["bundleIdentifier"] is String && entry["name"] is String
                              && ["visible", "hidden", "alwaysHidden"].contains(entry["group"] as? String ?? "")
                      }) else { throw Failure.invalid }
            }
        }
        return result
    }

    func save(_ archive: Archive, to url: URL) throws {
        _ = try validate(archive)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(archive).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Confirm the actual file on disk can be read and passes all checks.
        _ = try load(from: url)
    }

    func load(from url: URL) throws -> Archive {
        let archive: Archive
        do { archive = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: url)) }
        catch { throw Failure.invalid }
        _ = try validate(archive)
        return archive
    }

    /// Run only before configuration singletons and keyboard shortcuts start.
    /// All domains are validated first, and a failed write rolls both back.
    func restore(_ archive: Archive) throws {
        let values = try validate(archive)
        let originals = stores.map { $0.defaults.persistentDomain(forName: $0.name) ?? [:] }
        var targets = stores.map { values[$0.role]! }
        let applicationNames = Set(stores.filter { $0.role == .application }.map(\.name))
        for index in stores.indices where applicationNames.contains(stores[index].name) {
            for key in Self.runtimeKeys {
                targets[index][key] = originals[index][key]
            }
        }
        // Debug uses one physical domain for both roles. It must have one
        // unambiguous value instead of overwriting one role with the other.
        for left in stores.indices {
            for right in stores.indices where right > left && stores[left].name == stores[right].name {
                guard NSDictionary(dictionary: targets[left]).isEqual(to: targets[right]) else {
                    throw Failure.invalid
                }
            }
        }
        do {
            for index in stores.indices {
                stores[index].defaults.setPersistentDomain(targets[index], forName: stores[index].name)
            }
            for index in stores.indices {
                guard stores[index].defaults.synchronize(),
                      NSDictionary(dictionary: targets[index]).isEqual(to:
                        stores[index].defaults.persistentDomain(forName: stores[index].name) ?? [:]) else {
                    throw Failure.writeFailed
                }
            }
        } catch {
            for index in stores.indices {
                stores[index].defaults.setPersistentDomain(originals[index], forName: stores[index].name)
                stores[index].defaults.synchronize()
            }
            throw error
        }
    }

    func differences(from archive: Archive) throws -> [String: [String]] {
        let values = try validate(archive)
        var result: [String: [String]] = [:]
        for store in stores {
            let current = store.defaults.persistentDomain(forName: store.name) ?? [:]
            let saved = values[store.role]!
            let changed = Set(current.keys).union(saved.keys).filter { key in
                !NSDictionary(dictionary: current[key].map { [key: $0] } ?? [:])
                    .isEqual(to: saved[key].map { [key: $0] } ?? [:])
            }.sorted()
            if !changed.isEmpty { result[store.role.rawValue] = changed }
        }
        return result
    }

    static func backupDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("NewKit/Configuration Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func fileName(prefix: String = "NewKit-Settings") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(prefix)-\(formatter.string(from: Date())).plist"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension ConfigurationBackup.Archive {
    static let formatIdentifier = "com.codearthur.matrixapps.newkit.configuration-backup"
}
