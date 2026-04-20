import Foundation

@MainActor
final class RefreshScheduler {
    private let ipService: IPService
    private let settings: SettingsStore
    private let networkMonitor: NetworkMonitor
    private let sleepWakeObserver: SleepWakeObserver

    private var loopTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    init(
        ipService: IPService,
        settings: SettingsStore,
        networkMonitor: NetworkMonitor,
        sleepWakeObserver: SleepWakeObserver
    ) {
        self.ipService = ipService
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
    }

    func start() {
        restartLoop()
        observeNetworkEvents()
        observeWakeEvents()
        observeSettingsChanges()
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        networkTask?.cancel(); networkTask = nil
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
                case .becameReachable, .interfaceChanged:
                    Log.scheduler.info("Network event → refresh")
                    try? await Task.sleep(for: .seconds(2))
                    await ipService.refresh(force: true)
                case .becameUnreachable:
                    break
                }
            }
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
