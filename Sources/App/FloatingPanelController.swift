import AppKit
import SwiftUI

/// A borderless NSPanel that floats above other windows and shows the enabled file types
/// as a grid. Activated by global shortcut.
@MainActor
final class FloatingPanelController {
    static let shared = FloatingPanelController()

    private var panel: NSPanel?
    /// When set, the next file creation will use this folder instead of the frontmost Finder window.
    private var folderOverride: URL?

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func showOverriding(folder: URL) {
        folderOverride = folder
        show()
    }

    func show() {
        if let panel {
            position(panel)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let view = FloatingPanelView(
            config: Configuration.shared,
            onSelect: { [weak self] type in
                self?.handleSelection(type)
            },
            onClose: { [weak self] in
                self?.panel?.orderOut(nil)
            }
        )

        let host = NSHostingController(rootView: view)
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = 14
        host.view.layer?.masksToBounds = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        position(panel)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { panel.center(); return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2 + 60
        )
        panel.setFrameOrigin(origin)
    }

    private func handleSelection(_ type: FileType) {
        panel?.orderOut(nil)
        let dir = folderOverride ?? FinderHelper.currentTargetPath()
        folderOverride = nil
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

// MARK: - Floating Panel View

private struct FloatingPanelView: View {
    @ObservedObject var config: Configuration
    let onSelect: (FileType) -> Void
    let onClose: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("floating.title")).font(.headline)
                Spacer()
                Text(MenuRefresher.abbreviate(FinderHelper.currentTargetPath().path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(config.visibleTypes) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: type.symbolName ?? "doc")
                                    .font(.system(size: 28))
                                Text(type.menuTitle)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            Text(L10n.string("floating.hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .onExitCommand(perform: onClose)
    }
}
