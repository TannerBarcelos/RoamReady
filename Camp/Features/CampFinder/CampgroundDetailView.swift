import SwiftUI
import MapKit
import SwiftData
import CampCore
import Campgrounds
import CampPersistence

/// A Camp Finder place. Opened from a search result or a map tap (already looked up), or from a
/// saved campground's Apple Maps identifier, which is looked up again.
struct CampgroundDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(CampFinder.self) private var finder
    @State private var saveFailure: String?
    @Query private var saved: [SavedCampground]
    @Query(sort: \Trip.arrival, order: .reverse) private var trips: [Trip]
    private let identifier: String
    @State private var listing: CampgroundListing?
    @State private var failure: CampFinderError?
    @State private var planning = false
    /// Apple's street-level imagery near the campground; nil while loading or where Apple has none.
    @State private var lookAround: MKLookAroundScene?

    init(listing: CampgroundListing) {
        identifier = listing.mapItemIdentifier
        _listing = State(initialValue: listing)
    }
    init(identifier: String) { self.identifier = identifier }

    private var campgroundID: String { CampgroundIdentity.appleMaps(identifier).campgroundID }
    private var previousTrips: [Trip] { trips.filter { $0.campgroundID == campgroundID } }

    var body: some View {
        OnlineFeatureGate(feature: "Camp Finder", retry: { Task { await load() } }) {
            if let listing {
                content(listing)
            } else if let failure {
                List {
                    ContentUnavailableView {
                        Label("Place unavailable", systemImage: "exclamationmark.triangle")
                    } description: { Text(failure.message) } actions: {
                        if failure.canRetry { Button("Try again") { Task { await load() } } }
                    }
                    lists
                    memories
                }
            } else {
                ProgressView("Loading campground…")
            }
        }
        .navigationTitle(listing?.name ?? "Campground")
        .alert("Couldn’t update your campgrounds", isPresented: Binding(
            get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
            Button("OK") { saveFailure = nil }
        } message: { Text(saveFailure ?? "") }
        .task { if listing == nil { await load() } }
        .task(id: listing?.mapItemIdentifier) { if let listing { await loadLookAround(listing) } }
        .sheet(isPresented: $planning) { if let listing { NewTripView(initialListing: listing) } }
    }

    private func content(_ listing: CampgroundListing) -> some View {
        List {
            Section {
                mapPreview(listing)
                    .listRowInsets(EdgeInsets())
                VStack(alignment: .leading, spacing: 4) {
                    if let kind = listing.kind { Text(kind.title).font(.subheadline).foregroundStyle(.secondary) }
                    if let address = listing.address { Text(address).textSelection(.enabled) }
                }
                .padding(.vertical, 2)
                actions(listing)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
            }
            if let lookAround {
                Section {
                    LookAroundPreview(initialScene: lookAround, allowsNavigation: true, badgePosition: .bottomTrailing)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Look Around: street-level imagery near \(listing.name)")
                } header: { Text("Look Around") } footer: {
                    Text("Apple’s street-level imagery near the campground. Tap to look around full screen.")
                }
            }
            Section {
                Button("Add trip", systemImage: "calendar.badge.plus") { planning = true }
                    .accessibilityHint("Enter a booking you’ve already made at this campground")
                Button("Open in Apple Maps", systemImage: "map") { mapItem(for: listing).openInMaps() }
                    .accessibilityHint("Opens this campground in the Maps app")
            } footer: {
                Text("Book on the campground’s website or by phone, then come back and tap Add trip. RoamReady doesn’t book or show availability. Apple Maps shows photos, ratings, and hours when it has them for a place.")
            }
            lists
            memories
            Section {
                Text("Place details from Apple Maps. Hookups, site sizes, prices, and availability aren’t listed here; check with the campground.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lists: some View {
        Section {
            ForEach(CampgroundList.allCases) { list in
                Toggle(isOn: Binding(get: { CampgroundLists(saved: saved, trips: trips).contains(campgroundID, on: list) },
                                     set: { included in
                                         do {
                                             try SavedCampground.set(campgroundID, name: "", region: "", on: list, included, in: context)
                                             library.save()
                                         } catch { saveFailure = error.localizedDescription }
                                     })) {
                    Label(list.title, systemImage: list.symbol)
                }
            }
        } header: { Text("Your lists") } footer: {
            Text("Campgrounds from your completed trips are added to Have been automatically. Turn it off to remove one.")
        }
    }

    @ViewBuilder private var memories: some View {
        if !previousTrips.isEmpty {
            Section("Your trips here") {
                ForEach(previousTrips) { trip in
                    NavigationLink { MemoriesView(trip: trip) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trip.siteNumber.isEmpty ? "Your visit" : "Site \(trip.siteNumber)")
                            Text(trip.dateSummary).font(.caption).foregroundStyle(.secondary)
                            if trip.rating != .unrated { Text(trip.rating.title).font(.caption) }
                            if !trip.notes.isEmpty { Text(trip.notes).font(.subheadline).lineLimit(3).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        do { listing = try await finder.listing(identifier: identifier); failure = nil }
        catch is CancellationError {}
        catch { failure = error as? CampFinderError ?? .failed }
    }

    /// A still map of where the campground is; Directions and Open in Apple Maps are the ways to explore further.
    private func mapPreview(_ listing: CampgroundListing) -> some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: listing.coordinate, latitudinalMeters: 2_500, longitudinalMeters: 2_500)),
            interactionModes: []) {
            Marker(listing.name, systemImage: listing.kind == .rvPark ? "car.side" : "tent", coordinate: listing.coordinate)
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .frame(height: 180)
        .accessibilityLabel("Map showing where \(listing.name) is")
    }

    /// Call, Website, and Directions side by side, each shown only when Apple Maps has what it needs.
    private func actions(_ listing: CampgroundListing) -> some View {
        HStack(spacing: 8) {
            if let url = listing.phoneLink, let phone = listing.phone {
                Link(destination: url) { ActionLabel(title: "Call", systemImage: "phone.fill") }
                    .accessibilityLabel("Call campground, \(phone)")
            }
            if let url = listing.websiteLink {
                Link(destination: url) { ActionLabel(title: "Website", systemImage: "safari.fill") }
                    .accessibilityHint("Opens the campground’s website, where you can book")
            }
            Button { openDirections(listing) } label: { ActionLabel(title: "Directions", systemImage: "car.fill") }
                .accessibilityHint("Opens Apple Maps with driving directions")
        }
        .buttonStyle(.bordered)
    }

    private func loadLookAround(_ listing: CampgroundListing) async {
        let request = finder.mapItem(for: listing).map { MKLookAroundSceneRequest(mapItem: $0) }
            ?? MKLookAroundSceneRequest(coordinate: listing.coordinate)
        lookAround = try? await request.scene
    }

    private func mapItem(for listing: CampgroundListing) -> MKMapItem {
        finder.mapItem(for: listing) ?? {
            let item = MKMapItem(location: CLLocation(latitude: listing.latitude, longitude: listing.longitude), address: nil)
            item.name = listing.name
            return item
        }()
    }

    private func openDirections(_ listing: CampgroundListing) {
        mapItem(for: listing).openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

/// An action button's label: icon above title, filling its share of the row.
private struct ActionLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title3)
            Text(title).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// Chooses a Camp Finder place for a trip.
struct CampgroundPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CampFinder.self) private var finder
    let onSelect: (CampgroundListing) -> Void
    @State private var search = CampFinderSearch()
    @State private var location = LocationProvider()
    @State private var query = ""

    var body: some View {
        OnlineFeatureGate(feature: "Camp Finder", retry: { search.retry(using: finder) }) {
            List {
                Section {
                    Button("Search near me", systemImage: "location.fill") {
                        Task {
                            guard let here = await location.currentLocation() else { return }
                            search.run(.area(MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 40_000,
                                                                longitudinalMeters: 40_000)), using: finder)
                        }
                    }
                    if location.isDenied { Text("Location access is off. Search by name or place instead.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(search.results) { listing in
                        Button { onSelect(listing) } label: { CampgroundRow(listing: listing) }.tint(.primary)
                    }
                    switch search.phase {
                    case .loading: ProgressView()
                    case .failed(let failure):
                        Text(failure.message).foregroundStyle(.secondary)
                        if failure.canRetry { Button("Try again") { search.retry(using: finder) } }
                    case .loaded where search.results.isEmpty:
                        Text("No campgrounds found there. You can still enter the campground by name.").foregroundStyle(.secondary)
                    default: EmptyView()
                    }
                } footer: { Text("Places from Apple Maps.") }
            }
        }
        .navigationTitle("Choose campground").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Campground, city, park, or ZIP code")
        .onSubmit(of: .search) {
            guard cleanedSearchText(query) != nil else { return }
            search.run(.text(query, near: nil), using: finder)
        }
        .onDisappear { search.cancel() }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
