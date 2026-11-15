import Foundation

final class FixturePlatform: OldVersionCleanup.Platform, @unchecked Sendable {
    // Each fixture is used synchronously by one test. No system registrations
    // or real Trash folders are touched by these policy checks.
    var records: [OldVersionCleanup.Registration] = []
    var discovered: [URL] = []
    var metadata: [String: OldVersionCleanup.Metadata] = [:]
    var running: [URL] = []
    var failTrash = false
    var failUnregister = false
    var mutationCount = 0
    let trashRoot: URL

    init(trashRoot: URL) { self.trashRoot = trashRoot }
    func registrations() throws -> [OldVersionCleanup.Registration] { records }
    func discover(extraRoots: [URL], context: OldVersionCleanup.Context) throws -> OldVersionCleanup.Discovery {
        .init(paths: discovered)
    }
    func inspect(_ url: URL, context: OldVersionCleanup.Context) throws -> OldVersionCleanup.Metadata? { metadata[url.path] }
    func runningExecutables() throws -> [URL] { running }
    func trash(_ url: URL) throws -> URL {
        if failTrash { throw OldVersionCleanup.CleanupFailure("fixture permission denied") }
        mutationCount += 1
        let destination = trashRoot.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        records = records.map { record in
            let path = record.path.hasPrefix(url.path)
                ? destination.path + record.path.dropFirst(url.path.count) : record.path
            return .init(kind: record.kind, identifier: record.identifier, path: String(path))
        }
        return destination
    }
    func unregister(_ registration: OldVersionCleanup.Registration) throws {
        if failUnregister { throw OldVersionCleanup.CleanupFailure("fixture registration failure") }
        mutationCount += 1
        records.removeAll { $0 == registration }
    }
    func registerCurrent(_ context: OldVersionCleanup.Context) throws {
        mutationCount += 1
        if !records.contains(where: { $0.path == context.currentApp.path }) {
            records.append(.init(kind: .application, identifier: context.metadata.identifier, path: context.currentApp.path))
        }
    }
}

@main
enum OldVersionCleanupChecks {
    typealias Cleanup = OldVersionCleanup
    static let identifier = "com.codearthur.matrixapps.newkit"

    static func main() throws {
        assert(Cleanup.compareNumbers("1.10.0", "1.9.9") == .orderedDescending)
        assert(Cleanup.compareNumbers("1.4", "1.4.0") == .orderedSame)
        assert(Cleanup.compareNumbers("1.4-beta", "1.4.0") == nil)
        assert(Cleanup.compareNumbers("1..4", "1.4.0") == nil)
        assert(Cleanup.compareNumbers("-1", "1") == nil)
        try oldBundleAndRelocatedRegistrations()
        try protectCurrentNewerRunningAndData()
        try sameVersionAndMissingRegistrations()
        try revalidateAndFailSafely()
        try parseSystemCatalogs()
        try rejectUnverifiedInstallers()
        print("Old-version cleanup checks passed: version ordering, current/alias/data/running/newer protection, nested plugins, same-version retention, stale records, revalidation, backup gate, partial failures, catalog parsing")
    }

    static func info(version: String = "1.4.2", build: String = "143", team: String = "OURTEAM") -> Cleanup.Metadata {
        .init(identifier: identifier, team: team, version: version, build: build, signature: "signed-\(version)-\(build)-\(team)")
    }

    static func fixture(_ operation: (URL, Cleanup.Context, FixturePlatform, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NewKit-cleanup-tests-\(UUID().uuidString)")
        let current = root.appendingPathComponent("Applications/NewKit.app")
        let trash = root.appendingPathComponent("Trash")
        let data = root.appendingPathComponent("NewKitData")
        for url in [current, trash, data] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Cleanup.Context(currentApp: current, metadata: info(version: "1.4.3", build: "144"),
                                      protectedRoots: [data], trashRoot: trash)
        let platform = FixturePlatform(trashRoot: trash)
        platform.metadata[current.path] = context.metadata
        let backup = data.appendingPathComponent("verified-backup.plist")
        try Data("fixture configuration backup".utf8).write(to: backup)
        try operation(root, context, platform, backup)
    }

    @discardableResult
    static func add(_ name: String, under root: URL, platform: FixturePlatform,
                    metadata: Cleanup.Metadata = info(), registered: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        platform.metadata[url.path] = metadata
        platform.discovered.append(url)
        if registered {
            platform.records.append(.init(kind: .application, identifier: identifier, path: url.path))
        }
        return url
    }

    static func oldBundleAndRelocatedRegistrations() throws {
        try fixture { root, context, platform, backup in
            let old = try add("Old/NewKit.app", under: root, platform: platform)
            let plugin = old.appendingPathComponent("Contents/PlugIns/NewKitFinderExtension.appex")
            platform.records.append(.init(kind: .plugin, identifier: identifier + ".FinderExtension", path: plugin.path))
            platform.records.append(.init(kind: .application, identifier: identifier, path: context.currentApp.path))
            let cleaner = Cleanup(context: context, platform: platform)
            let plan = try cleaner.scan()
            assert(plan.candidates.count == 1)
            assert(platform.mutationCount == 0, "Scanning must not mutate anything")
            let report = try cleaner.apply(plan, configurationBackup: backup)
            assert(report.movedToTrash.count == 1 && report.removedRegistrations.count == 2)
            assert(report.issues.isEmpty)
            assert(!FileManager.default.fileExists(atPath: old.path))
            assert(platform.records.count == 1 && platform.records[0].path == context.currentApp.path)
            let retainedBackup = try Data(contentsOf: backup)
            assert(retainedBackup == Data("fixture configuration backup".utf8))
        }
    }

    static func protectCurrentNewerRunningAndData() throws {
        try fixture { root, context, platform, backup in
            platform.discovered.append(context.currentApp)
            let alias = root.appendingPathComponent("Alias.app")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: context.currentApp)
            platform.discovered.append(alias)
            let newer = try add("Newer.app", under: root, platform: platform, metadata: info(version: "9.0", build: "900"))
            let running = try add("Running.app", under: root, platform: platform)
            platform.running = [running.appendingPathComponent("Contents/MacOS/NewKit")]
            let dataApp = try add("NewKitData/Backup.app", under: root, platform: platform)
            let foreignInfo = Cleanup.Metadata(identifier: "com.example.unrelated", team: "OTHERTEAM",
                                               version: "1.0", build: "1", signature: "foreign")
            let foreign = try add("Foreign.app", under: root, platform: platform, metadata: foreignInfo)
            platform.running.append(foreign.appendingPathComponent("Contents/MacOS/OtherApp"))
            let lookalike = try add("OtherDeveloper.app", under: root, platform: platform, metadata: info(team: "OTHERTEAM"))
            let embedded = try add("OtherHost.app/Contents/Resources/NewKit.app", under: root, platform: platform)
            let cleaner = Cleanup(context: context, platform: platform)
            let report = try cleaner.apply(cleaner.scan(), configurationBackup: backup)
            assert(report.movedToTrash.isEmpty && report.removedRegistrations.isEmpty)
            for url in [context.currentApp, alias, newer, running, dataApp, foreign, lookalike, embedded] {
                assert(FileManager.default.fileExists(atPath: url.path))
            }
            assert(platform.mutationCount == 0)
            assert(!report.issues.contains(where: { $0.path == foreign.path }), "Do not report unrelated running apps")
            assert(report.issues.contains(where: { $0.path == lookalike.path }), "Retain and report copies from a different developer")
            assert(!context.excludesFromScan(context.currentApp.deletingLastPathComponent()), "Scan parent folders, protect current app itself")
        }
    }

    static func sameVersionAndMissingRegistrations() throws {
        try fixture { root, context, platform, backup in
            let duplicate = try add("Duplicate.app", under: root, platform: platform, metadata: context.metadata)
            let missing = root.appendingPathComponent("Gone.app")
            platform.records.append(.init(kind: .application, identifier: identifier, path: missing.path))
            let cleaner = Cleanup(context: context, platform: platform)
            let report = try cleaner.apply(cleaner.scan(), configurationBackup: backup)
            assert(report.movedToTrash.isEmpty)
            assert(report.removedRegistrations.count == 2)
            assert(FileManager.default.fileExists(atPath: duplicate.path))
            assert(!context.protects(missing), "Missing inodes must not compare equal to nil")
        }
    }

    static func revalidateAndFailSafely() throws {
        try fixture { root, context, platform, backup in
            let old = try add("Changed.app", under: root, platform: platform)
            let cleaner = Cleanup(context: context, platform: platform)
            let plan = try cleaner.scan()
            platform.metadata[old.path] = info(version: "9.0", build: "900")
            let changed = try cleaner.apply(plan, configurationBackup: backup)
            assert(changed.movedToTrash.isEmpty && !changed.issues.isEmpty)
            assert(platform.mutationCount == 0)
            expectFailure { _ = try cleaner.apply(plan, configurationBackup: root.appendingPathComponent("missing.plist")) }
            assert(platform.mutationCount == 0)
        }
        try fixture { root, context, platform, backup in
            let old = try add("Permission.app", under: root, platform: platform)
            platform.failTrash = true
            let cleaner = Cleanup(context: context, platform: platform)
            let denied = try cleaner.apply(cleaner.scan(), configurationBackup: backup)
            assert(denied.movedToTrash.isEmpty && denied.issues.count == 1)
            assert(FileManager.default.fileExists(atPath: old.path))
            assert(platform.mutationCount == 0)
        }
        try fixture { root, context, platform, backup in
            try add("Old.app", under: root, platform: platform)
            platform.failUnregister = true
            let cleaner = Cleanup(context: context, platform: platform)
            let report = try cleaner.apply(cleaner.scan(), configurationBackup: backup)
            assert(report.movedToTrash.count == 1 && report.removedRegistrations.isEmpty)
            assert(!report.issues.isEmpty, "Partial failures must not be reported as a clean result")
        }
        try fixture { root, context, platform, backup in
            let missing = root.appendingPathComponent("Reappeared.app")
            platform.records.append(.init(kind: .application, identifier: identifier, path: missing.path))
            let cleaner = Cleanup(context: context, platform: platform)
            let plan = try cleaner.scan()
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
            let report = try cleaner.apply(plan, configurationBackup: backup)
            assert(report.removedRegistrations.isEmpty && !report.issues.isEmpty)
            assert(platform.mutationCount == 0)
        }
    }

    static func parseSystemCatalogs() throws {
        let dump = """
        ------------------------
        path: /Applications/NewKit.app (0x1234)
        identifier: com.codearthur.matrixapps.newkit
        ------------------------
        path: /Users/a/Old Copy/NewKit.app (0xabcd)
        identifier: com.codearthur.matrixapps.newkit
        """
        let apps = OldVersionCleanupSystem.parseAppRegistrations(dump)
        assert(apps.count == 2 && apps[1].path == "/Users/a/Old Copy/NewKit.app")
        let plugins = OldVersionCleanupSystem.parsePluginRegistrations(
            "+ id(1.0)\tUUID\tdate\t/Applications/NewKit.app/Contents/PlugIns/Ext.appex\n (1 plug-in)",
            identifier: identifier + ".FinderExtension")
        assert(plugins.count == 1)
        assert(OldVersionCleanupSystem.installerVersion(URL(fileURLWithPath: "/tmp/NewKit-1.4.2-notarized.zip")) == "1.4.2")
        assert(OldVersionCleanupSystem.installerVersion(URL(fileURLWithPath: "/tmp/Before-NewKit-Settings.plist")) == nil)
    }

    static func rejectUnverifiedInstallers() throws {
        try fixture { root, context, _, _ in
            let notes = root.appendingPathComponent("personal-notes.txt")
            try Data("These are not an installer".utf8).write(to: notes)
            let zip = root.appendingPathComponent("NewKit-1.0.0.zip")
            _ = try OldVersionCleanupSystem.command("/usr/bin/tar",
                ["-a", "-cf", zip.path, "-C", root.path, "personal-notes.txt"])
            let system = OldVersionCleanupSystem()
            expectFailure { _ = try system.inspect(zip, context: context) }
            assert(FileManager.default.fileExists(atPath: zip.path))
            let dmg = root.appendingPathComponent("NewKit-1.0.0.dmg")
            try Data("An unverified file must not be removed based on its name".utf8).write(to: dmg)
            expectFailure { _ = try system.inspect(dmg, context: context) }
            assert(FileManager.default.fileExists(atPath: dmg.path))
        }
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected operation to be rejected") } catch { }
    }
}
