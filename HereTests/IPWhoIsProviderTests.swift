import Foundation
import Testing

@testable import Here

private final class TestBundleAnchor {}

/// `.serialized` because the URLProtocolMock-backed integration
/// tests below share the global `URLProtocolMock.handler` state
/// — running them concurrently makes one test's mock answer the
/// other's request and inflates `requestCount`. The pure mapping
/// tests that don't touch URLProtocolMock are also forced
/// serial here, but at <1 ms each that's invisible.
@Suite("IPWhoIsProvider", .serialized)
struct IPWhoIsProviderTests {

    /// Decode a fixture file from the test bundle. Mirrors the bundle
    /// lookup used elsewhere in the suite.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: TestBundleAnchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Fixture \(name).json not found in test bundle"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Mapping

    /// Real ipwho.is response for the Korean VPN IP (`45.82.246.98`)
    /// that motivated the migration from ip.guide. Validates the full
    /// happy path: every field gets mapped, country code is taken
    /// straight from `country_code` (no name-mapper round-trip),
    /// CIDR / ASN-country / RIR end up `nil` (ipwho.is omits them).
    @Test func mapsKoreanResponseEndToEnd() throws {
        let data = try loadFixture("ipwhois_kr_response")
        let raw = try JSONDecoder().decode(IPWhoIsRawResponse.self, from: data)
        let model = IPWhoIsProvider.map(raw)

        #expect(model.ip == "45.82.246.98")
        #expect(model.countryAlpha2 == "KR")
        #expect(model.location.country == "Republic of Korea")
        #expect(model.location.city == "Seoul")
        #expect(model.location.timezone == "Asia/Seoul")
        #expect(abs(model.location.latitude - 37.566535) < 0.0001)
        #expect(abs(model.location.longitude - 126.9779692) < 0.0001)

        #expect(model.network.cidr == nil)
        #expect(model.network.autonomousSystem.asn == 209847)
        #expect(model.network.autonomousSystem.organization == "Worktitans B.V.")
        #expect(model.network.autonomousSystem.country == nil)
        #expect(model.network.autonomousSystem.rir == nil)

        // No " - " separator → asnLabel passes the org through.
        #expect(model.asnLabel == "AS209847 · Worktitans B.V.")
    }

    /// City-state regression: ipwho.is sometimes returns `""` for HK
    /// / SG / MO instead of `null`. The provider must normalise both
    /// to `nil` so consumers only deal with one "missing" form.
    @Test func normalizesEmptyCityToNil() throws {
        let data = try loadFixture("ipwhois_hk_response")
        let raw = try JSONDecoder().decode(IPWhoIsRawResponse.self, from: data)
        let model = IPWhoIsProvider.map(raw)

        #expect(model.countryAlpha2 == "HK")
        #expect(model.location.city == nil)
        #expect(model.location.country == "Hong Kong")
    }

    // MARK: - Failure handling

    // MARK: - End-to-end via URLProtocolMock

    /// Build a provider whose `fetch()` round-trips through the
    /// in-process `URLProtocolMock` rather than the real network.
    /// Each test resets the mock's handler to drive a specific
    /// response shape.
    private func mockedProvider() -> IPWhoIsProvider {
        IPWhoIsProvider(
            endpoint: URL(string: "https://mock.ipwho.is/")!,
            sessionFactory: { URLProtocolMock.session() }
        )
    }

    private func httpResponse(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://mock.ipwho.is/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Happy path: 200 + valid JSON → fetch returns a populated
    /// IPDataModel. Confirms the decode + map pipeline runs end-to-
    /// end through the URLSession stack, not just the in-memory
    /// `map(_:)` path covered above.
    @Test func fetchSucceedsOnValidResponse() async throws {
        let data = try loadFixture("ipwhois_kr_response")
        URLProtocolMock.reset { _ in (self.httpResponse(200), data) }
        defer { URLProtocolMock.reset() }

        let model = try await mockedProvider().fetch()
        #expect(model.ip == "45.82.246.98")
        #expect(model.countryAlpha2 == "KR")
        #expect(URLProtocolMock.requestCount == 1)
    }

    /// `{"success": false, "message": "..."}` at HTTP 200 → the
    /// provider's guard fires and throws `.transport(message:)`
    /// carrying the upstream message verbatim. The popover banner
    /// renders that message to the user.
    @Test func fetchTranslatesSuccessFalseIntoTransportError() async throws {
        let data = try loadFixture("ipwhois_failure_response")
        URLProtocolMock.reset { _ in (self.httpResponse(200), data) }
        defer { URLProtocolMock.reset() }

        do {
            _ = try await mockedProvider().fetch()
            Issue.record("Expected fetch to throw on success:false")
        } catch let error as IPServiceError {
            if case .transport(let msg) = error {
                #expect(msg == "Invalid IP address")
            } else {
                Issue.record("Expected .transport, got \(error)")
            }
        }
    }

    /// HTTP non-2xx → IPServiceError.http(statusCode:). Exercised
    /// here against a 503 to confirm the status code passes through
    /// unmangled.
    @Test func fetchSurfacesHTTPErrorStatus() async throws {
        URLProtocolMock.reset { _ in (self.httpResponse(503), Data()) }
        defer { URLProtocolMock.reset() }

        do {
            _ = try await mockedProvider().fetch()
            Issue.record("Expected fetch to throw on 503")
        } catch let error as IPServiceError {
            if case .http(let code) = error {
                #expect(code == 503)
            } else {
                Issue.record("Expected .http(503), got \(error)")
            }
        }
    }

    /// Underlying URLError (e.g. dropped connection, TLS failure)
    /// gets translated into IPServiceError. Default case for
    /// unmapped URLErrors is `.transport(message:)` carrying the
    /// localized description.
    @Test func fetchSurfacesURLErrorAsTransportFailure() async throws {
        URLProtocolMock.reset { _ in
            throw URLError(.secureConnectionFailed)
        }
        defer { URLProtocolMock.reset() }

        do {
            _ = try await mockedProvider().fetch()
            Issue.record("Expected fetch to throw on URLError")
        } catch let error as IPServiceError {
            if case .transport = error {
                // OK — message content is system-localized, don't
                // assert on it.
            } else {
                Issue.record("Expected .transport for URLError, got \(error)")
            }
        }
    }

    /// Garbage body → IPServiceError.decoding. Important because
    /// we want the popover error banner to say "Got an unexpected
    /// response" rather than crash, even when the upstream returns
    /// HTML / wrong JSON shape / partial bytes.
    @Test func fetchSurfacesDecodingFailure() async throws {
        URLProtocolMock.reset { _ in
            (self.httpResponse(200), Data("<!DOCTYPE html>not json".utf8))
        }
        defer { URLProtocolMock.reset() }

        do {
            _ = try await mockedProvider().fetch()
            Issue.record("Expected fetch to throw on garbage body")
        } catch let error as IPServiceError {
            if case .decoding = error {
                // OK
            } else {
                Issue.record("Expected .decoding for non-JSON, got \(error)")
            }
        }
    }
}
