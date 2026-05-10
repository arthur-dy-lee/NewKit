import AppKit
import CoreGraphics

/// Pops up NewKit's contextual menu when the user Control + right-clicks
/// inside Finder. This path is the *fallback* — the primary integration is
/// via the Finder Sync extension which inserts items into Finder's native
/// context menu without any modifier. We use a CGEventTap (rather than the
/// observe-only `NSEvent.addGlobalMonitorForEvents`) so we can swallow the
/// click before Finder reacts to it; otherwise Finder's own context menu
/// races our popUp and the user sees a "flash and disappear".
final class RightClickMonitor: @unchecked Sendable {
    @MainActor static let shared = RightClickMonitor()
    private init() {}

    private let lock = NSLock()
    /// True between the swallowed mouse-down and the matching mouse-up so we
    /// can also swallow the up event — leaving an unmatched up dangling makes
    /// Finder think the click never finished and can mis-render its UI.
    private var consumeNextUp: Bool = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    @MainActor
    func start() {
        if tap != nil { return }
        guard AccessibilityHelper.isTrusted else {
            Log.error("RightClickMonitor: cannot start — Accessibility not granted")
            return
        }
        let mask =
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: rightClickCallback,
            userInfo: info
        ) else {
            Log.error("RightClickMonitor: CGEvent.tapCreate returned nil — likely a TCC issue")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = source
        Log.info("RightClickMonitor: tap created and enabled")
    }

    @MainActor
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
    }

    fileprivate func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func setConsumeNextUp(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        consumeNextUp = value
    }

    fileprivate func takeConsumeNextUp() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let v = consumeNextUp
        consumeNextUp = false
        return v
    }
}

/// True when Finder is the frontmost app. Cheap enough to call from the tap
/// callback per click. Marked nonisolated so we can run from the C callback
/// without async hopping — `NSWorkspace.shared.frontmostApplication` is
/// thread-safe in practice and reads a cached value.
private func isFinderFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
}

private func rightClickCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Log.error("RightClickMonitor: tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"); re-enabling")
        if let refcon {
            let m = Unmanaged<RightClickMonitor>.fromOpaque(refcon).takeUnretainedValue()
            m.reEnable()
        }
        return Unmanaged.passUnretained(event)
    }
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<RightClickMonitor>.fromOpaque(refcon).takeUnretainedValue()

    // Match the down: only swallow when Control is held AND Finder is the
    // active app. Without Control, let Finder show its own menu (which the
    // Finder extension augments with NewKit items).
    if type == .rightMouseDown {
        let flags = event.flags
        guard flags.contains(.maskControl), isFinderFrontmost() else {
            return Unmanaged.passUnretained(event)
        }
        monitor.setConsumeNextUp(true)
        DispatchQueue.main.async {
            let location = NSEvent.mouseLocation
            let menu = ContextMenuBuilder.buildMenu()
            menu.popUp(positioning: nil, at: location, in: nil)
        }
        return nil  // swallow so Finder never starts its own menu
    }

    if type == .rightMouseUp {
        if monitor.takeConsumeNextUp() {
            return nil
        }
    }
    return Unmanaged.passUnretained(event)
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
                if let symbol = type.symbolName {
                    item.image = MenuIcon.symbol(symbol)
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
            term.image = MenuIcon.symbol("terminal")
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
