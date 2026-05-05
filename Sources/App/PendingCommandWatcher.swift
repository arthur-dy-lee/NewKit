import AppKit

/// Watches the App-Group `Pending/` directory for command files dropped by the
/// Finder Sync extension (which can't reliably use NSWorkspace/NSExtensionContext.open
/// from inside the sandbox to invoke the `newkit://` URL scheme).
///
/// Each command is a JSON file: `{ "type": "<id>", "path": "<absolute-folder>" }`.
@MainActor
final class PendingCommandWatcher {
    static let shared = PendingCommandWatcher()

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func start() {
        guard let pending = pendingDirectory() else {
            Log.error("PendingCommandWatcher: app group container unavailable")
            return
        }
        Log.info("PendingCommandWatcher: watching \(pending.path)")
        try? FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        processAll(in: pending)
        dumpExtDebugLog()

        let dirfd = open(pending.path, O_EVTONLY)
        guard dirfd >= 0 else {
            Log.error("PendingCommandWatcher: open() failed errno=\(errno)")
            return
        }
        self.fd = dirfd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirfd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.processAll(in: pending)
            self.dumpExtDebugLog()
        }
        src.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { close(f) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func pendingDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.appGroupID)?
            .appendingPathComponent("Pending", isDirectory: true)
    }

    private func processAll(in pending: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: pending,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }
        let cmds = files.filter { $0.pathExtension == "json" }
        if !cmds.isEmpty {
            Log.info("PendingCommandWatcher: processing \(cmds.count) command(s)")
        }
        for file in cmds {
            process(file: file)
        }
    }

    private func dumpExtDebugLog() {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedDefaults.appGroupID) else { return }
        let logFile = group.appendingPathComponent("ext-debug.log")
        guard let data = try? Data(contentsOf: logFile),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        for line in text.split(separator: "\n") {
            Log.info(String(line))
        }
        try? FileManager.default.removeItem(at: logFile)
    }

    private func process(file: URL) {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let typeID = obj["type"], let path = obj["path"],
              !typeID.isEmpty, !path.isEmpty else {
            Log.error("PendingCommandWatcher: malformed command at \(file.lastPathComponent)")
            return
        }
        guard let type = resolveType(id: typeID) else {
            Log.error("PendingCommandWatcher: unknown type id=\(typeID)")
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let created = try FileCreator.create(type, in: folder)
            switch Configuration.shared.postCreateBehavior {
            case .revealAndRename: FinderHelper.revealAndRename(created)
            case .openInDefaultApp: NSWorkspace.shared.open(created)
            }
        } catch {
            Log.error("PendingCommandWatcher: create failed: \(error)")
            NSSound.beep()
        }
    }

    private func resolveType(id: String) -> FileType? {
        if let builtIn = FileTypeRegistry.builtIn(id: id) { return builtIn }
        return Configuration.shared.customTypes.first { $0.id == id }
    }
}
