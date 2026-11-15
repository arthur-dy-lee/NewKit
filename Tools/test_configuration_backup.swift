import Foundation

private final class FailingDefaults: UserDefaults, @unchecked Sendable {
    var failNextSync = false

    override func synchronize() -> Bool {
        if failNextSync {
            failNextSync = false
            return false
        }
        return super.synchronize()
    }
}

@main
enum ConfigurationBackupChecks {
    static func main() throws {
        let prefix = "com.codearthur.newkit.backup-tests.\(UUID().uuidString)"
        let sharedName = prefix + ".shared"
        let appName = prefix + ".app"
        let shared = UserDefaults(suiteName: sharedName)!
        let app = FailingDefaults(suiteName: appName)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            shared.removePersistentDomain(forName: sharedName)
            app.removePersistentDomain(forName: appName)
            try? FileManager.default.removeItem(at: folder)
        }
        let service = ConfigurationBackup(bundleIdentifier: prefix, stores: [
            .init(role: .shared, name: sharedName, defaults: shared),
            .init(role: .application, name: appName, defaults: app)
        ])
        let assignments = try JSONSerialization.data(withJSONObject: [
            ["bundleIdentifier": "app.visible", "name": "Visible", "group": "visible"],
            ["bundleIdentifier": "app.hidden", "name": "Hidden", "group": "hidden"],
            ["bundleIdentifier": "app.always", "name": "Always", "group": "alwaysHidden"]
        ])
        let sharedValues: [String: Any] = [
            "didSeedDefaults_v2": true,
            "menuBarOrganizerEnabled": true,
            "menuBarOrganizerOrder": ["app.hidden", "app.visible", "app.always"],
            "menuBarOrganizerAssignments": assignments,
            "customFileTypes": Data("custom templates".utf8),
            "unknownFutureSetting": ["nested": ["data": Data([1, 2, 3])]],
            "created": Date(timeIntervalSince1970: 1_700_000_000),
            "smoothScrollMultiplier": 1.75,
            "emptyArray": [String]()
        ]
        let appValues: [String: Any] = [
            "KeyboardShortcuts_toggleFloatingPanel": "{shortcut}",
            "NSStatusItem Preferred Position NewKit.MenuBarOrganizer": 140,
            "BuiltInDisplayDisabledNeedsRecovery": false,
            "BuiltInDisplaySavedBrightness": 0.75
        ]
        shared.setPersistentDomain(sharedValues, forName: sharedName)
        app.setPersistentDomain(appValues, forName: appName)
        let archive = try service.capture()
        // Reading a live GUI application's snapshot must not depend on the
        // obsolete synchronize() return value. Write verification still does.
        app.failNextSync = true
        let liveRead = try service.capture()
        let liveValues = try service.validate(liveRead)
        assert(liveValues[.application]?["KeyboardShortcuts_toggleFloatingPanel"] as? String == "{shortcut}")
        app.failNextSync = false
        let file = folder.appendingPathComponent("settings.plist")
        try service.save(archive, to: file)
        let roundTrip = try service.load(from: file)
        let differences = try service.differences(from: roundTrip)
        assert(differences.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        assert(permissions?.intValue == 0o600)

        // A complete restore removes post-backup keys and preserves native
        // property-list types, shortcut values, icon groups and icon order.
        shared.setPersistentDomain(["addedLater": true], forName: sharedName)
        app.setPersistentDomain(["addedLater": true], forName: appName)
        try service.restore(roundTrip)
        assert(NSDictionary(dictionary: sharedValues).isEqual(to:
            shared.persistentDomain(forName: sharedName)!))
        let restoredApp = app.persistentDomain(forName: appName)!
        assert(restoredApp["KeyboardShortcuts_toggleFloatingPanel"] as? String == "{shortcut}")
        assert(restoredApp["NSStatusItem Preferred Position NewKit.MenuBarOrganizer"] as? Int == 140)
        assert(restoredApp["addedLater"] == nil)
        assert(restoredApp["BuiltInDisplayDisabledNeedsRecovery"] == nil)

        // Old display-recovery breadcrumbs must not change live hardware state.
        app.set(true, forKey: "BuiltInDisplayDisabledNeedsRecovery")
        app.set(0.25, forKey: "BuiltInDisplaySavedBrightness")
        try service.restore(roundTrip)
        assert(app.bool(forKey: "BuiltInDisplayDisabledNeedsRecovery"))
        assert(app.double(forKey: "BuiltInDisplaySavedBrightness") == 0.25)

        var corrupt = roundTrip
        let domain = corrupt.domains[1]
        corrupt.domains[1] = .init(role: domain.role, payload: domain.payload + Data([0]), sha256: domain.sha256)
        let beforeFailure = shared.persistentDomain(forName: sharedName)!
        expectFailure { try service.restore(corrupt) }
        assert(NSDictionary(dictionary: beforeFailure).isEqual(to:
            shared.persistentDomain(forName: sharedName)!))
        var missing = roundTrip
        missing.domains.removeLast()
        expectFailure { try service.restore(missing) }
        var future = roundTrip
        future.schemaVersion = 2
        expectFailure { try service.restore(future) }

        // Fail the second domain's flush after both writes. Both complete
        // original domains must be restored, including post-backup keys.
        shared.set("keep shared", forKey: "addedBeforeFailedRestore")
        app.set("keep app", forKey: "addedBeforeFailedRestore")
        let sharedBeforeWriteFailure = shared.persistentDomain(forName: sharedName)!
        let appBeforeWriteFailure = app.persistentDomain(forName: appName)!
        app.failNextSync = true
        expectFailure { try service.restore(roundTrip) }
        assert(NSDictionary(dictionary: sharedBeforeWriteFailure).isEqual(to:
            shared.persistentDomain(forName: sharedName)!))
        assert(NSDictionary(dictionary: appBeforeWriteFailure).isEqual(to:
            app.persistentDomain(forName: appName)!))

        shared.set(42, forKey: "menuBarOrganizerOrder")
        let invalidOrder = try service.capture()
        expectFailure { try service.save(invalidOrder, to: folder.appendingPathComponent("invalid.plist")) }

        // Debug aliases shared and app preferences to the same domain.
        let debug = ConfigurationBackup(bundleIdentifier: prefix, stores: [
            .init(role: .shared, name: appName, defaults: app),
            .init(role: .application, name: appName, defaults: app)
        ])
        let debugArchive = try debug.capture()
        app.set(false, forKey: "BuiltInDisplayDisabledNeedsRecovery")
        try debug.restore(debugArchive)
        assert(!app.bool(forKey: "BuiltInDisplayDisabledNeedsRecovery"))

        shared.removePersistentDomain(forName: sharedName)
        expectFailure { _ = try service.capture() }

        print("Configuration backup checks passed: roundtrip, full restore, groups/order, shortcuts, integrity, validation, write-failure rollback, live recovery state")
    }

    private static func expectFailure(_ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("Expected backup validation to fail")
        } catch { }
    }
}
