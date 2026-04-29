import AppKit
import Foundation

/// Drives `IPService.refresh()` on a periodic loop.
///
/// Cadence is hardcoded — 5 s when the user is plausibly looking
/// at the screen, slowed to 30 s when the display is asleep. The
/// previous user-configurable picker (5 s / 1 min / 5 min) was
/// removed in v0.29.0: with the SCDynamicStore-driven network
/// observer gone, longer polling intervals would leave the widget
/// silently stale through proxy / VPN / WiFi changes for minutes
/// at a time, which contradicts the app's purpose. Hardcoding the
/// fast path keeps the UX consistent.
///
/// Auxiliary inputs:
/// - `NetworkMonitor` (NWPathMonitor): when the link drops we stop
///   firing requests and flip IPState to `.offline`; recovery on
///   `becameReachable` triggers a forced fetch.
/// - `SleepWakeObserver`: pauses the loop on lid-close so we don't
///   accumulate work, kicks a forced refresh on lid-open.
/// - `NSWorkspace` screen-sleep/wake: throttles the loop while
///   the display is off (B1: don't poll fast on a sleeping screen).
@MainActor
final class RefreshScheduler {
    private let ipService: IPService
    private let networkMonitor: NetworkMonitor
    private let sleepWakeObserver: SleepWakeObserver

    private var loopTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?

    /// `true` while the display is awake. Flipped by the NSWorkspace
    /// screen-sleep / -wake notifications. Read by the polling loop
    /// to decide between active and idle cadence.
    private var displayAwake = true

    private static let activeInterval: TimeInterval = 5
    private static let idleInterval: TimeInterval = 30

    init(
        ipService: IPService,
        networkMonitor: NetworkMonitor,
        sleepWakeObserver: SleepWakeObserver
    ) {
        self.ipService = ipService
        self.networkMonitor = networkMonitor
        self.sleepWakeObserver = sleepWakeObserver
    }

    func start() {
        observeScreenPower()
        restartLoop()
        observeNetworkEvents()
        observeWakeEvents()
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        networkTask?.cancel(); networkTask = nil
        wakeTask?.cancel(); wakeTask = nil
        if let obs = screenSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            screenSleepObserver = nil
        }
        if let obs = screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            screenWakeObserver = nil
        }
    }

    /// Manual refresh (e.g. the popover's refresh button). Bypasses
    /// IPService's 5-second `minimumGap` so the user always gets a
    /// fresh fetch when they ask for one — they're explicitly
    /// invoking the action, not riding the loop. Loud (not silent):
    /// the popover's spinner / blur overlay is the user-visible
    /// "we heard you" feedback for the click.
    func triggerNow() {
        Task { [ipService] in await ipService.refresh(force: true) }
    }

    // MARK: - Polling loop

    private var currentInterval: TimeInterval {
        displayAwake ? Self.activeInterval : Self.idleInterval
    }

    private func restartLoop() {
        loopTask?.cancel()
        Log.scheduler.info(
            "Loop restarting (interval \(self.currentInterval, privacy: .public)s, displayAwake \(self.displayAwake, privacy: .public))"
        )
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let sleepFor = self.currentInterval
                do {
                    try await Task.sleep(for: .seconds(sleepFor))
                } catch { break }
                await self.tickIfOnline()
            }
        }
    }

    private func tickIfOnline() async {
        if case .offline = networkMonitor.reachability {
            Log.scheduler.debug("Skipping tick; offline")
            return
        }
        // `silent: true` — at 5-second cadence the popover would
        // otherwise flicker its spinner-and-blur overlay every 5 s
        // and the menu-bar widget would reroll its placeholder
        // random flag through every cycle's `.loading` emission.
        // For background polling that's both ugly and useless: the
        // user didn't ask for a check, they shouldn't notice one.
        await ipService.refresh(silent: true)
    }

    // MARK: - Auxiliary observers

    private func observeNetworkEvents() {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            guard let stream = self?.networkMonitor.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .becameReachable:
                    // Network came back — fire one immediate refresh so
                    // the popover reflects the new plane without waiting
                    // up to one tick. Silent because this is a system-
                    // driven refresh, not user-driven.
                    await ipService.refresh(force: true, silent: true)
                case .becameUnreachable:
                    // Airplane mode, link down, fully offline. Drop
                    // straight into `.error(.offline)` instead of
                    // letting the next URLSession call time out —
                    // saves the user a round-trip's wait for an
                    // answer the kernel already knows.
                    await ipService.forceOffline()
                case .interfaceChanged, .pathChanged:
                    // Normal network mutations (WiFi SSID hop, VPN
                    // up/down, proxy toggle). At a 5 s loop cadence
                    // we'd see them within one tick anyway, but
                    // firing immediately removes the lag.
                    await ipService.refresh(force: true, silent: true)
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
                    // Brief settle to let the link/DHCP/DNS come back
                    // before we hit the network. Silent — wake is a
                    // system event, not a user request, so the popover
                    // shouldn't pop a loading overlay on every lid-open.
                    try? await Task.sleep(for: .seconds(1.5))
                    self.restartLoop()
                    await ipService.refresh(force: true, silent: true)
                case .willSleep:
                    loopTask?.cancel()
                }
            }
        }
    }

    /// Listen for display-sleep / display-wake. When the user's
    /// screen turns off (idle timeout, manual lock, lid close on
    /// clamshell), the polling loop drops to a 30 s cadence — there's
    /// no one looking, no point hammering ipwho.is and the network
    /// stack at full speed.
    ///
    /// Distinct from `SleepWakeObserver`, which handles full system
    /// sleep (hibernate / suspend). Display sleep is the much more
    /// common case for laptops.
    private func observeScreenPower() {
        let center = NSWorkspace.shared.notificationCenter
        screenSleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.displayAwake = false
                Log.scheduler.info("Display slept — slowing poll to \(Self.idleInterval, privacy: .public)s")
                self.restartLoop()
            }
        }
        screenWakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.displayAwake = true
                Log.scheduler.info("Display woke — speeding poll to \(Self.activeInterval, privacy: .public)s")
                self.restartLoop()
                await self.ipService.refresh(force: true, silent: true)
            }
        }
    }
}
