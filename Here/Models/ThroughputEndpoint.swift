import Foundation

/// Selectable download source for the Throughput speed test.
///
/// Each preset is a **complete** download URL — the test just issues a GET
/// and times how fast the response body arrives. No upload probe (upload
/// measurement needs an API-shaped endpoint and doesn't fit the "grab a
/// static file from the nearest CDN" model).
///
/// - `cachefly`: 100 MB test file on Cachefly's CDN. Long-lived global
///   endpoint with wide edge presence; typically hits the nearest POP.
///   Default because it doesn't share the `speed.cloudflare.com` host
///   that some networks SNI-filter.
/// - `cloudflare`: Cloudflare's speed test endpoint with a 100 MB
///   `?bytes=` request.
/// - `custom`: user-provided URL. Any HTTPS resource that serves ≥ 10 MB
///   or so of body works.
enum ThroughputEndpoint: String, CaseIterable, Identifiable, Sendable, Codable {
    case cachefly
    case cloudflare
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cachefly:   String(localized: "Cachefly (100 MB)")
        case .cloudflare: String(localized: "Cloudflare (100 MB)")
        case .custom:     String(localized: "Custom URL")
        }
    }

    /// Complete URL ready to GET. `nil` for `.custom` — the actual URL
    /// lives in `SettingsStore.throughputCustomURL`.
    var presetURL: URL? {
        switch self {
        case .cachefly:
            return URL(string: "https://cachefly.cachefly.net/100mb.test")
        case .cloudflare:
            return URL(string: "https://speed.cloudflare.com/__down?bytes=104857600")
        case .custom:
            return nil
        }
    }

    /// Resolve to a concrete `URL`. For `.custom` the supplied string
    /// must be a valid `http://` or `https://` URL — otherwise returns
    /// `nil`, and the Run Test handler surfaces that as a failure
    /// rather than running against a fallback.
    func resolveURL(customURL: String) -> URL? {
        if let preset = presetURL { return preset }
        return URL.fromUserCustomEndpoint(customURL)
    }
}

extension URL {
    /// Parse a user-entered string into a probe / download URL.
    /// Accepts `http://` or `https://` with a DNS-shaped host —
    /// letters, digits, dots and hyphens. `URL(string:)` itself is
    /// permissive enough that `http://*` parses to a URL with host
    /// `*`; the host regex below rejects those wildcard / exotic
    /// forms. Shared by both the latency and throughput Custom URL
    /// fields so validity is judged the same way everywhere.
    static func fromUserCustomEndpoint(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false),
              host.range(
                  of: #"^([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+$"#,
                  options: .regularExpression
              ) != nil
        else { return nil }
        return url
    }
}
