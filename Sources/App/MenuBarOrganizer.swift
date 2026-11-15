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
        case accessNeeded
        case failed
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var isExpanded = false
    @Published private(set) var state: State = .off
    @Published private(set) var orderState: OrderState = .idle
    @Published private(set) var hasLayoutAccess = MenuBarSystemOrder.hasBookmark
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
    private var requestedPlacement: MenuBarPhysicalOrder.Placement?
    private var attemptedOrder: MenuBarPhysicalOrder.Plan?
    private var orderVerification: DispatchWorkItem?
    private var controlItem: NSStatusItem?
    private var activeAssertion: NSObject?
    private var pendingAssertion: NSObject?
    private var applyGeneration = 0
    private var refreshGeneration = 0
    private var refreshInProgress = false
    private var refreshRequested = false
    private var lastDiscoveryRefresh = Date.distantPast
    private var ownStatusCheckGeneration: Int?
    private var displaySleeping = false
    private var systemSleeping = false
    private var wakeGeneration = 0
    private var wakeRecoveryDeadline = Date.distantPast
    private var nextWakeRecoveryAttempt = Date.distantPast
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"
        Log.info("MenuBar diagnostics=system-order start version=\(version)(\(build)) enabled=\(enabled) "
            + "trusted=\(AccessibilityHelper.isTrusted) supported=\(isSupported) "
            + "path=\(Bundle.main.bundlePath) savedOrder=\(orderedIDs)")

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let event = name == NSWorkspace.didLaunchApplicationNotification ? "app-launch" : "app-exit"
                let reason = "\(event):\(app?.bundleIdentifier ?? "unknown")"
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.enabled { Log.info("MenuBar trigger=\(reason)") }
                    self.reconcile()
                    self.refreshApps(reason: reason)
                }
            })
        }
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.displaySleeping = true
                self.suspendForSleep()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaySleeping = false
                self?.scheduleWakeRecovery()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemSleeping = true
                self.suspendForSleep()
                self.releaseAssertions()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemSleeping = false
                self?.scheduleWakeRecovery()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleWakeRecovery() }
        })

        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
        reconcile()
        if enabled { refreshApps(reason: "startup") }
    }

    func stop() {
        Log.info("MenuBar stop")
        resetOrderAttempt()
        wakeGeneration += 1
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
        displaySleeping = false
        systemSleeping = false
        started = false
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: Key.enabled)
        resetOrderAttempt()
        if !value { isExpanded = false }
        reconcile()
        if value { refreshApps() }
    }

    func toggleHidden() {
        guard enabled, !isSleeping,
              state == .ready || state == .applying || state == .failed else { return }
        Log.info("MenuBar trigger=toggle expanded=\(isExpanded) state=\(state)")
        resetOrderAttempt()
        isExpanded.toggle()
        updateControlItem()
        applyVisibility()
    }

    func retry() {
        resetOrderAttempt()
        reconcile()
        refreshApps()
    }

    func chooseLayoutFile() {
        guard MenuBarSystemOrder.chooseFile() else { return }
        hasLayoutAccess = true
        retry()
    }

    private func resetOrderAttempt() {
        orderVerification?.cancel()
        orderVerification = nil
        attemptedOrder = nil
        orderState = .idle
    }

    private var isSleeping: Bool { displaySleeping || systemSleeping }

    private func suspendForSleep() {
        Log.info("MenuBar suspend displaySleeping=\(displaySleeping) systemSleeping=\(systemSleeping)")
        resetOrderAttempt()
        wakeGeneration += 1
        applyGeneration += 1
        ownStatusCheckGeneration = nil
        timeout?.invalidate()
        timeout = nil
        if let pendingAssertion { bridge.invalidateAssertion(pendingAssertion) }
        pendingAssertion = nil
        refreshGeneration += 1
        refreshRequested = false
        if state == .applying {
            state = activeAssertion == nil ? .failed : .ready
        }
    }

    private func scheduleWakeRecovery() {
        wakeGeneration += 1
        guard started, enabled, !isSleeping else { return }
        Log.info("MenuBar trigger=wake generation=\(wakeGeneration) state=\(state)")
        let generation = wakeGeneration
        wakeRecoveryDeadline = Date().addingTimeInterval(60)
        nextWakeRecoveryAttempt = Date().addingTimeInterval(10)
        // MenuBarAgent and its Accessibility tree may recover after the display
        // wake notification. Retry only if the first reconciliation failed.
        for (index, delay) in [0.5, 2.5, 6.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.started, self.enabled, !self.isSleeping,
                      generation == self.wakeGeneration else { return }
                guard index == 0 || self.state == .failed else { return }
                self.reconcile()
                self.refreshApps(reason: "wake:\(generation):\(index)")
            }
        }
    }

    func group(for bundleIdentifier: String) -> MenuBarGroup {
        assignments[bundleIdentifier]?.group ?? .visible
    }

    func setGroup(_ group: MenuBarGroup, for app: MenuBarAppEntry) {
        guard group != self.group(for: app.id) else { return }
        assign(app, to: group)
        saveAssignments()
        if requestedPlacement?.source == app.id || requestedPlacement?.target == app.id {
            requestedPlacement = nil
        }
        resetOrderAttempt()
        rebuildApps()
        reconcile()
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

    /// Group changes apply immediately. The next scan uses the system's latest
    /// positions to apply any new order, including items just made visible.
    func moveApp(_ sourceID: String, to group: MenuBarGroup, before targetID: String?) {
        guard let source = apps.first(where: { $0.id == sourceID }), targetID != sourceID else { return }
        let peers = apps.filter { $0.group == group && $0.id != sourceID }.map(\.id)
        if let targetID, !peers.contains(targetID) { return }
        let placement = targetID.map {
            MenuBarPhysicalOrder.Placement(source: sourceID, target: $0, after: false)
        } ?? peers.last.map {
            MenuBarPhysicalOrder.Placement(source: sourceID, target: $0, after: true)
        }
        Log.info("MenuBar trigger=settings-drop source=\(sourceID) group=\(source.group)->\(group) "
            + "before=\(targetID ?? "end")")
        assign(source, to: group)
        saveAssignments()

        var desired = apps.map(\.id).filter { $0 != sourceID }
        if let placement, let index = desired.firstIndex(of: placement.target) {
            desired.insert(sourceID, at: placement.after ? index + 1 : index)
        } else {
            desired.append(sourceID)
        }
        orderedIDs = MenuBarPhysicalOrder.savingOrder(
            desired, previous: orderedIDs, including: [sourceID] + (placement.map { [$0.target] } ?? [])
        )
        defaults.set(orderedIDs, forKey: Key.order)
        requestedPlacement = group == .alwaysHidden ? nil : placement
        resetOrderAttempt()
        rebuildApps()
        if source.group != group {
            reconcile()
        } else {
            refreshApps(reason: "settings-drop")
        }
    }

    func refreshApps(reason: String = "requested") {
        guard !isSleeping else { return }
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
                    if generation == self.refreshGeneration, !self.isSleeping {
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
                            if changed {
                                let added = discovered.subtracting(self.discoveredIDs).sorted()
                                let defaultsVisible = added.filter { self.assignments[$0] == nil }
                                Log.info("MenuBar scan=\(generation) reason=\(reason) "
                                    + "added=\(added) removed=\(self.discoveredIDs.subtracting(discovered).sorted()) "
                                    + "defaultVisible=\(defaultsVisible)")
                            }
                            self.discoveredIDs = discovered
                            // Positions describe the current physical bar only;
                            // stale coordinates would confuse reorder checks.
                            self.observedPositions = positions
                            self.rebuildApps()
                            if changed { self.applyVisibility() }
                            self.reconcilePhysicalOrder(reason: "scan:\(generation):\(reason)")
                        } else {
                            self.rebuildApps()
                        }
                    }
                    if self.refreshRequested {
                        self.refreshRequested = false
                        self.refreshApps(reason: "coalesced")
                    }
                }
            }
        }
    }

    private func healthCheck() {
        guard enabled, !isSleeping else { return }
        if !AccessibilityHelper.isTrusted || !isSupported {
            reconcile()
        } else if state == .permissionNeeded || state == .installationNeeded || state == .unavailable {
            reconcile()
            refreshApps(reason: "health-permission-recovery")
        } else if state == .failed, Date() < wakeRecoveryDeadline,
                  Date() >= nextWakeRecoveryAttempt {
            nextWakeRecoveryAttempt = Date().addingTimeInterval(10)
            reconcile()
            refreshApps(reason: "health-wake-recovery")
        } else if Date().timeIntervalSince(lastDiscoveryRefresh) >= 30 {
            // A menu bar item may register after its app's launch notification.
            // Recheck periodically so those late icons enter the Visible group.
            refreshApps(reason: "health-periodic")
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
            return
        }
        guard !isSleeping else { return }
        guard isSupported else {
            releaseAssertions()
            removeControlItem()
            state = .unavailable
            return
        }
        guard AccessibilityHelper.isTrusted else {
            releaseAssertions()
            removeControlItem()
            state = .permissionNeeded
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
        guard !isSleeping else { return }
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
        Log.error("MenuBar visibility failed; restoring all icons applyGeneration=\(applyGeneration)")
        resetOrderAttempt()
        releaseAssertions()
        state = .failed
    }

    /// A successful assertion callback does not guarantee that the system kept
    /// our control item visible. Restore the whole bar if the user would lose
    /// the only menu bar control for expanding hidden icons.
    private func verifyOwnStatusItemAfterActivation(generation: Int, attempt: Int = 0) {
        guard !isSleeping, generation == applyGeneration,
              activeAssertion != nil else { return }
        guard let ownBundle = Bundle.main.bundleIdentifier else {
            failOpen()
            return
        }
        guard ownStatusCheckGeneration != generation else { return }
        ownStatusCheckGeneration = generation
        let requiredCount = (Configuration.shared.showMenuBarIcon ? 1 : 0)
            + (controlItem == nil ? 0 : 1)
        guard requiredCount > 0 else {
            ownStatusCheckGeneration = nil
            return
        }
        let scanner = bridge
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isSleeping,
                  generation == self.applyGeneration else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let screens = Dictionary(grouping: scanner.visibleMenuBarItems()) {
                    "\(Int($0.screenFrame.minX)):\(Int($0.screenFrame.minY))"
                }
                let visibleCount = screens.values.map { items in
                    items.filter { $0.bundleIdentifier == ownBundle }.count
                }.max() ?? 0
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.ownStatusCheckGeneration == generation else { return }
                        self.ownStatusCheckGeneration = nil
                        guard !self.isSleeping, generation == self.applyGeneration,
                              self.activeAssertion != nil else { return }
                        if visibleCount < requiredCount {
                            // The menu bar's AX tree can disappear briefly as
                            // the display wakes or the login window closes.
                            if attempt < 2 {
                                self.verifyOwnStatusItemAfterActivation(
                                    generation: generation, attempt: attempt + 1
                                )
                            } else {
                                Log.error("Menu bar hiding also hid NewKit controls; restoring all icons")
                                self.failOpen()
                            }
                        }
                    }
                }
            }
        }
    }

    private func scheduleOrderRefresh() {
        let generation = applyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, generation == self.applyGeneration else { return }
            self.refreshApps(reason: "visibility-settled:\(generation)")
        }
    }

    private func reconcilePhysicalOrder(reason: String) {
        guard enabled, !isSleeping, state == .ready, AccessibilityHelper.isTrusted else { return }
        let plan = MenuBarPhysicalOrder.plan(
            visible: apps.filter { $0.group == .visible }.map(\.id),
            hidden: isExpanded ? apps.filter { $0.group == .hidden }.map(\.id) : [],
            saved: orderedIDs, positions: observedPositions, placement: requestedPlacement
        )
        if orderState == .moving {
            guard orderVerification == nil else { return }
            if observedPositions.isEmpty {
                orderState = .deferred
                return
            }
        }
        if plan.isEmpty {
            if orderState == .moving { Log.info("MenuBar system order verified reason=\(reason)") }
            if let placement = requestedPlacement, observedPositions[placement.source] != nil,
               observedPositions[placement.target] != nil { requestedPlacement = nil }
            resetOrderAttempt()
            return
        }
        if orderState == .moving {
            attemptedOrder = plan
            orderState = .failed
            Log.info("MenuBar system order verification failed reason=\(reason)")
            return
        }
        if attemptedOrder == plan, orderState != .deferred { return }
        attemptedOrder = plan
        switch MenuBarSystemOrder.apply(plan) {
        case .updated(let count):
            orderState = .moving
            Log.info("MenuBar system order updated reason=\(reason) positions=\(count)")
            let verification = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.orderVerification = nil
                self.refreshApps(reason: "verify-system-order")
            }
            orderVerification = verification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: verification)
        case .unchanged, .failed:
            orderState = .failed
            Log.info("MenuBar system order not applied reason=\(reason)")
        case .accessNeeded:
            orderState = .accessNeeded
            Log.info("MenuBar system order access needed reason=\(reason)")
        }
    }

    private func releaseAssertions() {
        applyGeneration += 1
        ownStatusCheckGeneration = nil
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

    private func assign(_ app: MenuBarAppEntry, to group: MenuBarGroup) {
        assignments[app.id] = SavedMenuBarApp(bundleIdentifier: app.id, name: app.name, group: group)
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
        let system = ids.map { makeEntry(for: $0) }.sorted { left, right in
            let a = observedPositions[left.id] ?? .infinity
            let b = observedPositions[right.id] ?? .infinity
            if a != b { return a < b }
            let names = left.name.localizedStandardCompare(right.name)
            return names == .orderedSame ? left.id < right.id : names == .orderedAscending
        }
        let byID = Dictionary(uniqueKeysWithValues: system.map { ($0.id, $0) })
        apps = MenuBarGroup.allCases.flatMap { group in
            let members = system.filter { $0.group == group }.map(\.id)
            return MenuBarPhysicalOrder.applyingSavedOrder(orderedIDs, to: members).compactMap { byID[$0] }
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
