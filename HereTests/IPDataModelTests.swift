import Foundation
import Testing

@testable import Here

@Suite("IPDataModel")
struct IPDataModelTests {

    private func sample(asnName: String = "MISAKA - Misaka Network, Inc.") -> IPDataModel {
        IPDataModel(
            ip: "38.175.104.131",
            countryAlpha2: "US",
            network: .init(
                cidr: "38.175.104.0/24",
                autonomousSystem: .init(
                    asn: 917, name: asnName, organization: "Misaka Network, Inc.",
                    country: "US", rir: "ARIN"
                )
            ),
            location: .init(
                city: "San Jose", country: "United States",
                timezone: "America/Los_Angeles",
                latitude: 37.2379, longitude: -121.7946
            )
        )
    }

    @Test func coordinateMatches() {
        let model = sample()
        #expect(abs(model.coordinate.latitude - 37.2379) < 0.0001)
        #expect(abs(model.coordinate.longitude - (-121.7946)) < 0.0001)
    }

    /// `asnLabel` strips the `<HANDLE> - <legal-name>` style by taking
    /// only the leading segment. Matches what ip.guide-class providers
    /// shipped historically.
    @Test func asnLabelStripsHandleSuffix() {
        #expect(sample().asnLabel == "AS917 · MISAKA")
    }

    /// When the upstream just hands us a single legal name (no " - "
    /// separator) — which is what ipwho.is does — `asnLabel` lets the
    /// whole string through unchanged.
    @Test func asnLabelPassesThroughWithoutSeparator() {
        let model = sample(asnName: "Worktitans B.V.")
        #expect(model.asnLabel == "AS917 · Worktitans B.V.")
    }

    @Test func optionalFieldsRoundTripThroughCodable() throws {
        // Cache uses Codable to round-trip the model. Ensure
        // optional cidr / asn-country / rir survive a round-trip
        // when present, and stay nil when absent.
        let withFields = sample()
        let encoded = try JSONEncoder().encode(withFields)
        let decoded = try JSONDecoder().decode(IPDataModel.self, from: encoded)
        #expect(decoded == withFields)

        let withoutFields = IPDataModel(
            ip: "1.1.1.1",
            countryAlpha2: "AU",
            network: .init(
                cidr: nil,
                autonomousSystem: .init(
                    asn: 13335, name: "CLOUDFLARENET",
                    organization: "Cloudflare", country: nil, rir: nil
                )
            ),
            location: .init(
                city: nil, country: "Australia",
                timezone: "Australia/Sydney",
                latitude: -33.494, longitude: 143.211
            )
        )
        let encoded2 = try JSONEncoder().encode(withoutFields)
        let decoded2 = try JSONDecoder().decode(IPDataModel.self, from: encoded2)
        #expect(decoded2 == withoutFields)
    }
}
