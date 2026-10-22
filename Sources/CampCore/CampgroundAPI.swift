import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// RIDB-shaped responses from our bounded app backend. Provider keys stay on that backend.
/// This client does not represent reservation availability or replace the offline snapshot.
public struct CampgroundAPI: Sendable {
    public enum Failure: Error, Equatable {
        case invalidProxyURL, invalidQuery, invalidIdentifier, unexpectedResponse
        case httpStatus(Int)
    }
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let baseURL: URL
    private let transport: Transport

    public init(proxyBaseURL: URL, transport: @escaping Transport = CampgroundAPI.load) throws {
        guard proxyBaseURL.scheme == "https", let host = proxyBaseURL.host,
              !host.isEmpty, host != "ridb.recreation.gov",
              proxyBaseURL.user == nil, proxyBaseURL.password == nil,
              proxyBaseURL.query == nil, proxyBaseURL.fragment == nil else {
            throw Failure.invalidProxyURL
        }
        self.baseURL = proxyBaseURL
        self.transport = transport
    }

    public static func load(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.unexpectedResponse }
        return (data, response.statusCode)
    }

    /// Bounds match the published RIDB radius/page contract. Query is text, never URL syntax.
    public func facilitiesRequest(query: String, latitude: Double, longitude: Double,
                                  radiusMiles: Double = 25, offset: Int = 0) throws -> URLRequest {
        guard latitude.isFinite, (-90...90).contains(latitude), longitude.isFinite,
              (-180...180).contains(longitude), radiusMiles.isFinite,
              radiusMiles > 0, radiusMiles <= 25, offset >= 0, query.count <= 200 else {
            throw Failure.invalidQuery
        }
        return try request(path: ["facilities"], items: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "radius", value: String(radiusMiles)),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "full", value: "true")
        ])
    }

    public func sitesRequest(facilityID: String, offset: Int = 0) throws -> URLRequest {
        try Self.validateID(facilityID)
        guard offset >= 0 else { throw Failure.invalidQuery }
        return try request(path: ["facilities", facilityID, "campsites"], items: [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "offset", value: String(offset))
        ])
    }

    public func siteRequest(siteID: String) throws -> URLRequest {
        try Self.validateID(siteID)
        return try request(path: ["campsites", siteID], items: [])
    }

    public func facilities(query: String, latitude: Double, longitude: Double,
                           radiusMiles: Double = 25, offset: Int = 0) async throws -> CampgroundAPIPage<CampgroundAPIFacility> {
        try await fetch(facilitiesRequest(query: query, latitude: latitude, longitude: longitude,
                                         radiusMiles: radiusMiles, offset: offset))
    }

    public func sites(facilityID: String, offset: Int = 0) async throws -> CampgroundAPIPage<CampgroundAPISite> {
        try await fetch(sitesRequest(facilityID: facilityID, offset: offset))
    }

    public func site(siteID: String) async throws -> CampgroundAPISite {
        try await fetch(siteRequest(siteID: siteID))
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, status) = try await transport(request)
        guard (200...299).contains(status) else { throw Failure.httpStatus(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 80,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw Failure.invalidIdentifier
        }
    }

    private func request(path: [String], items: [URLQueryItem]) throws -> URLRequest {
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.invalidProxyURL
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw Failure.invalidProxyURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

public struct CampgroundAPIPage<Record: Decodable & Sendable>: Decodable, Sendable {
    public let records: [Record]
    public let metadata: Metadata?
    enum CodingKeys: String, CodingKey { case records = "RECDATA", metadata = "METADATA" }
    public struct Metadata: Decodable, Sendable {
        public let results: Results?
        enum CodingKeys: String, CodingKey { case results = "RESULTS" }
        public struct Results: Decodable, Sendable {
            public let totalCount: Int?
            enum CodingKeys: String, CodingKey { case totalCount = "TOTAL_COUNT" }
        }
    }
    /// Call serially until nil; a failed page must never be treated as a complete result.
    public func nextOffset(after offset: Int, limit: Int = 50) -> Int? {
        guard offset >= 0, limit > 0, !records.isEmpty, offset <= Int.max - records.count else { return nil }
        let next = offset + records.count
        if let total = metadata?.results?.totalCount { return next < total ? next : nil }
        return records.count == limit ? next : nil
    }
}

public struct CampgroundAPIFacility: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let type: String?
    public let latitude: Double?
    public let longitude: Double?
    public let reservationURL: String?
    public let updatedAt: String?
    public let enabled: Bool?
    enum CodingKeys: String, CodingKey {
        case id = "FacilityID", name = "FacilityName", type = "FacilityTypeDescription"
        case latitude = "FacilityLatitude", longitude = "FacilityLongitude"
        case reservationURL = "FacilityReservationURL", updatedAt = "LastUpdatedDate", enabled = "Enabled"
    }
}

/// Raw source values: normalization belongs in a reviewed import layer.
public struct CampgroundAPISite: Decodable, Sendable, Identifiable {
    public let id: String
    public let facilityID: String
    public let name: String
    public let kind: String?
    public let loop: String?
    public let typeOfUse: String?
    /// RIDB describes this as access by vehicle. It is not an ADA assertion.
    public let vehicleAccessible: Bool?
    public let latitude: Double?
    public let longitude: Double?
    public let attributes: [Attribute]?
    public let permittedEquipment: [Equipment]?
    public let updatedAt: String?
    public struct Attribute: Decodable, Sendable {
        public let name: String
        public let value: String
        enum CodingKeys: String, CodingKey { case name = "AttributeName", value = "AttributeValue" }
    }
    public struct Equipment: Decodable, Sendable {
        public let name: String
        public let maximumLength: Double?
        public var positiveMaximumLength: Double? {
            maximumLength.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        enum CodingKeys: String, CodingKey { case name = "EquipmentName", maximumLength = "MaxLength" }
    }
    enum CodingKeys: String, CodingKey {
        case id = "CampsiteID", facilityID = "FacilityID", name = "CampsiteName"
        case kind = "CampsiteType", loop = "Loop", typeOfUse = "TypeOfUse"
        case vehicleAccessible = "CampsiteAccessible", latitude = "CampsiteLatitude", longitude = "CampsiteLongitude"
        case attributes = "ATTRIBUTES", permittedEquipment = "PERMITTEDEQUIPMENT", updatedAt = "LastUpdatedDate"
    }
}
