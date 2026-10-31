import Foundation
import Observation
import MapKit
import Campgrounds

/// Initial nearby discovery and explicit searches share a session. Typing alone never starts a request,
/// and a new search cancels the one in flight.
@MainActor @Observable
final class CampFinderSearch {
    enum Request {
        case nearby(CLLocationCoordinate2D)
        case area(MKCoordinateRegion)
        case text(String, near: MKCoordinateRegion?)
    }
    enum Phase: Equatable { case idle, loading, loaded, failed(CampFinderError) }

    private(set) var phase = Phase.idle
    private(set) var results: [CampgroundListing] = []
    private(set) var current: Request?
    private(set) var wasInterrupted = false
    /// Where the results are: the searched area's center, or the place the text named.
    private(set) var center: CLLocationCoordinate2D?
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(_ request: Request, using finder: CampFinder) {
        task?.cancel()
        current = request
        wasInterrupted = false
        phase = .loading
        task = Task {
            do {
                let found: [CampgroundListing], center: CLLocationCoordinate2D?
                switch request {
                case .nearby(let coordinate):
                    let listings = try await finder.campgrounds(in: CampFinder.nearbyRegion(around: coordinate))
                    found = NearbyCampgrounds.results(listings, latitude: coordinate.latitude, longitude: coordinate.longitude)
                    center = coordinate
                case .area(let region):
                    found = try await finder.campgrounds(in: region)
                        .merged(with: [], nearLatitude: region.center.latitude, longitude: region.center.longitude)
                    center = region.center
                case .text(let text, let region):
                    (found, center) = try await finder.search(text, near: region)
                }
                guard !Task.isCancelled else { return }
                results = found; self.center = center; phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                phase = .failed(error as? CampFinderError ?? CampFinderError(error))
            }
        }
    }

    func retry(using finder: CampFinder) {
        if let current { run(current, using: finder) }
    }

    func cancel() {
        task?.cancel()
        if phase == .loading { wasInterrupted = true; phase = results.isEmpty ? .idle : .loaded }
    }
}
