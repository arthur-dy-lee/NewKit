import AppKit
import Combine
import SwiftUI

/// An AppKit drag source owns mouse-drag events, so the horizontal ScrollView
/// cannot turn an icon reorder into a scroll gesture.
private struct MenuBarIconDragHandle: NSViewRepresentable {
    let bundleIdentifier: String
    let appName: String
    let icon: NSImage
    let group: MenuBarGroup
    let onGroupChange: (MenuBarGroup) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.bundleIdentifier = bundleIdentifier
        view.appName = appName
        view.icon = icon
        view.group = group
        view.onGroupChange = onGroupChange
        view.toolTip = appName
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.bundleIdentifier = bundleIdentifier
        view.appName = appName
        view.icon = icon
        view.group = group
        view.onGroupChange = onGroupChange
        view.toolTip = appName
    }

    final class DragView: NSView, NSDraggingSource {
        var bundleIdentifier = ""
        var appName = ""
        var icon = NSImage()
        var group: MenuBarGroup = .visible
        var onGroupChange: ((MenuBarGroup) -> Void)?
        private var mouseDownPoint: NSPoint?
        private var dragStarted = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            for destination in MenuBarGroup.allCases {
                let item = NSMenuItem(title: destination.title,
                                      action: #selector(changeGroup(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = destination.rawValue
                item.state = destination == group ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        @objc private func changeGroup(_ item: NSMenuItem) {
            guard let rawValue = item.representedObject as? String,
                  let destination = MenuBarGroup(rawValue: rawValue) else { return }
            onGroupChange?(destination)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            dragStarted = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragStarted, let origin = mouseDownPoint,
                  !bundleIdentifier.isEmpty else { return }
            let current = convert(event.locationInWindow, from: nil)
            guard hypot(current.x - origin.x, current.y - origin.y) >= 4 else { return }

            let pasteboard = NSPasteboardItem()
            pasteboard.setString(bundleIdentifier, forType: .string)
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            let preview = icon.copy() as? NSImage ?? icon
            preview.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(NSRect(x: current.x - 16, y: current.y - 16,
                                         width: 32, height: 32), contents: preview)
            dragStarted = true
            Log.info("MenuBar drag started: \(bundleIdentifier)")
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .move]
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            mouseDownPoint = nil
            dragStarted = false
        }
    }
}

private struct MenuBarTileFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct MenuBarSettingsView: View {
    @ObservedObject private var organizer = MenuBarOrganizer.shared
    @State private var trusted = AccessibilityHelper.isTrusted
    @State private var activeDropTarget: String?
    @State private var tileFrames: [MenuBarGroup: [String: CGRect]] = [:]
    @State private var showingRunningPicker = false
    @State private var runningSearch = ""
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill"
                                              : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(L10n.string(trusted ? "perm.acc.granted" : "perm.acc.missing"))
                    Spacer()
                    if !trusted {
                        Button(L10n.string("perm.acc.request")) {
                            _ = AccessibilityHelper.requestTrustWithPrompt()
                            refreshPermissionState(retryOrganizer: true)
                        }
                        Button(L10n.string("perm.acc.opensettings")) {
                            AccessibilityHelper.openSystemSettings()
                        }
                    }
                }
                LabeledContent(L10n.string("settings.iconmanager.identity.version"),
                               value: currentVersion)
            } header: {
                Text("\(L10n.string("settings.iconmanager.identity.section")) · \(currentAppName)")
            }

            Section {
                Toggle(L10n.string("settings.iconmanager.enable"), isOn: Binding(
                    get: { organizer.enabled },
                    set: { organizer.setEnabled($0) }
                ))
                HStack {
                    Image(systemName: stateSymbol)
                        .foregroundStyle(stateColor)
                    Text(stateText)
                        .font(.callout)
                    Spacer()
                    if organizer.state == .failed {
                        Button(L10n.string("settings.iconmanager.retry")) {
                            organizer.retry()
                        }
                    }
                }
                if organizer.orderState != .idle {
                    Text(orderStatusText)
                        .font(.footnote)
                        .foregroundStyle(organizer.orderState == .failed ? .orange : .secondary)
                }
            } header: {
                Text(L10n.string("settings.iconmanager.section"))
            } footer: {
                Text(L10n.string("settings.iconmanager.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(L10n.string(organizer.isExpanded
                        ? "settings.iconmanager.collapse" : "settings.iconmanager.expand")) {
                        organizer.toggleHidden()
                    }
                    .disabled(!organizer.enabled || organizer.state != .ready ||
                              !organizer.apps.contains { $0.group == .hidden && $0.isRunning })
                    Spacer()
                    Button(L10n.string("settings.iconmanager.refresh")) {
                        organizer.refreshApps()
                    }
                    Button(L10n.string("settings.iconmanager.addrunning")) {
                        runningSearch = ""
                        showingRunningPicker = true
                    }
                }
            } header: {
                Text(L10n.string("settings.iconmanager.control"))
            } footer: {
                Text(L10n.string("settings.iconmanager.control.footer"))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if organizer.apps.isEmpty {
                Section {
                    Text(L10n.string("settings.iconmanager.noapps"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(L10n.string("settings.iconmanager.drag.hint"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(MenuBarGroup.allCases) { group in
                    Section {
                        groupLane(for: group)
                    } header: {
                        Text(group.title)
                    }
                }
            }

            Section {
                Text(L10n.string("settings.iconmanager.limitations"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshPermissionState(retryOrganizer: true) }
        .sheet(isPresented: $showingRunningPicker) {
            runningAppPicker
        }
        .onReceive(permissionTimer) { _ in refreshPermissionState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionState(retryOrganizer: true)
        }
    }

    private var currentAppName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "NewKit"
    }

    private var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func refreshPermissionState(retryOrganizer: Bool = false) {
        let now = AccessibilityHelper.isTrusted
        let changed = now != trusted
        trusted = now
        if retryOrganizer || changed || (now && organizer.state == .permissionNeeded) {
            organizer.retry()
        }
    }

    private var runningAppPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("settings.iconmanager.addrunning"))
                .font(.headline)
            Text(L10n.string("settings.iconmanager.addrunning.hint"))
                .font(.callout).foregroundStyle(.secondary)
            TextField(L10n.string("settings.iconmanager.addrunning.search"), text: $runningSearch)
                .textFieldStyle(.roundedBorder)
            let candidates = organizer.unlistedRunningApps().filter { app in
                runningSearch.isEmpty ||
                    app.name.localizedStandardContains(runningSearch) ||
                    app.id.localizedStandardContains(runningSearch)
            }
            List(candidates) { app in
                Button {
                    organizer.addRunningApp(app)
                    showingRunningPicker = false
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon)
                            .resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.id)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if candidates.isEmpty {
                Text(L10n.string("settings.iconmanager.addrunning.empty"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.string("settings.iconmanager.addrunning.close")) {
                    showingRunningPicker = false
                }
            }
        }
        .padding(20)
        .frame(width: 500, height: 450)
    }

    private func groupLane(for group: MenuBarGroup) -> some View {
        let entries = organizer.apps.filter { $0.group == group }
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Spacer().frame(width: 12) }
                    appTile(app, in: group)
                }
                appendZone(for: group, isEmpty: entries.isEmpty)
            }
            .padding(.vertical, 4)
        }
        .frame(height: 70)
        .coordinateSpace(name: "lane:\(group.rawValue)")
        .onPreferenceChange(MenuBarTileFrames.self) { frames in
            tileFrames[group] = frames
        }
        .background(activeDropTarget == "group:\(group.rawValue)"
                    ? Color.accentColor.opacity(0.09) : Color.clear)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, location in
            // One destination covers tiles, gaps, and the blank space after them.
            // Tile frames account for the lane's horizontal scroll offset.
            let beforeID = entries.first { app in
                guard let frame = tileFrames[group]?[app.id] else { return false }
                return location.x < frame.midX
            }?.id
            return acceptDrop(ids, to: group, before: beforeID)
        } isTargeted: { targeted in
            setDropTarget("group:\(group.rawValue)", targeted: targeted)
        }
    }

    private func appTile(_ app: MenuBarAppEntry, in group: MenuBarGroup) -> some View {
        Image(nsImage: app.icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 28, height: 28)
            .opacity(app.isRunning ? 1 : 0.5)
            .frame(width: 46, height: 46)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .overlay {
                MenuBarIconDragHandle(bundleIdentifier: app.id, appName: app.name,
                                      icon: app.icon, group: group) { destination in
                    organizer.setGroup(destination, for: app)
                }
            }
            .accessibilityLabel(app.name)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: MenuBarTileFrames.self,
                                           value: [app.id: proxy.frame(in: .named("lane:\(group.rawValue)"))])
                }
            }
    }

    private func appendZone(for group: MenuBarGroup, isEmpty: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.right.to.line")
            Text(L10n.string(isEmpty ? "settings.iconmanager.empty"
                                     : "settings.iconmanager.drag.end"))
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minWidth: isEmpty ? 170 : 120, minHeight: 50)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func setDropTarget(_ key: String, targeted: Bool) {
        if targeted { activeDropTarget = key }
        else if activeDropTarget == key { activeDropTarget = nil }
    }

    private func acceptDrop(_ ids: [String], to group: MenuBarGroup,
                            before targetID: String?) -> Bool {
        guard let id = ids.first,
              let source = organizer.apps.first(where: { $0.id == id }),
              source.group != group || organizer.orderState != .moving else { return false }
        Log.info("MenuBar drop: \(id) group=\(group.rawValue) target=\(targetID ?? "end")")
        organizer.moveApp(id, to: group, before: targetID)
        return true
    }

    private var orderStatusText: String {
        let key: String
        switch organizer.orderState {
        case .idle: return ""
        case .moving: key = "settings.iconmanager.order.moving"
        case .deferred: key = "settings.iconmanager.order.deferred"
        case .failed: key = "settings.iconmanager.order.failed"
        }
        return L10n.string(key)
    }

    private var stateSymbol: String {
        switch organizer.state {
        case .ready: "checkmark.circle.fill"
        case .off: "circle"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch organizer.state {
        case .ready: .green
        case .off: .secondary
        default: .orange
        }
    }

    private var stateText: String {
        let key: String
        switch organizer.state {
        case .off: key = "settings.iconmanager.state.off"
        case .permissionNeeded: key = "settings.iconmanager.state.permission"
        case .installationNeeded: key = "settings.iconmanager.state.installation"
        case .unavailable: key = "settings.iconmanager.state.unavailable"
        case .applying: key = "settings.iconmanager.state.applying"
        case .ready: key = "settings.iconmanager.state.ready"
        case .failed: key = "settings.iconmanager.state.failed"
        }
        return L10n.string(key)
    }
}
