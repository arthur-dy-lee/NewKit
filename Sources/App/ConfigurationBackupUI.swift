import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationBackupSection: View {
    @State private var result: String?
    @State private var failure: String?

    var body: some View {
        Section {
            HStack {
                Button(L10n.string("backup.export")) { exportSettings() }
                Button(L10n.string("backup.restore")) { restoreSettings() }
                Button(L10n.string("backup.reveal")) {
                    do {
                        let folder = try ConfigurationBackup.backupDirectory()
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } catch { failure = error.localizedDescription }
                }
            }
            if let result {
                Label(result, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.string("backup.section"))
        } footer: {
            Text(L10n.string("backup.footer"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = ConfigurationBackup.fileName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let service = try ConfigurationBackup.current()
            try service.save(service.capture(), to: url)
            result = String(format: L10n.string("backup.exported"), url.lastPathComponent)
            failure = nil
            Log.info("Settings backup exported and verified: \(url.path)")
        } catch { failure = error.localizedDescription }
    }

    private func restoreSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let service = try ConfigurationBackup.current()
            let archive = try service.load(from: url)
            let alert = NSAlert()
            alert.messageText = L10n.string("backup.confirm.title")
            alert.informativeText = String(
                format: L10n.string("backup.confirm.message"),
                DateFormatter.localizedString(from: archive.createdAt, dateStyle: .medium, timeStyle: .short))
            alert.addButton(withTitle: L10n.string("backup.confirm.restore"))
            alert.addButton(withTitle: L10n.string("backup.confirm.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            // Validate and stage the chosen archive before quitting. The next
            // process waits for this one to exit so cached singletons cannot
            // overwrite the restored preferences during termination.
            let pending = try ConfigurationBackup.backupDirectory()
                .appendingPathComponent(ConfigurationBackup.fileName(prefix: "PendingRestore"))
            try service.save(archive, to: pending)
            guard let executable = Bundle.main.executableURL else {
                throw ConfigurationBackup.Failure.unavailable
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--restore-settings-after-exit", pending.path,
                                 String(ProcessInfo.processInfo.processIdentifier)]
            try process.run()
            NSApp.terminate(nil)
        } catch { failure = error.localizedDescription }
    }
}

@MainActor
enum ConfigurationBackupCommand {
    private static var restoreFailure: String?

    /// Export/compare modes do not initialize any app services or move icons.
    /// The signed app can read its real protected App Group before replacement.
    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1, ["--export-settings", "--compare-settings",
                              "--restore-settings-after-exit"].contains(args[1]) else { return false }
        var parentHasExited = false
        do {
            let service = try ConfigurationBackup.current()
            guard args.count >= 3 else { throw ConfigurationBackup.Failure.invalid }
            let url = URL(fileURLWithPath: args[2])
            switch args[1] {
            case "--export-settings":
                let archive = try service.capture()
                let values = try service.validate(archive)
                // An unreadable group must not be reported as a complete backup
                // merely because a stale same-named legacy domain is readable.
                guard values[.shared]?["didSeedDefaults_v2"] as? Bool == true else {
                    throw ConfigurationBackup.Failure.unavailable
                }
                try service.save(archive, to: url)
                let shared = values[.shared] ?? [:]
                var summary: [String: Any] = [
                    "backup": url.path,
                    "sharedKeyCount": shared.count,
                    "applicationKeyCount": values[.application]?.count ?? 0,
                    "menuBarOrder": shared["menuBarOrganizerOrder"] as? [String] ?? [],
                    "verified": true
                ]
                if let data = shared["menuBarOrganizerAssignments"] as? Data,
                   let assignments = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    summary["menuBarGroups"] = ["visible", "hidden", "alwaysHidden"].reduce(into: [String: [String]]()) { result, group in
                        result[group] = assignments.filter { $0["group"] as? String == group }
                            .compactMap { $0["bundleIdentifier"] as? String }.sorted()
                    }
                }
                try printJSON(summary)
                return true
            case "--compare-settings":
                let differences = try service.differences(from: service.load(from: url))
                try printJSON(["matches": differences.isEmpty, "changedKeys": differences])
                if !differences.isEmpty { exit(2) }
                return true
            default:
                // The parent may already have exited by the time this signed
                // process starts; getppid() can legitimately be launchd here.
                guard args.count == 4, let parent = pid_t(args[3]), parent > 1,
                      parent != getpid() else { throw ConfigurationBackup.Failure.invalid }
                let deadline = Date().addingTimeInterval(15)
                while kill(parent, 0) == 0 {
                    guard Date() < deadline else { throw ConfigurationBackup.Failure.writeFailed }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                parentHasExited = true
                let archive = try service.load(from: url)
                let safety = try ConfigurationBackup.backupDirectory()
                    .appendingPathComponent(ConfigurationBackup.fileName(prefix: "BeforeRestore"))
                try service.save(service.capture(), to: safety)
                try service.restore(archive)
                Log.info("Settings restored before app initialization; previous configuration: \(safety.path)")
                return false // Continue normal app startup using restored values.
            }
        } catch {
            Log.error("Settings backup operation failed: \(error)")
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            if parentHasExited {
                restoreFailure = error.localizedDescription
                return false // Keep NewKit available after a failed restore.
            }
            exit(1)
        }
    }

    static func presentRestoreFailureIfNeeded() {
        guard let restoreFailure else { return }
        self.restoreFailure = nil
        let alert = NSAlert()
        alert.messageText = L10n.string("backup.failed.title")
        alert.informativeText = restoreFailure
        alert.runModal()
    }

    private static func printJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
