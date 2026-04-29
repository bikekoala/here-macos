import Foundation

actor IPService {
    private let provider: IPProvider
    private let cache: IPCache
    private let minimumGap: TimeInterval = 5

    private var inflight: Task<IPDataModel, Error>?
    private var lastSuccessAt: Date?
    private var lastDiskWriteAt: Date?
    private var currentState: IPState
    private var continuations: [UUID: AsyncStream<IPState>.Continuation] = [:]
    /// Maximum staleness for the on-disk `fetchedAt`. We dedup
    /// writes when the model is unchanged (the common case at 5 s
    /// polling), but force a save every `cacheRefreshInterval` to
    /// keep the timestamp honest — otherwise on next launch the
    /// popover would show "Updated 3 h ago" for data we actually
    /// just re-verified.
    private let cacheRefreshInterval: TimeInterval = 300

    init(provider: IPProvider, cache: IPCache) {
        self.provider = provider
        self.cache = cache
        if let cached = cache.load() {
            self.currentState = .loaded(cached.model, fetchedAt: cached.fetchedAt)
        } else {
            self.currentState = .idle
        }
    }

    /// Subscribe to IP state changes.
    ///
    /// Lifecycle: each subscriber gets a unique id slot in the
    /// `continuations` dict. On the consumer side, when the
    /// awaiting Task is cancelled or the consumer breaks out of
    /// the for-await loop, the AsyncStream calls `onTermination`,
    /// which schedules an unregister on the actor. Setting
    /// `onTermination` synchronously inside the init means
    /// termination handling is in place before any value is
    /// produced — a subscriber can't "miss" cleanup. The dict
    /// never accumulates dead entries in normal operation.
    /// (Catastrophic shutdown would orphan entries, but the
    /// actor itself dies with the process so this is bounded
    /// by app lifetime.)
    nonisolated func stateStream() -> AsyncStream<IPState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(id: UUID, continuation: AsyncStream<IPState>.Continuation) {
        continuations[id] = continuation
        continuation.yield(currentState)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func currentSnapshot() -> IPState { currentState }

    /// Transition the state to `.error(.offline, cached:)` without
    /// touching the network. Used by the scheduler when NWPathMonitor
    /// reports `.becameUnreachable` (airplane mode, link down) — the
    /// widget should reflect "we can't verify egress" instead of sitting
    /// on the last known flag, and there's no point issuing a fetch
    /// URLSession will immediately reject.
    func forceOffline() {
        if inflight != nil { return }
        let cached = cache.load()
        emit(.error(.offline, cached: cached?.model, fetchedAt: cached?.fetchedAt))
    }

    /// Flip to `.loading(cached:)` immediately, ahead of an upcoming
    /// fetch. Used by the scheduler when a network event arrives but
    /// we're going to wait a beat (2 s) before actually issuing the
    /// request. Without this the widget + popover keep rendering the
    /// prior `.error(.offline)` during the settling window, which reads
    /// as "the app hasn't noticed the network came back". No-op if a
    /// fetch is already inflight or we're already in `.loading`.
    func beginLoadingPlaceholder() {
        if inflight != nil { return }
        if case .loading = currentState { return }
        emit(.loading(cached: currentState.model))
    }

    /// Trigger an IP lookup.
    ///
    /// - Parameters:
    ///   - force: bypass the 5-second `minimumGap` between successful
    ///     fetches. Use for user-driven refreshes and one-shot
    ///     network-event reactions where stale-throttling would feel
    ///     wrong.
    ///   - silent: skip the `.loading(cached:)` intermediate emission.
    ///     A silent fetch goes directly from the prior state to the
    ///     final `.loaded` / `.error` — no UI loading flicker, no
    ///     random-flag widget reroll. Used by the periodic loop and
    ///     network-event handlers; manual refresh calls leave this
    ///     `false` so the popover's spinner-and-blur overlay still
    ///     fires as user-visible feedback.
    @discardableResult
    func refresh(force: Bool = false, silent: Bool = false) async -> IPState {
        if let last = lastSuccessAt, !force, Date().timeIntervalSince(last) < minimumGap {
            return currentState
        }

        if let existing = inflight {
            _ = try? await existing.value
            return currentState
        }

        if !silent {
            emit(.loading(cached: currentState.model))
        }

        // Single attempt. Previously this retried up to 3× with exponential
        // backoff, which made a failure sequence hammer an unreachable host
        // for ~45 s — noisy when the user is on a network that can't reach
        // the upstream provider. If the first try fails, we just drop into
        // `.error` and wait for the next scheduler/network-event trigger.
        let task = Task<IPDataModel, Error> { [provider] in
            try await provider.fetch()
        }
        inflight = task

        defer { inflight = nil }

        do {
            let model = try await task.value
            let fetchedAt = Date()
            let modelChanged = model != currentState.model
            let cacheStale = lastDiskWriteAt
                .map { fetchedAt.timeIntervalSince($0) >= cacheRefreshInterval }
                ?? true
            if modelChanged || cacheStale {
                cache.save(.init(model: model, fetchedAt: fetchedAt))
                lastDiskWriteAt = fetchedAt
            }
            lastSuccessAt = fetchedAt
            emit(.loaded(model, fetchedAt: fetchedAt))
        } catch {
            let err = IPServiceError.from(error)
            let cached = cache.load()
            emit(.error(err, cached: cached?.model, fetchedAt: cached?.fetchedAt))
        }

        return currentState
    }

    private func emit(_ state: IPState) {
        currentState = state
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
