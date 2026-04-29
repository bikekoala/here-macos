import Foundation

/// Shared `User-Agent` string for every outbound HTTP request the app
/// makes — IP lookup, latency probes, throughput downloads. Centralising
/// keeps formatting consistent and makes "swap our identifier" a
/// one-line change.
enum AppUserAgent {
    static var value: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return "Here/\(version) (macOS)"
    }
}
