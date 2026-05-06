import AppKit
import Combine

@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private let menuRefresher = MenuRefresher()
    private var configObserver: NSObjectProtocol?

    init() {
        applyVisibility()
        configObserver = NotificationCenter.default.addObserver(
            forName: Configuration.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyVisibility()
            self?.rebuildMenu()
        }
    }

    /// Creates or removes the status item to match the user's preference.
    private func applyVisibility() {
        let shouldShow = Configuration.shared.showMenuBarIcon
        if shouldShow, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "plus.square.on.square",
                                    accessibilityDescription: "NewKit")
                image?.isTemplate = true
                button.image = image
                button.toolTip = "NewKit"
            }
            statusItem = item
            rebuildMenu()
        } else if !shouldShow, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // Status bar lives for the entire app lifetime, so we don't bother removing the observer.

    /// Rebuilds the status bar menu from current configuration. Call after preferences change.
    func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let header = NSMenuItem(title: L10n.string("menu.header.newin"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for entry in Configuration.shared.visibleEntries {
            switch entry {
            case .fileType(let type):
                let item = NSMenuItem(title: type.menuTitle,
                                      action: #selector(handleCreate(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = type
                if let symbol = type.symbolName,
                   let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                    item.image = image
                }
                menu.addItem(item)
            case .separator:
                menu.addItem(SeparatorMenuItemFactory.make())
            }
        }

        if Configuration.shared.showOpenTerminal {
            let term = NSMenuItem(title: L10n.string("menu.openterminal"),
                                  action: #selector(openTerminal(_:)),
                                  keyEquivalent: "")
            term.target = self
            if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) {
                term.image = img
            }
            menu.addItem(term)
        }

        menu.addItem(.separator())

        let pathItem = NSMenuItem(title: pathLabel(), action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        pathItem.tag = 999
        menu.addItem(pathItem)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: L10n.string("menu.preferences"),
                               action: #selector(openPreferences(_:)),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let quit = NSMenuItem(title: L10n.string("menu.quit"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = menuRefresher
        statusItem.menu = menu
    }

    private func pathLabel() -> String {
        let dir = FinderHelper.currentTargetPath()
        let prefix = L10n.string("menu.targetpath.prefix")
        return "\(prefix) \(MenuRefresher.abbreviate(dir.path))"
    }

    @objc private func handleCreate(_ sender: NSMenuItem) {
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

    @objc private func openTerminal(_ sender: Any?) {
        TerminalOpener.open(at: FinderHelper.currentTargetPath())
    }

    @objc private func openPreferences(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}

/// Refreshes the dynamic "current path" item every time the menu opens.
final class MenuRefresher: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard let item = menu.item(withTag: 999) else { return }
        let dir = FinderHelper.currentTargetPath()
        let prefix = L10n.string("menu.targetpath.prefix")
        item.title = "\(prefix) \(MenuRefresher.abbreviate(dir.path))"
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
