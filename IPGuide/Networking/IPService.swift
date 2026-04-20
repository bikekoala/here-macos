import Foundation

actor IPService {
    private let provider: IPProvider
    private let cache: IPCache
    private let minimumGap: TimeInterval = 5

    private var inflight: Task<IPDataModel, Error>?
    private var lastSuccessAt: Date?
    private var currentState: IPState
    private var continuations: [UUID: AsyncStream<IPState>.Continuation] = [:]

    init(provider: IPProvider, cache: IPCache) {
        self.provider = provider
        self.cache = cache
        if let cached = cache.load() {
            self.currentState = .loaded(cached.model, fetchedAt: cached.fetchedAt)
        } else {
            self.currentState = .idle
        }
    }

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

    @discardableResult
    func refresh(force: Bool = false) async -> IPState {
        if let last = lastSuccessAt, !force, Date().timeIntervalSince(last) < minimumGap {
            return currentState
        }

        if let existing = inflight {
            _ = try? await existing.value
            return currentState
        }

        emit(.loading(cached: currentState.model))

        let task = Task<IPDataModel, Error> { [provider] in
            try await Self.fetchWithRetry(using: provider)
        }
        inflight = task

        defer { inflight = nil }

        do {
            let model = try await task.value
            let fetchedAt = Date()
            cache.save(.init(model: model, fetchedAt: fetchedAt))
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

    private static func fetchWithRetry(using provider: IPProvider, maxAttempts: Int = 3) async throws -> IPDataModel {
        var attempt = 0
        var lastError: Error = IPServiceError.transport(message: "no attempts made")
        while attempt < maxAttempts {
            attempt += 1
            do {
                return try await provider.fetch()
            } catch let error as IPServiceError {
                lastError = error
                if !shouldRetry(error) || attempt == maxAttempts { throw error }
            } catch {
                lastError = error
                let mapped = IPServiceError.from(error)
                if !shouldRetry(mapped) || attempt == maxAttempts { throw mapped }
            }
            let base = pow(2.0, Double(attempt - 1))
            let jitter = Double.random(in: 0.75...1.25)
            try await Task.sleep(for: .seconds(base * jitter))
        }
        throw lastError
    }

    private static func shouldRetry(_ error: IPServiceError) -> Bool {
        switch error {
        case .timeout, .transport, .offline: true
        case .http(let code): (500..<600).contains(code)
        case .decoding, .cancelled: false
        }
    }
}
