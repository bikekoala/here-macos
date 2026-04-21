import Foundation

/// One completed throughput measurement. Persisted as the "last result" so
/// reopening the popover shows the prior numbers immediately instead of
/// blanking out.
struct ThroughputResult: Codable, Sendable, Equatable {
    let downloadMbps: Double
    let uploadMbps: Double
    let testedAt: Date
}

/// State machine for the on-demand throughput probe.
///
/// Intentional UX: while a probe is in flight, the two speed numbers are
/// blanked out — we only fill in a direction's final value once that
/// direction's measurement finishes. So during the download phase: ↓ says
/// "…" (animating), ↑ says "…" (waiting); after download lands: ↓ shows the
/// fresh number, ↑ is now animating; when upload lands: both idle.
enum ThroughputStatus: Sendable, Equatable {
    case idle(lastResult: ThroughputResult?)

    /// Probing is in progress.
    /// - `phase` = which direction is currently being measured
    /// - `completedDownloadMbps` is set to the just-measured download value
    ///   once the download phase finishes, so the UI can flip the download
    ///   block from "…" to the real reading while the upload phase runs
    /// - `liveMbps` is a rolling estimate for the active phase, pushed every
    ///   ~200 ms from the URLSession progress delegate. The UI renders this
    ///   in place of "…" so the number ticks up as bytes transfer.
    /// - `liveProgress` (0…1) is real transfer progress:
    ///   - download: bytes received / expected bytes
    ///   - upload: completed chunks / total chunks
    ///   The progress bar hitting 1.0 means the transfer actually finished,
    ///   not an estimated timer running out.
    case probing(
        phase: Direction,
        completedDownloadMbps: Double?,
        liveMbps: Double?,
        liveProgress: Double
    )

    case failed(reason: String, lastResult: ThroughputResult?)

    enum Direction: String, Sendable, Equatable {
        case download
        case upload
    }

    /// The most recent *completed* result, if any. During `.probing` this is
    /// intentionally nil so the UI doesn't surface stale numbers — each
    /// block fills in as its fresh reading arrives.
    var lastResult: ThroughputResult? {
        switch self {
        case .idle(let r), .failed(_, let r): r
        case .probing: nil
        }
    }

    var isRunning: Bool {
        if case .probing = self { return true }
        return false
    }
}
