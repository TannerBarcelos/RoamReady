import Foundation
import Observation
import MapKit
import Campgrounds

/// One Camp Finder search session. A search runs when the person submits or taps a button, never
/// on each keystroke, and a new search cancels the one in flight.
@MainActor @Observable
final class CampFinderSearch {
    enum Request {
        case area(MKCoordinateRegion)
        case text(String, near: MKCoordinateRegion?)
    }
    enum Phase: Equatable { case idle, loading, loaded, failed(CampFinderError) }

    private(set) var phase = Phase.idle
    private(set) var results: [CampgroundListing] = []
    private(set) var current: Request?
    /// Where the results are: the searched area's center, or the place the text named.
    private(set) var center: CLLocationCoordinate2D?
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(_ request: Request, using finder: CampFinder) {
        task?.cancel()
        current = request
        phase = .loading
        task = Task {
            do {
                let found: [CampgroundListing], center: CLLocationCoordinate2D?
                switch request {
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
        if phase == .loading { phase = results.isEmpty ? .idle : .loaded }
    }
}
