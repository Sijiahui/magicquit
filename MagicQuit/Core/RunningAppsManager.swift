import AppKit
import Combine
import os.log

@MainActor
final class RunningAppsManager: ObservableObject {
    struct TrackedApp: Identifiable {
        let app: NSRunningApplication
        var lastActive: Date
        var id: pid_t { app.processIdentifier }
    }

    @Published private(set) var tracked: [pid_t: TrackedApp] = [:]
    @Published private(set) var wholeMacDueAt: Date?
    @Published private(set) var idlePaused = false
    @Published private(set) var waitingForUse: [pid_t: AppUseGate] = [:]

    let settings: AppSettings
    let windowWatcher: WindowWatcher

    private let startMonitoring: Bool
    private var sweepTimer: Timer?
    private var dueTimer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var suspension = IdleSuspension()
    private var perAppPauseStarted: Date?
    private var wholeMac = WholeMacIdleSession()
    private struct PendingTermination {
        let key: String?
        var manual: Bool
        var mayRelaunch: Bool
    }

    private var pending: [pid_t: PendingTermination] = [:]
    private var relaunching: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var previousMode: IdleMode
    private var perAppModeStarted: Date?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.MagicQuit", category: "RunningAppsManager")

    init(settings: AppSettings, startMonitoring: Bool = true) {
        self.settings = settings
        self.startMonitoring = startMonitoring
        self.windowWatcher = WindowWatcher(settings: settings)
        previousMode = settings.idleMode
        guard startMonitoring else { return }

        windowWatcher.terminateHandler = { [weak self] app in
            guard let self, self.pending[app.processIdentifier] == nil,
                  self.waitingForUse[app.processIdentifier] == nil else { return }
            self.quit(app)
        }

        let center = NSWorkspace.shared.notificationCenter
        func observeApp(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication) -> Void) {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { handler(app) }
            })
        }

        observeApp(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            self?.touch(app)
            self?.observeForegroundUse()
            self?.scheduleSweep()
        }
        observeApp(NSWorkspace.didDeactivateApplicationNotification) { [weak self] app in
            self?.touch(app)
            self?.clearUseBaseline(for: app.processIdentifier)
        }
        observeApp(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            self?.track(app)
            self?.scheduleSweep()
        }
        observeApp(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in self?.untrack(app) }

        func observeSession(_ name: Notification.Name, _ reason: IdleSuspension.Reason, _ active: Bool) {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSuspension(reason, active: active) }
            })
        }

        observeSession(NSWorkspace.willSleepNotification, .sleep, true)
        observeSession(NSWorkspace.didWakeNotification, .sleep, false)
        observeSession(NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true)
        observeSession(NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false)

        let distributed = DistributedNotificationCenter.default()
        func observeLock(_ name: String, _ locked: Bool) {
            distributedTokens.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSuspension(.locked, active: locked) }
            })
        }
        observeLock("com.apple.screenIsLocked", true)
        observeLock("com.apple.screenIsUnlocked", false)

        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if session[kCGSessionOnConsoleKey as String] as? Bool == false {
                suspension.set(.inactiveSession, active: true)
            }
            if session["CGSSessionScreenIsLocked"] as? Bool == true {
                suspension.set(.locked, active: true)
            }
        }
        if suspension.perAppPaused { perAppPauseStarted = Date() }
        resetWholeMac()

        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }

        // Published settings emit before assignment. Defer the sweep so it reads the new values.
        settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.sweep() }
            }
            .store(in: &cancellables)
        sweep()
    }

    deinit {
        sweepTimer?.invalidate()
        dueTimer?.invalidate()
        if !observerTokens.isEmpty {
            for token in observerTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        }
        if !distributedTokens.isEmpty {
            for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
        }
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func track(_ app: NSRunningApplication) {
        guard !app.isTerminated,
              QuitPolicy.isTrackable(bundleId: app.bundleIdentifier,
                                     activationPolicy: app.activationPolicy,
                                     ownBundleId: Bundle.main.bundleIdentifier) else { return }
        settings.migrateLegacyToggleIfNeeded(appName: app.localizedName, bundleId: app.bundleIdentifier)
        let pid = app.processIdentifier
        if tracked[pid]?.app != app {
            tracked[pid] = TrackedApp(app: app, lastActive: Date())
            if let bundleId = app.bundleIdentifier, relaunching.contains(bundleId) {
                waitingForUse[pid] = AppUseGate()
            }
        }
        windowWatcher.watch(app)
    }

    private func untrack(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard tracked[pid]?.app == app else { return }
        tracked[pid] = nil
        waitingForUse[pid] = nil
        windowWatcher.unwatch(pid)
    }

    private func touch(_ app: NSRunningApplication) {
        track(app)
        let pid = app.processIdentifier
        guard !suspension.perAppPaused, waitingForUse[pid] == nil, pending[pid] == nil else { return }
        tracked[pid]?.lastActive = Date()
    }

    private func reconcile() {
        let running = NSWorkspace.shared.runningApplications
        let runningPids = Set(running.map(\.processIdentifier))
        for entry in tracked.values {
            let app = entry.app
            if !runningPids.contains(entry.id) || app.isTerminated ||
                !QuitPolicy.isTrackable(bundleId: app.bundleIdentifier, activationPolicy: app.activationPolicy,
                                       ownBundleId: Bundle.main.bundleIdentifier) {
                untrack(app)
            }
        }
        for app in running { track(app) }
        for pid in waitingForUse.keys where !runningPids.contains(pid) { waitingForUse[pid] = nil }
    }

    private func updateSuspension(_ reason: IdleSuspension.Reason, active: Bool) {
        let wasWholePaused = suspension.wholeMacPaused
        if settings.idleMode == .wholeMac && !wasWholePaused && active && reason != .locked {
            _ = sampleWholeMac()
        }
        suspension.set(reason, active: active)
        let now = Date()
        if suspension.perAppPaused {
            if perAppPauseStarted == nil {
                perAppPauseStarted = now
                for pid in waitingForUse.keys { clearUseBaseline(for: pid) }
            }
        } else if let start = perAppPauseStarted {
            perAppPauseStarted = nil
            for pid in tracked.keys {
                if let entry = tracked[pid] {
                    tracked[pid]?.lastActive = min(now, perAppIdleStart(for: entry).addingTimeInterval(now.timeIntervalSince(start)))
                }
            }
        }

        if !active && (reason == .locked || (reason == .inactiveSession && wasWholePaused)) { resetWholeMac() }
        if suspension.wholeMacPaused || wasWholePaused { wholeMac.pause() }
        // Apply suspension synchronously, then allow AppKit and the HID clock to settle.
        scheduleSweep()
    }

    private func resetWholeMac() {
        wholeMac.reset(at: Self.uptime, hidIdle: suspension.wholeMacPaused ? nil : HIDIdle.seconds())
    }

    private func clearUseBaseline(for pid: pid_t) {
        guard var gate = waitingForUse[pid] else { return }
        _ = gate.observe(isFrontmost: false, at: Self.uptime, inputAge: nil)
        waitingForUse[pid] = gate
    }

    private func observeForegroundUse() {
        guard !suspension.perAppPaused,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pending[pid] == nil, var gate = waitingForUse[pid] else { return }

        let wasWaiting = gate
        if gate.observe(isFrontmost: true, at: Self.uptime, inputAge: AppUseGate.interactionAge()) {
            waitingForUse[pid] = nil
            tracked[pid]?.lastActive = Date()
        } else if gate != wasWaiting {
            waitingForUse[pid] = gate
        }
    }

    func updateIdleMode(at now: Date) {
        guard previousMode != settings.idleMode else { return }
        previousMode = settings.idleMode
        for pid in pending.keys { pending[pid]?.mayRelaunch = false }
        if settings.idleMode == .perApp {
            perAppModeStarted = perAppPauseStarted ?? now
        } else {
            resetWholeMac()
        }
    }

    private func perAppIdleStart(for entry: TrackedApp) -> Date {
        max(entry.lastActive, perAppModeStarted ?? entry.lastActive)
    }

    private func sweep() {
        let now = Date()
        updateIdleMode(at: now)
        reconcile()
        observeForegroundUse()
        if let frontmost = NSWorkspace.shared.frontmostApplication { touch(frontmost) }
        windowWatcher.refresh(apps: tracked.values.map(\.app))

        let threshold = TimeInterval(settings.idleMinutes) * 60
        let wholeMode = settings.idleMode == .wholeMac
        idlePaused = wholeMode ? suspension.wholeMacPaused : suspension.perAppPaused
        let wholeElapsed = wholeMode && !idlePaused ? sampleWholeMac() : nil
        wholeMacDueAt = wholeElapsed.map { now.addingTimeInterval(threshold - $0) }
        var nextCheck = wholeElapsed.map { threshold - $0 }

        if !idlePaused {
            for entry in tracked.values {
                let app = entry.app
                let action = idleAction(for: app)
                guard app.isFinishedLaunching, pending[entry.id] == nil, action != .off else { continue }
                if wholeMode {
                    guard let wholeElapsed, wholeElapsed >= threshold, let key = appKey(app),
                          !wholeMac.hasHandled(key) else { continue }
                } else {
                    guard waitingForUse[entry.id] == nil else { continue }
                    let remaining = threshold - now.timeIntervalSince(perAppIdleStart(for: entry))
                    if remaining > 0 {
                        nextCheck = min(nextCheck ?? remaining, remaining)
                        continue
                    }
                }
                if action == .restart && restartTarget(for: app) == nil { continue }
                terminate(app, automaticAction: action)
            }
        }

        if !suspension.perAppPaused, let front = NSWorkspace.shared.frontmostApplication,
           waitingForUse[front.processIdentifier] != nil, pending[front.processIdentifier] == nil {
            scheduleSweep(after: 1)
        } else if let nextCheck, nextCheck > 0, nextCheck < 30 {
            scheduleSweep(after: max(0.1, nextCheck))
        } else {
            dueTimer?.invalidate()
            dueTimer = nil
        }
    }

    private func sampleWholeMac() -> TimeInterval? {
        wholeMac.sample(at: Self.uptime, hidIdle: HIDIdle.seconds())
    }

    func refreshWholeMacCountdown(now: Date) {
        guard startMonitoring, settings.idleMode == .wholeMac else { return }
        idlePaused = suspension.wholeMacPaused
        let elapsed = idlePaused ? nil : sampleWholeMac()
        wholeMacDueAt = elapsed.map { now.addingTimeInterval(TimeInterval(settings.idleMinutes) * 60 - $0) }
    }

    private func scheduleSweep(after delay: TimeInterval = 0.1) {
        guard startMonitoring else { return }
        dueTimer?.invalidate()
        dueTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    // MARK: - App actions

    private func restartTarget(for app: NSRunningApplication) -> (bundleId: String, url: URL)? {
        guard let id = app.bundleIdentifier, let url = app.bundleURL,
              url.isFileURL, url.pathExtension.lowercased() == "app",
              Bundle(url: url)?.bundleIdentifier == id,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (id, url)
    }

    private func terminate(_ app: NSRunningApplication, automaticAction: IdleAction? = nil) {
        let pid = app.processIdentifier
        guard pending[pid] == nil else { return }
        let mode = settings.idleMode
        let target = automaticAction == .restart ? restartTarget(for: app) : nil
        pending[pid] = PendingTermination(key: appKey(app), manual: automaticAction == nil, mayRelaunch: target != nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.pending[pid] = nil
                self.scheduleSweep()
            }
            await AppTermination.perform(
                request: {
                    if let automaticAction, self.pending[pid]?.manual == false {
                        guard mode == self.settings.idleMode,
                              self.idleAction(for: app) == automaticAction else { return false }
                        let threshold = TimeInterval(self.settings.idleMinutes) * 60
                        if mode == .wholeMac {
                            guard !self.suspension.wholeMacPaused,
                                  let key = self.appKey(app), let idle = self.sampleWholeMac(),
                                  idle >= threshold, self.wholeMac.claim(key) else { return false }
                        } else {
                            guard !self.suspension.perAppPaused,
                                  let entry = self.tracked[pid], entry.app == app,
                                  self.waitingForUse[pid] == nil,
                                  NSWorkspace.shared.frontmostApplication != app,
                                  Date().timeIntervalSince(self.perAppIdleStart(for: entry)) >= threshold else { return false }
                        }
                        self.waitingForUse[pid] = AppUseGate()
                    }
                    self.log.debug("Requesting normal termination of PID \(pid)")
                    return app.terminate()
                },
                hasExited: { app.isTerminated },
                now: { Self.uptime },
                wait: { try? await Task.sleep(for: .milliseconds(250)) },
                restartIfAllowed: {
                    guard let target, self.pending[pid]?.mayRelaunch == true,
                          mode == self.settings.idleMode,
                          !(mode == .wholeMac ? self.suspension.wholeMacPaused : self.suspension.perAppPaused),
                          self.settings.idleAction(for: target.bundleId) == .restart else { return }
                    self.relaunch(bundleId: target.bundleId, url: target.url)
                }
            )
        }
    }

    private func relaunch(bundleId: String, url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), Bundle(url: url)?.bundleIdentifier == bundleId,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).allSatisfy(\.isTerminated),
              relaunching.insert(bundleId).inserted else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if let app, !app.isTerminated {
                    self.waitingForUse[app.processIdentifier] = AppUseGate()
                    self.track(app)
                }
                self.relaunching.remove(bundleId)
                if let error {
                    self.log.error("Background launch failed: \(error.localizedDescription, privacy: .public)")
                }
                self.scheduleSweep()
            }
        }
    }

    func quit(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if pending[pid] != nil {
            pending[pid]?.manual = true
            pending[pid]?.mayRelaunch = false
        } else {
            terminate(app)
        }
    }

    func resetTimer(for pid: pid_t) {
        waitingForUse[pid] = nil
        tracked[pid]?.lastActive = Date()
        scheduleSweep()
    }

    private func appKey(_ app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? app.executableURL?.path
    }

    func idleAction(for app: NSRunningApplication) -> IdleAction {
        guard let key = appKey(app) else { return .off }
        return settings.idleAction(for: key)
    }

    func availableActions(for app: NSRunningApplication) -> [IdleAction] {
        guard appKey(app) != nil else { return [.off] }
        return app.bundleIdentifier != nil && app.bundleURL != nil ? IdleAction.allCases : [.off, .quit]
    }

    func setIdleAction(_ action: IdleAction, for app: NSRunningApplication) {
        guard let key = appKey(app), availableActions(for: app).contains(action),
              settings.idleAction(for: key) != action else { return }
        settings.setIdleAction(action, for: key)
        if action != .restart {
            // Cancel a queued relaunch even if the policy is changed back before termination finishes.
            for pid in pending.keys where pending[pid]?.key == key {
                pending[pid]?.mayRelaunch = false
            }
        }
        if action != .off, waitingForUse[app.processIdentifier] == nil {
            resetTimer(for: app.processIdentifier)
        }
    }

    func remaining(for entry: TrackedApp, now: Date) -> Int {
        QuitPolicy.remainingSeconds(lastActive: perAppIdleStart(for: entry), now: perAppPauseStarted ?? now,
                                    idleMinutes: settings.idleMinutes)
    }
}
