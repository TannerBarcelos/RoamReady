import XCTest
import CampCore
@testable import Campgrounds

final class CampgroundAPITests: XCTestCase {
    func testProxyRequestsBoundQueryAndDoNotContainProviderKeys() throws {
        let api = try CampgroundAPI(proxyBaseURL: URL(string: "https://camp.example/api/ridb")!)
        let request = try api.facilitiesRequest(query: "Pines & Lake", latitude: 44, longitude: -118)
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/ridb/facilities")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "query" })?.value, "Pines & Lake")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "radius" })?.value, "25.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
        XCTAssertFalse(url.absoluteString.contains("apikey"))
        XCTAssertThrowsError(try api.facilitiesRequest(query: "", latitude: .nan, longitude: 1))
        XCTAssertThrowsError(try api.facilitiesRequest(query: "", latitude: 44, longitude: -118, radiusMiles: 26))
        XCTAssertThrowsError(try api.sitesRequest(facilityID: "../campsites?apikey=x"))
        XCTAssertThrowsError(try CampgroundAPI(proxyBaseURL: URL(string: "http://camp.example")!))
        XCTAssertThrowsError(try CampgroundAPI(proxyBaseURL: URL(string: "https://ridb.recreation.gov/api/v1")!))
    }

    func testSiteDecoderPreservesUnknownsConflictsAndEquipmentKinds() throws {
        let data = Data(#"{"RECDATA":[{"CampsiteID":"123","FacilityID":"456","CampsiteName":"A01","CampsiteType":"STANDARD NONELECTRIC","Loop":"A","TypeOfUse":"Overnight","CampsiteAccessible":true,"ATTRIBUTES":[{"AttributeName":"Water Hookup","AttributeValue":"Yes"},{"AttributeName":"Water Hookup","AttributeValue":"No"}],"PERMITTEDEQUIPMENT":[{"EquipmentName":"RV","MaxLength":35},{"EquipmentName":"TRAILER","MaxLength":0}]}],"METADATA":{"RESULTS":{"CURRENT_COUNT":1,"TOTAL_COUNT":2}}}"#.utf8)
        let page = try JSONDecoder().decode(CampgroundAPIPage<CampgroundAPISite>.self, from: data)
        let site = try XCTUnwrap(page.records.first)
        XCTAssertEqual(site.facilityID, "456")
        XCTAssertEqual(site.vehicleAccessible, true)
        XCTAssertNil(site.latitude)
        XCTAssertEqual(site.attributes?.count, 2, "Do not collapse conflicting source attributes")
        XCTAssertEqual(site.permittedEquipment?[0].positiveMaximumLength, 35)
        XCTAssertNil(site.permittedEquipment?[1].positiveMaximumLength, "Zero is unknown, not unlimited")
        XCTAssertEqual(page.nextOffset(after: 0), 1)
        XCTAssertNil(page.nextOffset(after: 1))
    }

    func testSingleSiteEndpointAndStatusFailure() async throws {
        let data = Data(#"{"CampsiteID":"123","FacilityID":"456","CampsiteName":"A01"}"#.utf8)
        let api = try CampgroundAPI(proxyBaseURL: URL(string: "https://camp.example/ridb")!) { request in
            guard request.url?.path == "/ridb/campsites/123" else { throw CampgroundAPI.Failure.invalidQuery }
            return (data, 200)
        }
        let site = try await api.site(siteID: "123")
        XCTAssertEqual(site.id, "123")
        XCTAssertNil(site.attributes)
        let unavailable = try CampgroundAPI(proxyBaseURL: URL(string: "https://camp.example")!) { _ in (Data(), 429) }
        do {
            _ = try await unavailable.sites(facilityID: "456")
            XCTFail("A rate limit must not become an empty successful result")
        } catch let error as CampgroundAPI.Failure {
            XCTAssertEqual(error, .httpStatus(429))
        }
    }
}
