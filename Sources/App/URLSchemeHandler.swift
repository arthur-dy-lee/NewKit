import AppKit

/// Handles `newkit://create?type=<id>&path=<urlencoded-folder>` URLs sent from the
/// Finder Sync Extension toolbar / context menu.
@MainActor
enum URLSchemeHandler {
    static func register() {
        NSAppleEventManager.shared().setEventHandler(
            handler,
            andSelector: #selector(URLEventTrampoline.handleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private static let handler = URLEventTrampoline.shared

    static func handle(url: URL) {
        guard url.scheme == "newkit" else { return }
        guard url.host == "create" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let typeID = components?.queryItems?.first(where: { $0.name == "type" })?.value ?? ""
        let path = components?.queryItems?.first(where: { $0.name == "path" })?.value ?? ""

        guard !typeID.isEmpty, !path.isEmpty else { return }
        guard let type = resolveType(id: typeID) else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)

        do {
            let url = try FileCreator.create(type, in: folder)
            switch Configuration.shared.postCreateBehavior {
            case .revealAndRename: FinderHelper.revealAndRename(url)
            case .openInDefaultApp: NSWorkspace.shared.open(url)
            }
        } catch {
            Log.error("URL scheme create failed: \(error)")
            NSSound.beep()
        }
    }

    private static func resolveType(id: String) -> FileType? {
        if let builtIn = FileTypeRegistry.builtIn(id: id) { return builtIn }
        return Configuration.shared.customTypes.first { $0.id == id }
    }
}

/// Trampoline so we can use a non-NSObject enum as the Apple Event handler.
final class URLEventTrampoline: NSObject {
    @MainActor static let shared = URLEventTrampoline()

    @objc func handleEvent(_ event: NSAppleEventDescriptor,
                           withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        Task { @MainActor in URLSchemeHandler.handle(url: url) }
    }
}
