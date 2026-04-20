import Foundation

@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let cache: IPCache
    let networkMonitor: NetworkMonitor
    let sleepWakeObserver: SleepWakeObserver
    let ipService: IPService
    let regionMapper: RegionMapper
    let scheduler: RefreshScheduler
    let launchAtLogin: LaunchAtLoginService

    @MainActor
    init() {
        let cache = IPCache()
        let settings = SettingsStore()
        let networkMonitor = NetworkMonitor()
        let sleepWakeObserver = SleepWakeObserver()
        let regionMapper = RegionMapper()
        let ipService = IPService(provider: IPGuideProvider(), cache: cache)
        let scheduler = RefreshScheduler(
            ipService: ipService,
            settings: settings,
            networkMonitor: networkMonitor,
            sleepWakeObserver: sleepWakeObserver
        )
        let launchAtLogin = LaunchAtLoginService()

        self.cache = cache
        self.settings = settings
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
        self.regionMapper = regionMapper
        self.ipService = ipService
        self.scheduler = scheduler
        self.launchAtLogin = launchAtLogin
    }

    @MainActor
    func start() {
        networkMonitor.start()
        sleepWakeObserver.start()
        scheduler.start()
        Task { await ipService.refresh() }
    }

    @MainActor
    func shutdown() {
        scheduler.stop()
        sleepWakeObserver.stop()
        networkMonitor.stop()
    }
}
