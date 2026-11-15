import CryptoKit
import Darwin
import Foundation
import Security

struct OldVersionCleanupSystem: OldVersionCleanup.Platform {
    typealias Cleanup = OldVersionCleanup
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func currentContext() throws -> Cleanup.Context {
        let app = Bundle.main.bundleURL.standardizedFileURL
        let metadata = try signedBundle(app)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/NewKit", isDirectory: true)
        var protected = [support, home.appendingPathComponent("Library/Preferences"),
                         home.appendingPathComponent("Library/Logs/NewKit"),
                         home.appendingPathComponent("Library/Containers/\(metadata.identifier)")]
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedDefaults.appGroupID) {
            protected.append(group)
        }
        return Cleanup.Context(currentApp: app, metadata: metadata, protectedRoots: protected,
                               trashRoot: home.appendingPathComponent(".Trash"))
    }

    func registrations() throws -> [Cleanup.Registration] {
        let apps = try Self.command(Self.lsregister, ["-dump"])
        var records = Self.parseAppRegistrations(apps)
        // Query only NewKit plugin identifiers; do not change other apps' elections.
        let appIDs = ["com.codearthur.matrixapps.newkit", "app.newkit.NewKit", "com.codearthur.matrixapps.newkit.debug"]
        for appID in appIDs {
            let identifier = appID + ".FinderExtension"
            if let output = try? Self.command("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier]) {
                records += Self.parsePluginRegistrations(output, identifier: identifier)
            }
        }
        return Array(Set(records))
    }

    static func parseAppRegistrations(_ output: String) -> [Cleanup.Registration] {
        var records: [Cleanup.Registration] = []
        var path: String?
        var identifier: String?
        func flush() {
            if let path, let identifier {
                records.append(.init(kind: identifier.hasSuffix(".FinderExtension") ? .plugin : .application,
                                     identifier: identifier, path: path))
            }
            path = nil
            identifier = nil
        }
        for line in output.components(separatedBy: .newlines) {
            if line.count >= 10, line.allSatisfy({ $0 == "-" }) { flush() }
            else if line.hasPrefix("path:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                path = value.replacingOccurrences(of: #"\s+\(0x[0-9a-fA-F]+\)$"#,
                                                  with: "", options: .regularExpression)
            } else if line.hasPrefix("identifier:") {
                identifier = line.dropFirst(11).split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
        }
        flush()
        return records
    }

    static func parsePluginRegistrations(_ output: String, identifier: String) -> [Cleanup.Registration] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard let path = line.components(separatedBy: "\t").last,
                  path.hasPrefix("/") else { return nil }
            return .init(kind: .plugin, identifier: identifier, path: path)
        }
    }

    func discover(extraRoots: [URL], context: Cleanup.Context) throws -> Cleanup.Discovery {
        var result = Cleanup.Discovery()
        let predicates = context.appIDs.map { "kMDItemCFBundleIdentifier == \"\($0)\"" }
            + ["kMDItemFSName == \"NewKit-*.dmg\"", "kMDItemFSName == \"NewKit-*.zip\""]
        do {
            let output = try Self.command("/usr/bin/mdfind", ["-0", predicates.joined(separator: " || ")])
            result.paths += output.split(separator: "\0").map { URL(fileURLWithPath: String($0)) }
        } catch { result.issues.append(.init(path: "Spotlight", reason: "scan incomplete: \(error)")) }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
                     home.appendingPathComponent("Downloads")] + extraRoots
        var visited = Set<String>()
        for root in roots where visited.insert(Cleanup.Context.canonical(root)).inserted {
            guard FileManager.default.fileExists(atPath: root.path), !context.excludesFromScan(root) else { continue }
            let maximumDepth = extraRoots.contains(root) ? 10 : 2
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { url, error in
                    result.issues.append(.init(path: url.path, reason: "not accessible: \(error.localizedDescription)"))
                    return true
                }) else { continue }
            var count = 0
            for case let url as URL in enumerator {
                count += 1
                if count > 20_000 {
                    result.issues.append(.init(path: root.path, reason: "scan limit reached; choose a narrower folder"))
                    break
                }
                let name = url.lastPathComponent.lowercased()
                if context.excludesFromScan(url) || context.isInTrash(url) {
                    enumerator.skipDescendants()
                } else if name.hasSuffix(".app") || name.hasSuffix(".app.backup") || name.hasSuffix(".appex") {
                    result.paths.append(url)
                    enumerator.skipDescendants()
                } else if Self.installerVersion(url) != nil {
                    result.paths.append(url)
                } else if enumerator.level >= maximumDepth ||
                            [".git", "node_modules", "intermediates.noindex", "sourcepackages",
                             "modulecache.noindex", "index.noindex", "sdkexplicitprecompiledmodules",
                             "sdkstatcaches.noindex"].contains(name) {
                    enumerator.skipDescendants()
                }
            }
        }
        return result
    }

    func inspect(_ url: URL, context: Cleanup.Context) throws -> Cleanup.Metadata? {
        if ["zip", "dmg"].contains(url.pathExtension.lowercased()) {
            guard let version = Self.installerVersion(url),
                  let comparison = Cleanup.compareNumbers(version, context.metadata.version),
                  comparison != .orderedDescending else { return nil }
            if url.pathExtension.lowercased() == "dmg" {
                let signing = try Self.signingInfo(url)
                let prefix = context.metadata.identifier + ".installer.v"
                guard signing.team == context.metadata.team, signing.identifier.hasPrefix(prefix) else {
                    throw Cleanup.CleanupFailure("installer signature does not match NewKit")
                }
                let parts = String(signing.identifier.dropFirst(prefix.count)).components(separatedBy: ".b")
                guard parts.count == 2, parts[0] == version,
                      Cleanup.compareNumbers(parts[1], parts[1]) != nil else {
                    throw Cleanup.CleanupFailure("installer version cannot be verified")
                }
                return .init(identifier: context.metadata.identifier, team: signing.team,
                             version: version, build: parts[1], signature: signing.signature)
            }
            return try Self.inspectZIP(url, expectedVersion: version, context: context)
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              context.identifiers.contains(identifier) else { return nil }
        return try Self.signedBundle(url)
    }

    static func installerVersion(_ url: URL) -> String? {
        let expression = try! NSRegularExpression(pattern: #"^NewKit-([0-9]+(?:\.[0-9]+){1,3})(?:-signed|-notarized)?\.(?:zip|dmg)$"#,
                                                  options: .caseInsensitive)
        let name = url.lastPathComponent
        guard let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[range])
    }

    private static func inspectZIP(_ url: URL, expectedVersion: String,
                                   context: Cleanup.Context) throws -> Cleanup.Metadata {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 256 * 1024 * 1024 else { throw Cleanup.CleanupFailure("archive too large to verify automatically") }
        let listing = try command("/usr/bin/tar", ["-tf", url.path])
        let totals = try command("/usr/bin/unzip", ["-Z", "-t", url.path])
        let totalsPattern = try NSRegularExpression(pattern: #"([0-9]+) bytes uncompressed"#)
        guard let match = totalsPattern.firstMatch(in: totals, range: NSRange(totals.startIndex..., in: totals)),
              let range = Range(match.range(at: 1), in: totals), let expanded = UInt64(totals[range]),
              expanded <= 256 * 1024 * 1024 else {
            throw Cleanup.CleanupFailure("archive expanded size is unavailable or too large")
        }
        let entries = listing.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !entries.isEmpty, entries.count <= 20_000, entries.allSatisfy({ entry in
            let parts = entry.split(separator: "/")
            return !entry.hasPrefix("/") && !entry.contains("\\") && !parts.contains("..")
                && !entry.unicodeScalars.contains(where: { $0.value < 32 })
                && ["NewKit.app", "__MACOSX"].contains(String(parts.first ?? ""))
        }) else { throw Cleanup.CleanupFailure("archive contains unexpected paths; retained") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NewKit-archive-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        // bsdtar's default extraction rejects '..' and symlink traversal. Do
        // not pass -P. Never execute or register the extracted application.
        _ = try command("/usr/bin/tar", ["-xf", url.path, "-C", folder.path,
            "--safe-writes", "--no-same-owner", "--no-same-permissions", "--no-xattrs", "--no-acls", "--no-fflags"])
        let app = folder.appendingPathComponent("NewKit.app")
        guard Cleanup.Context.contains(folder.path, Cleanup.Context.canonical(app)) else {
            throw Cleanup.CleanupFailure("archive application escapes temporary directory")
        }
        let metadata = try signedBundle(app)
        guard context.appIDs.contains(metadata.identifier), metadata.team == context.metadata.team,
              metadata.version == expectedVersion else { throw Cleanup.CleanupFailure("archive identity or version mismatch") }
        // Bind revalidation to the complete archive, including extra contents.
        return .init(identifier: metadata.identifier, team: metadata.team, version: metadata.version,
                     build: metadata.build, signature: digest(try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    private static func signedBundle(_ url: URL) throws -> Cleanup.Metadata {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else {
            throw Cleanup.CleanupFailure("bundle metadata incomplete")
        }
        let signing = try signingInfo(url)
        guard signing.identifier == identifier else { throw Cleanup.CleanupFailure("bundle identity does not match signature") }
        return .init(identifier: identifier, team: signing.team, version: version, build: build,
                     signature: signing.signature)
    }

    private static func signingInfo(_ url: URL) throws -> (identifier: String, team: String, signature: String) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw Cleanup.CleanupFailure("code signature invalid or unavailable")
        }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let values = dictionary as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data else {
            throw Cleanup.CleanupFailure("verified signer identity unavailable")
        }
        guard !team.isEmpty, team.count <= 64, team.allSatisfy({
            $0.isASCII && ($0.isUppercase || $0.isNumber)
        }) else { throw Cleanup.CleanupFailure("invalid signer team") }
        // Team text alone is not proof of ownership: also require an Apple
        // certificate chain, so a self-signed lookalike cannot qualify.
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue:
                kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw Cleanup.CleanupFailure("code signature or trusted signer validation failed")
        }
        return (identifier, team, hash.map { String(format: "%02x", $0) }.joined())
    }

    func runningExecutables() throws -> [URL] {
        let output = try Self.command("/bin/ps", ["-axo", "pid=,comm="])
        var paths = Set<URL>()
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            let cached = fields[1].trimmingCharacters(in: .whitespaces)
            if cached.hasPrefix("/") { paths.insert(URL(fileURLWithPath: cached)) }
            // Also ask the kernel for the executable vnode's current path.
            // A running app may have been renamed/moved since it launched.
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let path = String(decoding: bytes, as: UTF8.self)
                if path.hasPrefix("/") { paths.insert(URL(fileURLWithPath: path)) }
            }
        }
        return Array(paths)
    }

    func trash(_ url: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        guard let destination else { throw Cleanup.CleanupFailure("Trash destination unavailable") }
        return destination as URL
    }

    func unregister(_ registration: Cleanup.Registration) throws {
        do {
            _ = try Self.command(registration.kind == .plugin ? "/usr/bin/pluginkit" : Self.lsregister,
                                 [registration.kind == .plugin ? "-r" : "-u", registration.path])
        } catch {
            // Unregistering the containing app can also remove its plugin.
            // Treat an already-absent record as success, with a fresh check.
            if try registrations().contains(registration) { throw error }
        }
    }

    func registerCurrent(_ context: Cleanup.Context) throws {
        _ = try Self.command(Self.lsregister, ["-f", context.currentApp.path])
        let plugin = context.currentApp.appendingPathComponent("Contents/PlugIns/NewKitFinderExtension.appex")
        if FileManager.default.fileExists(atPath: plugin.path) {
            _ = try Self.command("/usr/bin/pluginkit", ["-a", plugin.path])
        }
    }

    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("NewKit-cleanup-output-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw Cleanup.CleanupFailure("temporary output unavailable")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw Cleanup.CleanupFailure("\(URL(fileURLWithPath: executable).lastPathComponent) timed out")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 64 * 1024 * 1024 else {
            throw Cleanup.CleanupFailure("command output too large")
        }
        let output = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Cleanup.CleanupFailure("\(URL(fileURLWithPath: executable).lastPathComponent): \(output.prefix(500))")
        }
        return output
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
