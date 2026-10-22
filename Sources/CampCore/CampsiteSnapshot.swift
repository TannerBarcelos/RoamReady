import Foundation

/// Factual site details from an official RIDB export, not live inventory or availability.
public struct CampsiteSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let loop: String
    public let vehicleAccessible: Bool?
    public let latitude: Double?
    public let longitude: Double?
    public let attributes: [String: String]
    /// Keys are RigType raw values. Zero means the source does not publish a positive length limit.
    public let equipment: [String: Double]
    public let updatedAt: String
    public func maximumLengthFeet(for type: RigType) -> Double? {
        equipment[type.rawValue].flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}

public struct CampsiteShard: Decodable, Sendable {
    public let schemaVersion: Int
    public let sitesByFacility: [String: [CampsiteSnapshot]]
    public static func number(for facilityID: String) -> Int { facilityID.utf8.reduce(0) { ($0 + Int($1)) % 64 } }
    public static func decode(_ data: Data) throws -> CampsiteShard {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1 else { throw CampError.unsupportedSchema(result.schemaVersion) }
        return result
    }
}
