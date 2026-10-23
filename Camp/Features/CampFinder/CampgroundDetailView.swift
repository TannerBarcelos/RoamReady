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
    @Query private var saved: [SavedCampground]
    @Query(sort: \Trip.arrival, order: .reverse) private var trips: [Trip]
    private let identifier: String
    @State private var listing: CampgroundListing?
    @State private var failure: CampFinderError?
    @State private var planning = false
    @State private var placeCard: MKMapItem?

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
        .task { if listing == nil { await load() } }
        .sheet(isPresented: $planning) { if let listing { NewTripView(initialListing: listing) } }
        .mapItemDetailSheet(item: $placeCard)
    }

    private func content(_ listing: CampgroundListing) -> some View {
        List {
            Section {
                if let kind = listing.kind { Text(kind.title).foregroundStyle(.secondary) }
                if let address = listing.address { Text(address) }
            }
            Section {
                if let url = listing.websiteLink {
                    Link(destination: url) { Label("Website", systemImage: "globe") }
                        .accessibilityHint("Opens the campground’s website, where you can book")
                }
                if let url = listing.phoneLink, let phone = listing.phone {
                    Link(destination: url) { Label("Call \(phone)", systemImage: "phone") }
                        .accessibilityLabel("Call campground, \(phone)")
                }
                Button("Directions", systemImage: "car") { openDirections(listing) }
                    .accessibilityHint("Opens Apple Maps with driving directions")
                if let item = finder.mapItem(for: listing) {
                    Button("Photos, ratings & hours", systemImage: "info.circle") { placeCard = item }
                        .accessibilityHint("Shows Apple Maps’ place card for this campground")
                }
                Button("Add trip", systemImage: "calendar.badge.plus") { planning = true }
                    .accessibilityHint("Enter a booking you’ve already made at this campground")
            } footer: {
                Text("Book on the campground’s website or by phone. RoamReady doesn’t book or show availability. After you book, come back and tap Add trip.")
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
                                         try? SavedCampground.set(campgroundID, name: "", region: "", on: list, included, in: context)
                                         library.save()
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

    private func openDirections(_ listing: CampgroundListing) {
        let item = finder.mapItem(for: listing) ?? {
            let item = MKMapItem(location: CLLocation(latitude: listing.latitude, longitude: listing.longitude), address: nil)
            item.name = listing.name
            return item
        }()
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
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
