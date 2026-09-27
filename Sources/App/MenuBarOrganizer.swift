import AppKit
import Combine

// The bridge's discovery method reads immutable runtime metadata and AX state.
// Assertion activation and invalidation remain on the main actor.
extension MenuBarNativeBridge: @unchecked Sendable {}

enum MenuBarGroup: String, Codable, CaseIterable, Identifiable {
    case visible
    case hidden
    case alwaysHidden

    var id: String { rawValue }

    var title: String {
        L10n.string("settings.iconmanager.group.\(rawValue)")
    }
}

struct MenuBarAppEntry: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let isRunning: Bool
    let group: MenuBarGroup
}

private struct SavedMenuBarApp: Codable {
    let bundleIdentifier: String
    var name: String
    var group: MenuBarGroup
}

/// Keeps the macOS 27 assessment assertion alive while selected menu bar apps
/// are hidden. All persistent choices are per app bundle, rather than per icon.
@MainActor
final class MenuBarOrganizer: ObservableObject {
    static let shared = MenuBarOrganizer()

    enum State: Equatable {
        case off
        case permissionNeeded
        case installationNeeded
        case unavailable
        case applying
        case ready
        case failed
    }

    enum OrderState: Equatable {
        case idle
        case moving
        case deferred
        case failed
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var isExpanded = false
    @Published private(set) var state: State = .off
    @Published private(set) var orderState: OrderState = .idle
    @Published private(set) var apps: [MenuBarAppEntry] = []

    private enum Key {
        static let enabled = "menuBarOrganizerEnabled"
        static let assignments = "menuBarOrganizerAssignments"
        static let order = "menuBarOrganizerOrder"
    }

    private let defaults = SharedDefaults.store
    private let bridge = MenuBarNativeBridge()
    private var assignments: [String: SavedMenuBarApp]
    private var orderedIDs: [String]
    private var discoveredIDs = Set<String>()
    private var observedPositions: [String: CGFloat] = [:]
    private struct PendingReorder {
        let sourceID: String
        let targetID: String
        let placeAfter: Bool
        let previousOrder: [String]
        let generation: Int
    }
    private struct DeferredReorder: Equatable {
        let sourceID: String
        let target: MenuBarPhysicalOrder.Move.Target
        let placeAfter: Bool
    }
    private var pendingReorder: PendingReorder?
    private var deferredMoves: [DeferredReorder] = []
    private var reorderGeneration = 0
    private var physicalMoveInFlight = false
    private var controlItem: NSStatusItem?
    private var activeAssertion: NSObject?
    private var pendingAssertion: NSObject?
    private var applyGeneration = 0
    private var refreshGeneration = 0
    private var refreshInProgress = false
    private var refreshRequested = false
    private var lastDiscoveryRefresh = Date.distantPast
    private var ownStatusCheckInProgress = false
    private var timeout: Timer?
    private var healthTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {
        enabled = defaults.bool(forKey: Key.enabled)
        orderedIDs = defaults.stringArray(forKey: Key.order) ?? []
        if let data = defaults.data(forKey: Key.assignments),
           let saved = try? JSONDecoder().decode([SavedMenuBarApp].self, from: data) {
            assignments = saved.reduce(into: [:]) { result, app in
                result[app.bundleIdentifier] = app
            }
        } else {
            assignments = [:]
        }
        rebuildApps()
    }

    var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 && bridge.isAvailable
    }

    /// Assessment mode identifies bundles through LaunchServices. A build
    /// launched directly from DerivedData is not necessarily registered there.
    private var isRegisteredApplication: Bool {
        guard let id = Bundle.main.bundleIdentifier,
              let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return false }
        return registered.resolvingSymlinksInPath().standardizedFileURL
            == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func start() {
        guard !started else { return }
        started = true

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reconcile()
                    self?.refreshApps()
                }
            })
        }
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAssertions() }
        })

        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
        reconcile()
        if enabled { refreshApps() }
    }

    func stop() {
        reorderGeneration += 1
        pendingReorder = nil
        refreshGeneration += 1
        refreshRequested = false
        healthTimer?.invalidate()
        healthTimer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        releaseAssertions()
        removeControlItem()
        started = false
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: Key.enabled)
        if !value { isExpanded = false }
        reconcile()
        if value { refreshApps() }
    }

    func toggleHidden() {
        guard enabled, state == .ready || state == .applying else { return }
        // An in-flight drag may finish after the visibility assertion changes.
        // Ignore its result and reconcile against the new displayed set.
        reorderGeneration += 1
        pendingReorder = nil
        deferredMoves.removeAll()
        orderState = .idle
        isExpanded.toggle()
        updateControlItem()
        applyVisibility()
    }

    func retry() {
        reconcile()
        refreshApps()
    }

    func group(for bundleIdentifier: String) -> MenuBarGroup {
        assignments[bundleIdentifier]?.group ?? .visible
    }

    func setGroup(_ group: MenuBarGroup, for app: MenuBarAppEntry) {
        guard app.group != group else { return }
        moveApp(app.id, to: group, before: nil)
    }

    /// Running helpers whose status items are not exposed by Accessibility can
    /// still be added by bundle identifier and managed by the visibility rule.
    func unlistedRunningApps() -> [MenuBarAppEntry] {
        let excluded = discoveredIDs.union(assignments.keys)
            .union(["com.apple.MenuBarAgent", "com.apple.controlcenter",
                    "com.apple.systemuiserver", Bundle.main.bundleIdentifier ?? ""])
        var runningByID: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !excluded.contains(id),
                  runningByID[id] == nil else { continue }
            runningByID[id] = app
        }
        return runningByID.map { makeEntry(for: $0.key, running: $0.value) }
            .sorted { left, right in
                let result = left.name.localizedStandardCompare(right.name)
                return result == .orderedSame ? left.id < right.id : result == .orderedAscending
            }
    }

    func addRunningApp(_ app: MenuBarAppEntry) {
        guard !apps.contains(where: { $0.id == app.id }),
              !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty
        else { return }
        assignments[app.id] = SavedMenuBarApp(
            bundleIdentifier: app.id, name: app.name, group: .visible
        )
        saveAssignments()
        rebuildApps()
    }

    /// The order within each section is the physical left-to-right order. A
    /// same-section drag is verified immediately; section changes are reconciled
    /// after the visibility assertion updates the menu bar.
    func moveApp(_ sourceID: String, to group: MenuBarGroup, before targetID: String?) {
        guard let source = apps.first(where: { $0.id == sourceID }),
              targetID != sourceID else { return }
        // A physical reorder may still be settling. A change of group is a
        // visibility choice and should take effect as soon as the tile drops.
        guard source.group != group || orderState != .moving else { return }
        if let targetID {
            guard apps.contains(where: { $0.id == targetID && $0.group == group }) else { return }
        }

        let previousGroup = source.group
        let previousDisplayedIDs = desiredDisplayedIDs()
        let previousOrder = apps.map(\.id)
        assignments[sourceID] = SavedMenuBarApp(
            bundleIdentifier: sourceID, name: source.name, group: group
        )
        saveAssignments()

        var nextOrder = previousOrder.filter { $0 != sourceID }
        if let targetID, let index = nextOrder.firstIndex(of: targetID) {
            nextOrder.insert(sourceID, at: index)
        } else if let last = nextOrder.lastIndex(where: { self.group(for: $0) == group }) {
            nextOrder.insert(sourceID, at: last + 1)
        } else {
            nextOrder.append(sourceID)
        }
        orderedIDs = nextOrder
        defaults.set(orderedIDs, forKey: Key.order)
        rebuildApps()

        reorderGeneration += 1
        deferredMoves.removeAll()
        let desired = desiredDisplayedIDs()
        let sourceIndex = desired.firstIndex(of: sourceID)
        let previousIndex = previousDisplayedIDs.firstIndex(of: sourceID)
        let physicalTargetID: String?
        let placeAfter: Bool
        if previousGroup == group, let sourceIndex, let previousIndex,
           sourceIndex > previousIndex {
            physicalTargetID = desired[sourceIndex - 1]
            placeAfter = true
        } else if previousGroup == group, let sourceIndex, let previousIndex,
                  sourceIndex < previousIndex, sourceIndex + 1 < desired.count {
            physicalTargetID = desired[sourceIndex + 1]
            placeAfter = false
        } else {
            physicalTargetID = nil
            placeAfter = false
        }
        if let physicalTargetID, previousGroup == group, enabled,
           state == .ready, AccessibilityHelper.isTrusted,
           observedPositions[sourceID] != nil,
           observedPositions[physicalTargetID] != nil {
            pendingReorder = PendingReorder(
                sourceID: sourceID, targetID: physicalTargetID,
                placeAfter: placeAfter,
                previousOrder: previousOrder, generation: reorderGeneration
            )
            orderState = .moving
        } else {
            pendingReorder = nil
            orderState = physicalTargetID == nil || !enabled ? .idle : .deferred
        }

        if previousGroup != group { reconcile() }
        startPendingReorderIfReady()
        reconcilePhysicalOrder()
    }

    func refreshApps() {
        guard AccessibilityHelper.isTrusted else {
            refreshGeneration += 1
            refreshRequested = false
            // Keep the last known apps in the settings list if Accessibility
            // becomes temporarily unavailable. Their saved groups still apply.
            rebuildApps()
            if enabled { reconcile() }
            return
        }
        guard !refreshInProgress else {
            refreshRequested = true
            return
        }
        refreshInProgress = true
        refreshGeneration += 1
        lastDiscoveryRefresh = Date()
        let generation = refreshGeneration
        let scanner = bridge
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = scanner.discoverBundleIdentifiers().map(Set.init)
            let hosted = scanner.visibleMenuBarItems()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshInProgress = false
                    if generation == self.refreshGeneration {
                        if let found {
                            // Use the same screen for app positions and the
                            // chevron. Its location is the physical boundary
                            // between Hidden and Visible, not just another app.
                            let divider = self.controlItem.flatMap {
                                self.bridge.visibleMenuBarItem(for: $0)
                            }
                            let byScreen = Dictionary(grouping: hosted) { item in
                                "\(Int(item.screenFrame.minX)):\(Int(item.screenFrame.minY))"
                            }
                            let screenItems = divider.map { divider in
                                hosted.filter { $0.screenFrame == divider.screenFrame }
                            } ?? byScreen.values.max { $0.count < $1.count } ?? []
                            var positions: [String: CGFloat] = [:]
                            for item in screenItems {
                                let x = item.frame.minX
                                positions[item.bundleIdentifier] = min(positions[item.bundleIdentifier] ?? x, x)
                            }
                            if let divider {
                                positions[MenuBarPhysicalOrder.dividerID] = divider.frame.minX
                            }
                            // A scan can omit an icon while its app is starting
                            // or while another visibility rule is active. Keep
                            // known running apps instead of making them vanish.
                            let runningIDs = Set(NSWorkspace.shared.runningApplications
                                .compactMap(\.bundleIdentifier))
                            let discovered = found.union(self.discoveredIDs.intersection(runningIDs))
                            let changed = self.discoveredIDs != discovered
                            self.discoveredIDs = discovered
                            // Positions describe the current physical bar only;
                            // stale coordinates would confuse reorder checks.
                            self.observedPositions = positions
                            self.rebuildApps()
                            if changed { self.applyVisibility() }
                            self.reconcilePhysicalOrder()
                        } else {
                            self.rebuildApps()
                        }
                    }
                    if self.refreshRequested {
                        self.refreshRequested = false
                        self.refreshApps()
                    }
                }
            }
        }
    }

    private func healthCheck() {
        guard enabled else { return }
        if !AccessibilityHelper.isTrusted || !isSupported {
            reconcile()
        } else if state == .permissionNeeded || state == .installationNeeded || state == .unavailable {
            reconcile()
            refreshApps()
        } else if Date().timeIntervalSince(lastDiscoveryRefresh) >= 30 {
            // A menu bar item may register after its app's launch notification.
            // Recheck periodically so those late icons enter the Visible group.
            refreshApps()
        }
        if activeAssertion != nil {
            verifyOwnStatusItemAfterActivation(generation: applyGeneration)
        }
    }

    private func reconcile() {
        guard enabled else {
            releaseAssertions()
            removeControlItem()
            state = .off
            startDeferredReorderIfReady()
            return
        }
        guard isSupported else {
            releaseAssertions()
            removeControlItem()
            state = .unavailable
            failPendingReorder()
            return
        }
        guard AccessibilityHelper.isTrusted else {
            releaseAssertions()
            removeControlItem()
            state = .permissionNeeded
            failPendingReorder()
            return
        }
        guard isRegisteredApplication else {
            releaseAssertions()
            removeControlItem()
            state = .installationNeeded
            return
        }
        applyVisibility()
    }

    private func installControlItem() {
        guard controlItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "NewKit.MenuBarOrganizer"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(toggleFromMenuBar(_:))
        controlItem = item
        updateControlItem()
    }

    private func removeControlItem() {
        guard let controlItem else { return }
        NSStatusBar.system.removeStatusItem(controlItem)
        self.controlItem = nil
    }

    private func updateControlItem() {
        guard let button = controlItem?.button else { return }
        let symbol = isExpanded ? "chevron.right" : "chevron.left"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NewKit")
        button.image?.isTemplate = true
        button.toolTip = L10n.string(isExpanded
            ? "settings.iconmanager.collapse" : "settings.iconmanager.expand")
    }

    /// The reveal control is useful only while a running app has been assigned
    /// to the expandable Hidden section. Always Hidden items cannot be revealed.
    private func syncControlItem(runningIDs: Set<String>) {
        let hasHiddenItem = assignments.values.contains {
            $0.group == .hidden && runningIDs.contains($0.bundleIdentifier)
        }
        if hasHiddenItem {
            installControlItem()
            updateControlItem()
        } else {
            isExpanded = false
            removeControlItem()
        }
    }

    @objc private func toggleFromMenuBar(_ sender: Any?) {
        toggleHidden()
    }

    private func applyVisibility() {
        guard enabled, isSupported, AccessibilityHelper.isTrusted,
              isRegisteredApplication else {
            reconcile()
            return
        }
        applyGeneration += 1
        let generation = applyGeneration
        timeout?.invalidate()
        timeout = nil
        if let pendingAssertion {
            bridge.invalidateAssertion(pendingAssertion)
            self.pendingAssertion = nil
        }

        let actualRunningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        syncControlItem(runningIDs: actualRunningIDs)
        let hiddenIDs = Set(assignments.values.compactMap { saved -> String? in
            if saved.group == .alwaysHidden || (saved.group == .hidden && !isExpanded) {
                return saved.bundleIdentifier
            }
            return nil
        })
        let runningIDs = actualRunningIDs.union(discoveredIDs)
        guard !hiddenIDs.isDisjoint(with: runningIDs) else {
            releaseAssertions()
            state = .ready
            startPendingReorderIfReady()
            scheduleOrderRefresh()
            return
        }

        var allowed = runningIDs
        allowed.subtract(hiddenIDs)
        if let ownBundle = Bundle.main.bundleIdentifier { allowed.insert(ownBundle) }
        state = .applying

        let candidate = bridge.activateAllowingBundleIdentifiers(allowed.sorted()) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, generation == self.applyGeneration else { return }
                self.timeout?.invalidate()
                self.timeout = nil
                guard error == nil, let pending = self.pendingAssertion else {
                    self.failOpen()
                    return
                }
                if let old = self.activeAssertion { self.bridge.invalidateAssertion(old) }
                self.activeAssertion = pending
                self.pendingAssertion = nil
                self.state = .ready
                self.verifyOwnStatusItemAfterActivation(generation: generation)
                self.startPendingReorderIfReady()
                self.scheduleOrderRefresh()
            }
        } as? NSObject

        guard let candidate else {
            failOpen()
            return
        }
        pendingAssertion = candidate
        timeout = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.applyGeneration else { return }
                self.failOpen()
            }
        }
    }

    private func failOpen() {
        releaseAssertions()
        state = .failed
        failPendingReorder()
    }

    /// A successful assertion callback does not guarantee that the system kept
    /// our control item visible. Restore the whole bar if the user would lose
    /// the only menu bar control for expanding hidden icons.
    private func verifyOwnStatusItemAfterActivation(generation: Int) {
        guard let ownBundle = Bundle.main.bundleIdentifier else {
            failOpen()
            return
        }
        guard !ownStatusCheckInProgress else { return }
        ownStatusCheckInProgress = true
        let requiredCount = (Configuration.shared.showMenuBarIcon ? 1 : 0)
            + (controlItem == nil ? 0 : 1)
        guard requiredCount > 0 else {
            ownStatusCheckInProgress = false
            return
        }
        let scanner = bridge
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let screens = Dictionary(grouping: scanner.visibleMenuBarItems()) {
                    "\(Int($0.screenFrame.minX)):\(Int($0.screenFrame.minY))"
                }
                let visibleCount = screens.values.map { items in
                    items.filter { $0.bundleIdentifier == ownBundle }.count
                }.max() ?? 0
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.ownStatusCheckInProgress = false
                        guard generation == self.applyGeneration,
                              self.activeAssertion != nil else { return }
                        if visibleCount < requiredCount {
                            Log.error("Menu bar hiding also hid NewKit controls; restoring all icons")
                            self.failOpen()
                        }
                    }
                }
            }
        }
    }

    private func startPendingReorderIfReady() {
        guard enabled, state == .ready, !physicalMoveInFlight,
              let move = pendingReorder else { return }
        pendingReorder = nil
        physicalMoveInFlight = true
        bridge.moveBundleIdentifier(move.sourceID,
                                    relativeToBundleIdentifier: move.targetID,
                                    placeAfter: move.placeAfter) { [weak self] moved in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.physicalMoveInFlight = false
                guard move.generation == self.reorderGeneration else {
                    self.refreshApps()
                    return
                }
                if moved {
                    self.orderState = .idle
                    self.refreshApps()
                } else {
                    self.orderedIDs = move.previousOrder
                    self.defaults.set(self.orderedIDs, forKey: Key.order)
                    self.rebuildApps()
                    self.orderState = .failed
                }
            }
        }
    }

    private func desiredDisplayedIDs() -> [String] {
        let visible = apps.filter { $0.group == .visible }.map(\.id)
        let hidden = apps.filter { $0.group == .hidden }.map(\.id)
        return MenuBarPhysicalOrder.displayedIDs(
            visible: visible, hidden: hidden, expanded: isExpanded
        )
    }

    /// The assessment assertion may restore items asynchronously. Read their
    /// actual positions after it settles, then place hidden items before the
    /// visible section without moving already ordered visible items.
    private func scheduleOrderRefresh() {
        let generation = applyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, generation == self.applyGeneration else { return }
            self.refreshApps()
        }
    }

    private func reconcilePhysicalOrder() {
        guard enabled, state == .ready, AccessibilityHelper.isTrusted,
              !physicalMoveInFlight, pendingReorder == nil, deferredMoves.isEmpty,
              orderState != .moving, orderState != .failed else { return }
        let visible = apps.filter { $0.group == .visible }.map(\.id)
        let hidden = apps.filter { $0.group == .hidden }.map(\.id)
        if controlItem != nil {
            // A hidden icon can have the correct order among apps while it is
            // still physically to the right of the reveal control. Keep the
            // divider in the plan, and wait for it to be observable rather
            // than accepting an app-only ordering as complete.
            guard let dividerX = observedPositions[MenuBarPhysicalOrder.dividerID] else {
                orderState = .deferred
                return
            }
            deferredMoves = MenuBarPhysicalOrder.movesToMatch(
                visible: visible, hidden: hidden, expanded: isExpanded,
                positions: observedPositions, dividerX: dividerX
            ).map { DeferredReorder(sourceID: $0.sourceID,
                                    target: $0.target, placeAfter: $0.placeAfter) }
        } else {
            deferredMoves = MenuBarPhysicalOrder.movesToMatch(
                desiredDisplayedIDs(), positions: observedPositions
            ).map { DeferredReorder(sourceID: $0.0, target: .app($0.1),
                                    placeAfter: false) }
        }
        guard !deferredMoves.isEmpty else {
            orderState = .idle
            return
        }
        orderState = .deferred
        startDeferredReorderIfReady()
    }

    private func startDeferredReorderIfReady() {
        guard enabled, state == .ready, pendingReorder == nil,
              !physicalMoveInFlight, orderState != .moving,
              AccessibilityHelper.isTrusted,
              let move = deferredMoves.first else { return }

        if case .control = move.target, controlItem == nil { return }
        reorderGeneration += 1
        let generation = reorderGeneration
        orderState = .moving
        physicalMoveInFlight = true
        let completion: (Bool) -> Void = { [weak self] moved in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.physicalMoveInFlight = false
                guard generation == self.reorderGeneration else {
                    self.refreshApps()
                    return
                }
                if moved {
                    if self.deferredMoves.first == move {
                        self.deferredMoves.removeFirst()
                    }
                    self.orderState = self.deferredMoves.isEmpty ? .idle : .deferred
                    if self.deferredMoves.isEmpty { self.refreshApps() }
                    else { self.startDeferredReorderIfReady() }
                } else {
                    self.deferredMoves.removeAll()
                    self.orderState = .failed
                }
            }
        }
        switch move.target {
        case .app(let targetID):
            bridge.moveBundleIdentifier(move.sourceID,
                                        relativeToBundleIdentifier: targetID,
                                        placeAfter: move.placeAfter,
                                        completion: completion)
        case .control:
            bridge.moveBundleIdentifier(move.sourceID,
                                        relativeToStatusItem: controlItem!,
                                        placeAfter: move.placeAfter,
                                        completion: completion)
        }
    }

    private func failPendingReorder() {
        guard let move = pendingReorder else { return }
        pendingReorder = nil
        orderedIDs = move.previousOrder
        defaults.set(orderedIDs, forKey: Key.order)
        rebuildApps()
        orderState = .failed
    }

    private func releaseAssertions() {
        applyGeneration += 1
        timeout?.invalidate()
        timeout = nil
        if let pendingAssertion { bridge.invalidateAssertion(pendingAssertion) }
        if let activeAssertion { bridge.invalidateAssertion(activeAssertion) }
        pendingAssertion = nil
        activeAssertion = nil
    }

    private func saveAssignments() {
        let list = assignments.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Key.assignments)
        }
    }

    private func rebuildApps() {
        let ownBundle = Bundle.main.bundleIdentifier
        let systemHosts: Set<String> = [
            "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"
        ]
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let ids = discoveredIDs.union(assignments.keys).filter { id in
            runningIDs.contains(id) && id != ownBundle && !systemHosts.contains(id)
        }
        var savedOrder: [String: Int] = [:]
        for (index, id) in orderedIDs.enumerated() where savedOrder[id] == nil {
            savedOrder[id] = index
        }
        apps = ids.map { makeEntry(for: $0) }.sorted { left, right in
            if let a = savedOrder[left.id], let b = savedOrder[right.id] { return a < b }
            if savedOrder[left.id] != nil { return true }
            if savedOrder[right.id] != nil { return false }
            if let a = observedPositions[left.id], let b = observedPositions[right.id] { return a < b }
            if observedPositions[left.id] != nil { return true }
            if observedPositions[right.id] != nil { return false }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private func makeEntry(for id: String, running existing: NSRunningApplication? = nil) -> MenuBarAppEntry {
        let running = existing ?? NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        let url = representativeURL(for: running?.bundleURL)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
            ?? url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
            ?? running?.localizedName
            ?? assignments[id]?.name
            ?? id
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? running?.icon
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: name)
            ?? NSImage()
        return MenuBarAppEntry(id: id, name: name, icon: icon,
                               isRunning: running != nil, group: group(for: id))
    }

    private func representativeURL(for bundleURL: URL?) -> URL? {
        guard let bundleURL else { return nil }
        var candidate = bundleURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return bundleURL
    }
}
