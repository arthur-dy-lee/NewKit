import AppKit
import Combine

/// Keeps the saved NK preferences separate from the app currently processing
/// mouse input. Observe runningApplications: macOS does not send application
/// launch/exit notifications for LSUIElement apps such as Smooze Pro.
@MainActor
final class MouseEnhancementCoordinator: ObservableObject {
    static let shared = MouseEnhancementCoordinator()

    enum State: String {
        case newKit
        case smooze
        case resuming
    }

    struct CompanionProcess {
        let bundleIdentifier: String
        let processIdentifier: pid_t
    }

    @Published private(set) var state: State = .resuming
    var isSuspended: Bool { state != .newKit }

    private let processes: () -> [CompanionProcess]
    private let applyEnhancements: (Bool) -> Void
    private let resumeDelay: TimeInterval
    private let pollInterval: TimeInterval
    private let notificationCenter: NotificationCenter
    private let workspaceToObserve: NSWorkspace?
    private var applicationObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var resumeWork: DispatchWorkItem?
    private var generation = 0
    private var started = false

    init(processes: @escaping () -> [CompanionProcess] = {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let id = app.bundleIdentifier else { return nil }
            return CompanionProcess(bundleIdentifier: id, processIdentifier: app.processIdentifier)
        }
    }, applyEnhancements: @escaping (Bool) -> Void = { suspended in
        // Drain the animation queue before allowing another app to process
        // subsequent wheel events. None of these writes change preferences.
        SmoothScroller.shared.apply(suspended: suspended)
        ScrollInverter.shared.apply(suspended: suspended)
        PointerLinearizer.shared.apply(suspended: suspended)
    }, resumeDelay: TimeInterval = 0.8, pollInterval: TimeInterval = 2,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         workspaceToObserve: NSWorkspace? = .shared) {
        self.processes = processes
        self.applyEnhancements = applyEnhancements
        self.resumeDelay = resumeDelay
        self.pollInterval = pollInterval
        self.notificationCenter = notificationCenter
        self.workspaceToObserve = workspaceToObserve
    }

    nonisolated static func isSmooze(_ bundleIdentifier: String) -> Bool {
        // Match the main application's stable identity, independent of its
        // display name, installation path, or whether its menu icon is hidden.
        bundleIdentifier == "co.smoozepro.macos"
    }

    func start() {
        guard !started else { return }
        started = true
        let center = notificationCenter
        applicationObservation = workspaceToObserve?.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            // AppKit updates this KVO-compliant property on the main run loop
            // in common modes, including while a menu or settings is open.
            MainActor.assumeIsolated {
                self?.refresh(reason: "running-apps-changed")
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh(reason: "wake-or-login", reapply: true)
                }
            })
        }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(reason: "process-probe") }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        refresh(reason: "startup", reapply: true, immediateTakeover: true)
    }

    func configurationDidChange() {
        refresh(reason: "settings", reapply: true)
    }

    func stop() {
        started = false
        generation += 1
        resumeWork?.cancel()
        resumeWork = nil
        healthTimer?.invalidate()
        healthTimer = nil
        applicationObservation?.invalidate()
        applicationObservation = nil
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        state = .resuming
        applyEnhancements(true)
    }

    func refresh(reason: String, reapply: Bool = false, immediateTakeover: Bool = false) {
        guard started else { return }
        let running = processes().filter {
            Self.isSmooze($0.bundleIdentifier)
        }
        if !running.isEmpty {
            generation += 1
            resumeWork?.cancel()
            resumeWork = nil
            setState(.smooze, reason: reason, reapply: reapply)
        } else if state == .newKit || immediateTakeover {
            setState(.newKit, reason: reason, reapply: reapply)
        } else if resumeWork == nil {
            setState(.resuming, reason: reason, reapply: reapply)
            generation += 1
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.started, token == self.generation else { return }
                self.resumeWork = nil
                // Smooze may relaunch while exiting or while a settings window
                // is open. A fresh probe always wins over an old resume timer.
                self.refresh(reason: "exit-settled", immediateTakeover: true)
            }
            resumeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay, execute: work)
        } else if reapply {
            applyEnhancements(true)
        }
    }

    private func setState(_ next: State, reason: String, reapply: Bool) {
        let changed = state != next
        if changed { state = next }
        guard changed || reapply else { return }
        applyEnhancements(isSuspended)
        Log.info("MouseEnhancementCoordinator owner=\(next.rawValue) suspended=\(isSuspended) reason=\(reason)")
    }
}
