import AppKit
import Foundation
import SwiftUI

struct OldVersionCleanupSection: View {
    @State private var busy = false
    @State private var extraRoots: [URL] = []
    @State private var result: String?
    @State private var failure: String?
    @State private var reportURL: URL?

    var body: some View {
        Section {
            HStack {
                Button(L10n.string("cleanup.run")) { clean() }.disabled(busy)
                Button(L10n.string("cleanup.addFolder")) { addFolder() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                if let reportURL {
                    Button(L10n.string("cleanup.report")) { NSWorkspace.shared.open(reportURL) }
                }
            }
            if !extraRoots.isEmpty {
                HStack {
                    Text(String(format: L10n.string("cleanup.extraFolders"), extraRoots.count))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(L10n.string("cleanup.clearFolders")) {
                        extraRoots = []
                        UserDefaults.standard.removeObject(forKey: OldVersionCleanupCommand.rootsKey)
                    }.disabled(busy)
                }
            }
            if let result {
                Text(result).font(.callout).textSelection(.enabled)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.string("cleanup.section"))
        } footer: {
            Text(L10n.string("cleanup.footer"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { extraRoots = OldVersionCleanupCommand.savedRoots() }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        extraRoots = Array(Set(extraRoots + panel.urls)).sorted { $0.path < $1.path }
        UserDefaults.standard.set(extraRoots.map(\.path), forKey: OldVersionCleanupCommand.rootsKey)
    }

    private func clean() {
        busy = true
        result = nil
        failure = nil
        reportURL = nil
        let roots = extraRoots
        Task {
            do {
                let context = try OldVersionCleanupSystem.currentContext()
                let backup = try OldVersionCleanupCommand.backupConfiguration()
                let report = try await Task.detached(priority: .utility) {
                    let cleaner = OldVersionCleanup(context: context, platform: OldVersionCleanupSystem())
                    return try cleaner.apply(cleaner.scan(extraRoots: roots), configurationBackup: backup)
                }.value
                result = String(format: L10n.string("cleanup.result"), report.movedToTrash.count,
                                report.removedRegistrations.count, report.issues.count)
                if report.movedToTrash.isEmpty, report.removedRegistrations.isEmpty, report.issues.isEmpty {
                    result = L10n.string("cleanup.nothing")
                }
                Log.info("Old-version cleanup finished: moved=\(report.movedToTrash.count) "
                    + "registrations=\(report.removedRegistrations.count) issues=\(report.issues.count)")
                reportURL = try OldVersionCleanupCommand.saveReport(report)
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

@MainActor
enum OldVersionCleanupCommand {
    static let rootsKey = "oldVersionCleanupExtraRoots"

    static func savedRoots() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: rootsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func backupConfiguration() throws -> URL {
        let service = try ConfigurationBackup.current()
        let archive = try service.capture()
        let values = try service.validate(archive)
        guard values[.shared]?["didSeedDefaults_v2"] as? Bool == true else {
            throw ConfigurationBackup.Failure.unavailable
        }
        let destination = try ConfigurationBackup.backupDirectory()
            .appendingPathComponent(ConfigurationBackup.fileName(prefix: "BeforeOldVersionCleanup"))
        try service.save(archive, to: destination)
        return destination
    }

    static func saveReport(_ report: OldVersionCleanup.Report) throws -> URL {
        let folder = try ConfigurationBackup.backupDirectory().deletingLastPathComponent()
            .appendingPathComponent("Cleanup Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(ConfigurationBackup.fileName(prefix: "OldVersionCleanup"))
            .deletingPathExtension().appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func handleIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--cleanup-old-versions" else { return false }
        do {
            var roots = savedRoots()
            var dryRun = false
            var index = 1
            while index < args.count {
                switch args[index] {
                case "--dry-run": dryRun = true
                case "--scan-folder":
                    index += 1
                    guard index < args.count else { throw OldVersionCleanup.CleanupFailure("missing folder") }
                    roots.append(URL(fileURLWithPath: args[index]))
                default: throw OldVersionCleanup.CleanupFailure("unknown cleanup argument: \(args[index])")
                }
                index += 1
            }
            let cleaner = OldVersionCleanup(context: try OldVersionCleanupSystem.currentContext(),
                                            platform: OldVersionCleanupSystem())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if dryRun {
                print(String(decoding: try encoder.encode(cleaner.scan(extraRoots: roots)), as: UTF8.self))
            } else {
                let backup = try backupConfiguration()
                let report = try cleaner.apply(cleaner.scan(extraRoots: roots), configurationBackup: backup)
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
                let url = try saveReport(report)
                Log.info("Old-version cleanup report: \(url.path)")
                if !report.issues.isEmpty { exit(2) }
            }
            return true
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
