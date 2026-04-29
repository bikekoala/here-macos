import CoreLocation
import Foundation

/// The app's **internal** model for an IP lookup.
///
/// This is *not* the wire format of any provider. Each `IPProvider`
/// implementation owns its own private `Decodable` raw-response shape and
/// a `map(_:) -> IPDataModel` adapter. That keeps swapping providers a
/// matter of writing a new mapper, not touching the UI / persistence /
/// history layers.
///
/// Some sub-fields are `Optional` because the providers we support don't
/// all supply them:
///
/// - `network.cidr`, `network.autonomousSystem.{country, rir}` —
///   ip.guide carries them, ipwho.is doesn't.
/// - `location.city` — null for city-state egresses (HK, SG, MO, …)
///   regardless of provider.
///
/// The previously-computed `countryAlpha2` is now a **stored** field,
/// populated directly by each provider's mapper. That eliminates a
/// fragile English-name → ISO-alpha-2 round-trip that would silently
/// fail when a provider's spelling didn't match Apple's `Locale` tables
/// (e.g. ipwho.is ships "Republic of Korea"; Apple has "South Korea").
struct IPDataModel: Codable, Equatable, Sendable {
    let ip: String
    /// Uppercase ISO-3166-1 alpha-2. Authoritative for flag / region
    /// display. Provider-specific mapping logic lives in each provider,
    /// not here — this field just caches the answer.
    let countryAlpha2: String
    let network: Network
    let location: Location

    struct Network: Codable, Equatable, Sendable {
        /// Network CIDR (e.g. "45.82.246.0/24"). Optional: ipwho.is
        /// doesn't expose it; ip.guide-class providers do.
        let cidr: String?
        let autonomousSystem: AutonomousSystem

        enum CodingKeys: String, CodingKey {
            case cidr
            case autonomousSystem = "autonomous_system"
        }

        struct AutonomousSystem: Codable, Equatable, Sendable {
            let asn: Int
            let name: String
            let organization: String
            /// ISO-alpha-2 of the ASN's registered country. **Not the
            /// egress country** — for VPN traffic that routinely
            /// disagrees with `IPDataModel.countryAlpha2`. Optional
            /// because some providers (ipwho.is) don't surface it.
            let country: String?
            /// Regional Internet Registry (e.g. "RIPE NCC"). Optional
            /// for the same reason as `country`.
            let rir: String?
        }
    }

    struct Location: Codable, Equatable, Sendable {
        // City can come back as JSON `null` for city-state egresses
        // (e.g. Hong Kong, Singapore, Macao). Keep it Optional —
        // a non-Optional declaration would make every HK / SG egress
        // fail to decode, which surfaces in the UI as "Got an
        // unexpected response from <provider>".
        let city: String?
        let country: String
        let timezone: String
        let latitude: Double
        let longitude: Double
    }
}

extension IPDataModel {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    /// "AS<asn> · <short-name>". The short-name is the leading
    /// segment of `name` when the provider gives a "<HANDLE> -
    /// <legal-name>" style string (ip.guide does this for some ASNs);
    /// providers that just give the legal name verbatim (ipwho.is)
    /// pass through unchanged.
    var asnLabel: String {
        "AS\(network.autonomousSystem.asn) · \(network.autonomousSystem.name.components(separatedBy: " - ").first ?? network.autonomousSystem.name)"
    }
}
