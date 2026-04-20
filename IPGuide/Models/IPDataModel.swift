import CoreLocation
import Foundation

struct IPDataModel: Codable, Equatable, Sendable {
    let ip: String
    let network: Network
    let location: Location

    struct Network: Codable, Equatable, Sendable {
        let cidr: String
        let hosts: Hosts
        let autonomousSystem: AutonomousSystem

        enum CodingKeys: String, CodingKey {
            case cidr
            case hosts
            case autonomousSystem = "autonomous_system"
        }

        struct Hosts: Codable, Equatable, Sendable {
            let start: String
            let end: String
        }

        struct AutonomousSystem: Codable, Equatable, Sendable {
            let asn: Int
            let name: String
            let organization: String
            let country: String
            let rir: String
        }
    }

    struct Location: Codable, Equatable, Sendable {
        let city: String
        let country: String
        let timezone: String
        let latitude: Double
        let longitude: Double
    }
}

extension IPDataModel {
    var countryAlpha2: String {
        network.autonomousSystem.country.uppercased()
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    var asnLabel: String {
        "AS\(network.autonomousSystem.asn) · \(network.autonomousSystem.name.components(separatedBy: " - ").first ?? network.autonomousSystem.name)"
    }
}
