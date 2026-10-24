import Foundation
import Observation
import CoreLocation
import MapKit
// MapFeature (a place tapped on the map) is MapKit's SwiftUI type.
import SwiftUI
import CampCore
import Campgrounds

/// Why a Camp Finder search or lookup didn't finish, in terms the app can explain.
enum CampFinderError: Error, Equatable {
    case offline, throttled, notFound, failed

    var message: String {
        switch self {
        case .offline: "Camp Finder needs an internet connection."
        case .throttled: "Apple Maps is limiting searches from this iPhone for a moment. Try again shortly."
        case .notFound: "Apple Maps no longer lists this place. Your trips and lists are unchanged."
        case .failed: "Apple Maps couldn’t finish the search. Try again."
        }
    }
    var canRetry: Bool { self != .notFound }

    init(_ error: any Error) {
        if let error = error as? MKError {
            switch error.code {
            case .loadingThrottled: self = .throttled
            case .placemarkNotFound: self = .notFound
            default: self = (error.userInfo[NSUnderlyingErrorKey] as? URLError).map { _ in .offline } ?? .failed
            }
        } else if error is URLError {
            self = .offline
        } else {
            self = .failed
        }
    }
}

/// Camp Finder's Apple Maps searches and lookups. Apple Maps is free to use from the app, needs no
/// server or key, and throttles each device on its own, so there is no quota to manage. Places are
/// kept in memory for the session only; the library stores just Apple's identifiers.
@MainActor @Observable
final class CampFinder {
    static let categories: [MKPointOfInterestCategory] = [.campground, .rvPark]
    static var filter: MKPointOfInterestFilter { MKPointOfInterestFilter(including: categories) }
    @ObservationIgnored private var items: [String: MKMapItem] = [:]
    private(set) var listings: [String: CampgroundListing] = [:]

    /// Campgrounds and RV parks in a map region, with no search text. Apple's points-of-interest request
    /// alone lists only a few (none around Hollister, CA; 2 in Yosemite Valley), so category searches kept
    /// inside the region fill in the rest.
    func campgrounds(in region: MKCoordinateRegion) async throws -> [CampgroundListing] {
        let pointsOfInterest = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        pointsOfInterest.pointOfInterestFilter = Self.filter
        var searches = [MKLocalSearch(request: pointsOfInterest)]
        for category in ["campground", "RV park"] {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = category
            request.resultTypes = .pointOfInterest
            request.pointOfInterestFilter = Self.filter
            request.region = region
            request.regionPriority = .required
            searches.append(MKLocalSearch(request: request))
        }
        var found: [CampgroundListing] = []
        var failure: (any Error)?
        var anySucceeded = false
        for search in searches {
            switch await optional({ try await self.run(search) }) {
            case .success(let listings): found += listings; anySucceeded = true
            case .failure(let error): failure = failure ?? error
            }
        }
        // Any search finishing is a result; only all of them failing is an error.
        if !anySucceeded, let failure { throw failure }
        return found.merged(with: [], nearLatitude: region.center.latitude, longitude: region.center.longitude)
    }

    /// Typed text: campgrounds whose name matches, plus campgrounds around the place it names
    /// ("Moab, UT", a ZIP code, a park). Returns the results and where to center the map.
    func search(_ text: String, near region: MKCoordinateRegion?) async throws -> (listings: [CampgroundListing], center: CLLocationCoordinate2D?) {
        guard let text = cleanedSearchText(text) else { return ([], nil) }
        let byName = MKLocalSearch.Request()
        byName.naturalLanguageQuery = text
        byName.resultTypes = .pointOfInterest
        byName.pointOfInterestFilter = Self.filter
        if let region { byName.region = region }
        let namedResult = await optional { try await self.run(MKLocalSearch(request: byName)) }

        let address = MKLocalSearch.Request()
        address.naturalLanguageQuery = text
        address.resultTypes = .address
        if let region { address.region = region }
        let place = try? await MKLocalSearch(request: address).start().mapItems.first?.location.coordinate

        var nearby: [CampgroundListing]?
        if let place {
            let area = MKCoordinateRegion(center: place, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
            nearby = try? await campgrounds(in: area)
        }
        let named = try? namedResult.get()
        // Either half finding something is a result; nothing succeeding is an error.
        if named == nil, nearby == nil, case .failure(let error) = namedResult { throw CampFinderError(error) }
        let found = named ?? []
        let center = place ?? found.first?.coordinate
        let origin = center ?? region?.center ?? CLLocationCoordinate2D()
        return (found.merged(with: nearby ?? [], nearLatitude: origin.latitude, longitude: origin.longitude), center)
    }

    /// A saved or tapped place, looked up by Apple's identifier.
    func listing(identifier: String) async throws -> CampgroundListing {
        if let listing = listings[identifier] { return listing }
        guard let id = MKMapItem.Identifier(rawValue: identifier) else { throw CampFinderError.notFound }
        return try await lookUp(MKMapItemRequest(mapItemIdentifier: id))
    }

    /// A campground tapped on the map itself.
    func listing(for feature: MapFeature) async throws -> CampgroundListing {
        try await lookUp(MKMapItemRequest(feature: feature))
    }

    private func lookUp(_ request: MKMapItemRequest) async throws -> CampgroundListing {
        let item: MKMapItem
        do { item = try await request.mapItem } catch { throw CampFinderError(error) }
        guard let listing = remember(item) else { throw CampFinderError.notFound }
        return listing
    }

    /// The Apple Maps item behind a listing, for Apple's place card, Directions, and Open in Maps.
    func mapItem(for listing: CampgroundListing) -> MKMapItem? { items[listing.mapItemIdentifier] }

    /// A listing already looked up this session, without a network request.
    func cachedListing(for campgroundID: String) -> CampgroundListing? {
        guard case .appleMaps(let identifier) = CampgroundIdentity(campgroundID) else { return nil }
        return listings[identifier]
    }

    private func run(_ search: MKLocalSearch) async throws -> [CampgroundListing] {
        do { return try await search.start().mapItems.compactMap(remember) }
        // Apple Maps reports a search with no matches as "placemark not found": that's no results, not a missing place.
        catch let error as MKError where error.code == .placemarkNotFound { return [] }
        catch { throw CampFinderError(error) }
    }

    private func optional<Value>(_ body: () async throws -> Value) async -> Result<Value, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Nil for an item without an identifier, which couldn't be saved or found again.
    private func remember(_ item: MKMapItem) -> CampgroundListing? {
        guard let identifier = item.identifier?.rawValue, let name = item.name, !name.isEmpty else { return nil }
        let coordinate = item.location.coordinate
        let kind: CampgroundKind? = switch item.pointOfInterestCategory {
        case .campground?: .campground
        case .rvPark?: .rvPark
        default: nil
        }
        let listing = CampgroundListing(mapItemIdentifier: identifier, name: name, kind: kind, phone: item.phoneNumber,
                                        websiteURL: item.url?.absoluteString, address: item.address?.shortAddress ?? item.address?.fullAddress,
                                        latitude: coordinate.latitude, longitude: coordinate.longitude,
                                        timeZoneIdentifier: item.timeZone?.identifier)
        items[identifier] = item
        listings[identifier] = listing
        return listing
    }
}

extension CampgroundListing {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The device location for "Near me". Asking is optional: typing a place always works.
@MainActor @Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// One location fix, asking permission first if needed. Nil when denied or unavailable.
    func currentLocation() async -> CLLocation? {
        if isDenied { return nil }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            if authorization == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
        }
    }

    private func finish(_ location: CLLocation?) {
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorization = status
            guard !waiting.isEmpty else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: finish(nil)
            default: break
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in finish(location) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in finish(nil) }
    }
}
