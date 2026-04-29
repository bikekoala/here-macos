import Foundation

/// One way to look up the current egress IP and its geolocation.
///
/// Each conforming provider:
/// 1. Owns a private `Decodable` shape that mirrors its upstream JSON
///    contract (so a provider's wire format never leaks past its own
///    file).
/// 2. Maps that raw decode into `IPDataModel`, which is the app's
///    internal, provider-neutral type. The mapper is where
///    name → alpha-2 normalisation, empty-string-to-nil, and any
///    field-availability fallbacks live.
///
/// To add a third provider: write the raw struct, write the mapper,
/// implement `fetch()`, register it in `AppEnvironment`. UI / cache /
/// history don't need to change.
protocol IPProvider: Sendable {
    var name: String { get }
    func fetch() async throws -> IPDataModel
}
