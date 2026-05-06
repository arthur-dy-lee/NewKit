import AppKit

/// Listens for right-mouse-down events while Finder is frontmost and pops up NewKit's contextual
/// menu at the cursor when the user holds the trigger modifier (default: Control).
///
/// Avoids fighting Finder's native context menu — the user opts in by holding the modifier.
@MainActor
final class RightClickMonitor {
    static let shared = RightClickMonitor()

    private var monitor: Any?
    private let triggerModifier: NSEvent.ModifierFlags = .control
    private let finderBundleID = "com.apple.finder"

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.handle(event)
        }
        Log.info("RightClickMonitor: started")
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        // Require trigger modifier (Control) — without it, let Finder show its native menu.
        guard event.modifierFlags.contains(triggerModifier) else { return }

        // Require Finder to be frontmost.
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == finderBundleID else { return }

        let location = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            self?.presentMenu(at: location)
        }
    }

    private func presentMenu(at screenLocation: NSPoint) {
        let menu = ContextMenuBuilder.buildMenu()
        // popUp with view=nil interprets the location in screen coordinates.
        menu.popUp(positioning: nil, at: screenLocation, in: nil)
    }
}

/// Builds the NSMenu that appears for both the status bar and the right-click trigger.
@MainActor
enum ContextMenuBuilder {
    static func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: L10n.string("menu.header.newhere"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let showSeps = Configuration.shared.showSeparatorsInRightClickMenu
        let entries = Configuration.shared.visibleEntries
        let summary = entries.map { $0.isSeparator ? "[sep]" : "[type]" }.joined(separator: ",")
        Log.info("RightClick menu build: showSeps=\(showSeps) entries=\(summary)")
        for entry in entries {
            switch entry {
            case .fileType(let type):
                let item = NSMenuItem(title: type.menuTitle,
                                      action: #selector(MenuActionTarget.shared.create(_:)),
                                      keyEquivalent: "")
                item.target = MenuActionTarget.shared
                item.representedObject = type
                if let symbol = type.symbolName,
                   let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                    item.image = image
                }
                menu.addItem(item)
            case .separator:
                guard showSeps else { continue }
                menu.addItem(SeparatorMenuItemFactory.make())
            }
        }

        if Configuration.shared.showOpenTerminal {
            let term = NSMenuItem(title: L10n.string("menu.openterminal"),
                                  action: #selector(MenuActionTarget.shared.openTerminal(_:)),
                                  keyEquivalent: "")
            term.target = MenuActionTarget.shared
            if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) {
                term.image = img
            }
            menu.addItem(term)
        }

        return menu
    }
}

/// Singleton target so we can attach selectors from non-NSObject contexts.
@MainActor
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    @objc func openTerminal(_ sender: NSMenuItem) {
        TerminalOpener.open(at: FinderHelper.currentTargetPath())
    }

    @objc func create(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? FileType else { return }
        let dir = FinderHelper.currentTargetPath()
        do {
            let url = try FileCreator.create(type, in: dir)
            switch Configuration.shared.postCreateBehavior {
            case .revealAndRename:
                FinderHelper.revealAndRename(url)
            case .openInDefaultApp:
                NSWorkspace.shared.open(url)
            }
        } catch {
            Log.error("Create failed: \(error)")
            NSSound.beep()
        }
    }
}
