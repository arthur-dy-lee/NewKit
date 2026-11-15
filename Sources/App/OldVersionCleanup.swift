import Foundation

struct OldVersionCleanup: Sendable {
    enum Kind: String, Codable, Sendable { case application, plugin, installer, registration }

    struct Metadata: Codable, Equatable, Sendable {
        let identifier: String
        let team: String
        let version: String
        let build: String
        let signature: String
    }

    struct Registration: Hashable, Codable, Sendable {
        let kind: Kind
        let identifier: String
        let path: String
    }

    struct Issue: Codable, Sendable {
        let path: String
        let reason: String
    }

    struct Discovery: Sendable {
        var paths: [URL] = []
        var issues: [Issue] = []
    }

    struct Context: Sendable {
        let currentApp: URL
        let metadata: Metadata
        let protectedRoots: [URL]
        let trashRoot: URL

        var appIDs: Set<String> {
            if metadata.identifier == "com.codearthur.matrixapps.newkit" {
                return [metadata.identifier, "app.newkit.NewKit"]
            }
            return [metadata.identifier]
        }

        var identifiers: Set<String> { appIDs.union(appIDs.map { $0 + ".FinderExtension" }) }

        func protects(_ url: URL) -> Bool {
            let path = Self.canonical(url)
            let current = Self.canonical(currentApp)
            if Self.contains(path, current) || Self.contains(current, path) { return true }
            if let identity = Self.fileID(url), identity == Self.fileID(currentApp) { return true }
            return protectedRoots.contains { Self.contains(Self.canonical($0), path) }
        }

        func isInTrash(_ url: URL) -> Bool {
            Self.contains(Self.canonical(trashRoot), Self.canonical(url))
        }

        func excludesFromScan(_ url: URL) -> Bool {
            let path = Self.canonical(url)
            return Self.contains(Self.canonical(currentApp), path)
                || protectedRoots.contains { Self.contains(Self.canonical($0), path) }
        }

        static func canonical(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }

        static func contains(_ parent: String, _ child: String) -> Bool {
            parent == child || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
        }

        private static func fileID(_ url: URL) -> String? {
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let volume = values[.systemNumber] as? NSNumber,
                  let inode = values[.systemFileNumber] as? NSNumber else { return nil }
            return "\(volume):\(inode)"
        }
    }

    struct Fingerprint: Codable, Equatable, Sendable {
        let volume: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init(_ url: URL) throws {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let volume = values[.systemNumber] as? NSNumber,
                  let inode = values[.systemFileNumber] as? NSNumber,
                  let size = values[.size] as? NSNumber,
                  let modified = values[.modificationDate] as? Date,
                  values[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw CleanupFailure("unreadable or symbolic-link item")
            }
            self.volume = volume.uint64Value
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified
        }
    }

    struct Candidate: Codable, Sendable {
        let path: String
        let kind: Kind
        let metadata: Metadata?
        let fingerprint: Fingerprint?
        let moveToTrash: Bool
    }

    struct Plan: Codable, Sendable {
        let createdAt: Date
        let currentApp: String
        var candidates: [Candidate] = []
        var issues: [Issue] = []
    }

    struct Report: Codable, Sendable {
        let createdAt: Date
        let currentApp: String
        let configurationBackup: String
        var movedToTrash: [String: String] = [:]
        var removedRegistrations: [Registration] = []
        var issues: [Issue] = []
    }

    struct CleanupFailure: Error, LocalizedError, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
        var errorDescription: String? { description }
    }

    protocol Platform: Sendable {
        func registrations() throws -> [Registration]
        func discover(extraRoots: [URL], context: Context) throws -> Discovery
        func inspect(_ url: URL, context: Context) throws -> Metadata?
        func runningExecutables() throws -> [URL]
        func trash(_ url: URL) throws -> URL
        func unregister(_ registration: Registration) throws
        func registerCurrent(_ context: Context) throws
    }

    let context: Context
    let platform: any Platform

    func scan(extraRoots: [URL] = []) throws -> Plan {
        let registrations = try platform.registrations().filter { context.identifiers.contains($0.identifier) }
        let discovery = try platform.discover(extraRoots: extraRoots, context: context)
        let running = try platform.runningExecutables()
        var plan = Plan(createdAt: Date(), currentApp: context.currentApp.path, issues: discovery.issues)
        let paths = Set(discovery.paths.map(\.standardizedFileURL.path) + registrations.map(\.path))
        var visited = Set<String>()
        for path in paths.sorted() {
            let original = URL(fileURLWithPath: path)
            let url = Self.enclosingApp(original) ?? original
            let canonical = Context.canonical(url)
            guard visited.insert(canonical).inserted, !context.protects(url) else { continue }
            let registered = registrations.contains { Context.contains(url.path, $0.path) }
            if context.isInTrash(url) || !FileManager.default.fileExists(atPath: url.path) {
                if registered {
                    if isRunning(url, executables: running) {
                        plan.issues.append(Issue(path: path, reason: "running; retained"))
                    } else {
                        plan.candidates.append(Candidate(path: url.path, kind: .registration,
                            metadata: nil, fingerprint: nil, moveToTrash: false))
                    }
                }
                continue
            }
            do {
                guard let metadata = try platform.inspect(url, context: context),
                      context.identifiers.contains(metadata.identifier) else { continue }
                guard metadata.team == context.metadata.team else {
                    plan.issues.append(Issue(path: url.path, reason: "different developer; retained"))
                    continue
                }
                if isRunning(url, executables: running) {
                    plan.issues.append(Issue(path: path, reason: "running; retained"))
                    continue
                }
                guard let comparison = Self.compare(metadata, context.metadata) else {
                    plan.issues.append(Issue(path: url.path, reason: "unknown version; retained"))
                    continue
                }
                if comparison == .orderedDescending {
                    plan.issues.append(Issue(path: url.path, reason: "newer version; retained"))
                    continue
                }
                let kind: Kind = ["dmg", "zip"].contains(url.pathExtension.lowercased())
                    ? .installer : (url.pathExtension == "appex" ? .plugin : .application)
                let remove = comparison == .orderedAscending && !url.path.hasPrefix("/Volumes/")
                if remove || registered {
                    plan.candidates.append(Candidate(path: url.path, kind: kind,
                        metadata: metadata, fingerprint: try Fingerprint(url), moveToTrash: remove))
                }
            } catch {
                plan.issues.append(Issue(path: url.path, reason: "not verified; retained: \(error)"))
            }
        }
        return plan
    }

    func apply(_ plan: Plan, configurationBackup: URL) throws -> Report {
        let age = Date().timeIntervalSince(plan.createdAt)
        guard plan.currentApp == context.currentApp.path, age >= 0, age < 300,
              FileManager.default.fileExists(atPath: configurationBackup.path) else {
            throw CleanupFailure("fresh scan and verified configuration backup required")
        }
        var report = Report(createdAt: Date(), currentApp: context.currentApp.path,
                            configurationBackup: configurationBackup.path, issues: plan.issues)
        var approvedPaths = Set<String>()
        for candidate in plan.candidates {
            let url = URL(fileURLWithPath: candidate.path)
            do {
                guard !context.protects(url), !isRunning(url, executables: try platform.runningExecutables()) else {
                    throw CleanupFailure("current or running item; retained")
                }
                if let expected = candidate.metadata {
                    guard try Fingerprint(url) == candidate.fingerprint,
                          let actual = try platform.inspect(url, context: context), actual == expected,
                          actual.team == context.metadata.team,
                          context.identifiers.contains(actual.identifier),
                          let comparison = Self.compare(actual, context.metadata),
                          comparison != .orderedDescending,
                          !candidate.moveToTrash || comparison == .orderedAscending else {
                        throw CleanupFailure("item changed after scanning; retained")
                    }
                } else {
                    guard candidate.kind == .registration, !candidate.moveToTrash,
                          context.isInTrash(url) || !FileManager.default.fileExists(atPath: url.path) else {
                        throw CleanupFailure("stale path reappeared; retained")
                    }
                }
                if candidate.moveToTrash {
                    let destination = try platform.trash(url)
                    report.movedToTrash[url.path] = destination.path
                    approvedPaths.insert(destination.path)
                }
                approvedPaths.insert(url.path)
            } catch {
                report.issues.append(Issue(path: url.path, reason: "\(error)"))
            }
        }
        // Moving a bundle can cause LaunchServices to register its new Trash
        // path. Read the catalog again after moving, then remove those records.
        for _ in 0..<2 {
            let registrations: [Registration]
            let running: [URL]
            do {
                registrations = try platform.registrations()
                running = try platform.runningExecutables()
            } catch {
                report.issues.append(Issue(path: "system registrations", reason: "verification incomplete: \(error)"))
                break
            }
            for registration in registrations where context.identifiers.contains(registration.identifier) {
                let url = URL(fileURLWithPath: registration.path)
                guard !context.protects(url), !isRunning(url, executables: running),
                      context.isInTrash(url) || approvedPaths.contains(where: {
                          Context.contains($0, registration.path)
                      }) else { continue }
                do {
                    try platform.unregister(registration)
                    if !report.removedRegistrations.contains(registration) {
                        report.removedRegistrations.append(registration)
                    }
                } catch {
                    report.issues.append(Issue(path: registration.path, reason: "registration retained: \(error)"))
                }
            }
        }
        if !approvedPaths.isEmpty || !report.removedRegistrations.isEmpty {
            do { try platform.registerCurrent(context) }
            catch { report.issues.append(Issue(path: context.currentApp.path, reason: "registration refresh failed: \(error)")) }
        }
        do {
            let remaining = Set(try platform.registrations())
            report.removedRegistrations.removeAll { remaining.contains($0) }
            for registration in remaining where context.identifiers.contains(registration.identifier) {
                let url = URL(fileURLWithPath: registration.path)
                if !context.protects(url), approvedPaths.contains(where: {
                    Context.contains($0, registration.path)
                }) {
                    report.issues.append(Issue(path: registration.path,
                        reason: "registration still present after cleanup; retained in report"))
                }
            }
        } catch {
            report.issues.append(Issue(path: "system registrations", reason: "final verification failed: \(error)"))
        }
        return report
    }

    private func isRunning(_ url: URL, executables: [URL]) -> Bool {
        let path = Context.canonical(url)
        return executables.contains { Context.contains(path, Context.canonical($0)) }
    }

    static func enclosingApp(_ url: URL) -> URL? {
        var current = url
        var outermost: URL?
        while current.path != "/" {
            let name = current.lastPathComponent.lowercased()
            if name.hasSuffix(".app") || name.hasSuffix(".app.backup") { outermost = current }
            current.deleteLastPathComponent()
        }
        // Never remove an embedded app from a different host application.
        return outermost
    }

    static func compare(_ left: Metadata, _ right: Metadata) -> ComparisonResult? {
        guard let version = compareNumbers(left.version, right.version) else { return nil }
        return version == .orderedSame ? compareNumbers(left.build, right.build) : version
    }

    static func compareNumbers(_ left: String, _ right: String) -> ComparisonResult? {
        func parts(_ value: String) -> [Int]? {
            let segments = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !segments.isEmpty, segments.count <= 8 else { return nil }
            let numbers = segments.compactMap { segment -> Int? in
                guard !segment.isEmpty, segment.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                return Int(segment)
            }
            return numbers.count == segments.count ? numbers : nil
        }
        guard let a = parts(left), let b = parts(right) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
