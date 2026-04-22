import Foundation

@MainActor
final class RefreshScheduler {
    private let ipService: IPService
    private let settings: SettingsStore
    private let networkMonitor: NetworkMonitor
    private let sleepWakeObserver: SleepWakeObserver
    private let systemNetworkObserver: SystemNetworkObserver

    private var loopTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var systemNetworkTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    /// Last time a network/proxy-driven refresh actually fired. Used to
    /// collapse bursts — if interfaceChanged and pathChanged land within
    /// a few seconds of each other, the second fires a no-op.
    private var lastNetworkTriggeredRefresh: Date = .distantPast

    /// Last time a network-triggered refresh ended in `.error`. Within a
    /// window after this, further network events are ignored: the user
    /// opted out of retry behaviour. Manual refresh (right-click menu,
    /// popover button) bypasses this — it calls `triggerNow()` directly,
    /// not through this coalesce path.
    private var lastFailedNetworkRefresh: Date = .distantPast

    /// Minimum gap between two network-triggered refreshes during normal
    /// operation. Narrow — a single network change typically emits
    /// systemStateChanged + interfaceChanged + pathChanged within a few seconds
    /// and we want one refresh per change, not three.
    private static let networkRefreshCoalesceWindow: TimeInterval = 5

    /// After a network-triggered refresh fails, ignore further network
    /// events for this long. Prevents the "I switched networks, it
    /// loaded, failed, and then started loading again by itself" pattern
    /// — the user explicitly doesn't want retries. Long enough to
    /// absorb the tail of a network-settling event storm; short enough
    /// that if the user deliberately switches to a working node after
    /// waiting, the next change still triggers a fresh attempt.
    private static let postErrorCooldown: TimeInterval = 30

    init(
        ipService: IPService,
        settings: SettingsStore,
        networkMonitor: NetworkMonitor,
        sleepWakeObserver: SleepWakeObserver,
        systemNetworkObserver: SystemNetworkObserver
    ) {
        self.ipService = ipService
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
        self.systemNetworkObserver = systemNetworkObserver
    }

    func start() {
        restartLoop()
        observeNetworkEvents()
        observeSystemNetworkEvents()
        observeWakeEvents()
        observeSettingsChanges()
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        networkTask?.cancel(); networkTask = nil
        systemNetworkTask?.cancel(); systemNetworkTask = nil
        wakeTask?.cancel(); wakeTask = nil
        settingsTask?.cancel(); settingsTask = nil
    }

    func triggerNow() {
        Task { [ipService] in await ipService.refresh(force: true) }
    }

    private func restartLoop() {
        loopTask?.cancel()
        let interval = settings.refreshInterval.seconds
        Log.scheduler.info("Loop restarting with interval \(interval, privacy: .public)s")
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
                guard let self else { break }
                await self.tickIfOnline()
            }
        }
    }

    private func tickIfOnline() async {
        if case .offline = networkMonitor.reachability {
            Log.scheduler.debug("Skipping tick; offline")
            return
        }
        await ipService.refresh()
    }

    private func observeNetworkEvents() {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            guard let stream = self?.networkMonitor.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .becameReachable, .interfaceChanged, .pathChanged:
                    guard settings.refreshOnNetworkChange else { continue }
                    try? await Task.sleep(for: .seconds(2))
                    await fireNetworkTriggeredRefresh(
                        reason: String(describing: event)
                    )
                case .becameUnreachable:
                    break
                }
            }
        }
    }

    private func observeSystemNetworkEvents() {
        systemNetworkTask?.cancel()
        systemNetworkTask = Task { [weak self] in
            guard let stream = self?.systemNetworkObserver.events() else { return }
            for await _ in stream {
                guard let self else { return }
                guard settings.refreshOnNetworkChange else { continue }
                // 2 s matches the NWPathMonitor leg — give URLSession's
                // connection cache + DNS resolver a beat to notice the
                // new network plane before we fire the probe.
                try? await Task.sleep(for: .seconds(2))
                await fireNetworkTriggeredRefresh(reason: "systemStateChanged")
            }
        }
    }

    /// Coalesce network-triggered refreshes. Two gates:
    ///  1. Post-error cooldown: once a refresh failed, sit out further
    ///     auto-retries for a while. The user asked for one shot, not
    ///     a retry storm when the network settles.
    ///  2. Burst coalesce: a single network change often emits multiple
    ///     events (systemStateChanged + interfaceChanged + pathChanged). Fire
    ///     one refresh per change, not one per event.
    private func fireNetworkTriggeredRefresh(reason: String) async {
        let now = Date()
        if now.timeIntervalSince(lastFailedNetworkRefresh) < Self.postErrorCooldown {
            Log.scheduler.info(
                "Post-error cooldown — skipping \(reason, privacy: .public)"
            )
            return
        }
        if now.timeIntervalSince(lastNetworkTriggeredRefresh)
            < Self.networkRefreshCoalesceWindow {
            Log.scheduler.debug(
                "Coalescing network event → skip refresh (\(reason, privacy: .public))"
            )
            return
        }
        lastNetworkTriggeredRefresh = now
        Log.scheduler.info("Network event → refresh (\(reason, privacy: .public))")
        let state = await ipService.refresh(force: true)
        if case .error = state {
            lastFailedNetworkRefresh = Date()
            Log.scheduler.info("Refresh failed — 30 s cooldown armed")
        }
    }

    private func observeWakeEvents() {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let stream = self?.sleepWakeObserver.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .didWake:
                    try? await Task.sleep(for: .seconds(1.5))
                    self.restartLoop()
                    await ipService.refresh(force: true)
                case .willSleep:
                    loopTask?.cancel()
                }
            }
        }
    }

    private func observeSettingsChanges() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else { return }
            var lastInterval = settings.refreshInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let current = settings.refreshInterval
                if current != lastInterval {
                    lastInterval = current
                    self.restartLoop()
                }
            }
        }
    }
}
