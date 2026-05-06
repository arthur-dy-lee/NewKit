import AppKit

/// Builds an `NSMenuItem` whose content is a custom `NSView` drawing a thin horizontal line.
///
/// We can't rely on `NSMenuItem.separator()` because Finder's contextual menu (kind=1) merges
/// items returned by Finder Sync extensions into its own menu, and that merge step strips —
/// or renders as a blank disabled row — items returned by `NSMenuItem.separator()`.
/// View-based items survive the merge because Finder treats them as opaque content.
enum SeparatorMenuItemFactory {
    static func make() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = SeparatorLineView()
        return item
    }
}

private final class SeparatorLineView: NSView {
    init() {
        // Width auto-stretches with the menu; height matches a system separator line.
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 9))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = NSRect(x: 14, y: bounds.midY, width: bounds.width - 28, height: 1)
        line.fill()
    }
}
