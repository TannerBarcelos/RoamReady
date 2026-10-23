import SwiftUI
import MapKit
import SwiftData
import CampCore
import Campgrounds
import CampPersistence

/// Camp Finder (#26): campgrounds and RV parks from Apple Maps. The map shows only campground
/// and RV park places, so they appear as you pan; tap one, or search, to see its details.
/// Online only in v1. Nothing here is user data; saving and trips go through SwiftData.
struct CampFinderView: View {
    @Environment(CampFinder.self) private var finder
    @State private var search = CampFinderSearch()
    @State private var location = LocationProvider()
    @State private var text = ""
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var tapped: MapFeature?
    @State private var opened: CampgroundListing?
    @State private var tapFailure: CampFinderError?
    @State private var locating = false

    var body: some View {
        OnlineFeatureGate(feature: "Camp Finder", retry: { search.retry(using: finder) }) { content }
            .navigationTitle("Camp Finder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SavedCampgroundsView() } label: { Label("Your campgrounds", systemImage: "bookmark") }
                }
            }
    }

    private var content: some View {
        List {
            Section {
                map
                HStack {
                    Button { searchNearMe() } label: { Label("Near me", systemImage: "location.fill") }
                        .buttonStyle(.bordered).disabled(locating)
                    Spacer()
                    Button { searchVisibleArea() } label: { Label("Search this area", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered).disabled(visibleRegion == nil)
                }
                if location.isDenied {
                    Text("Location access is off. Search by city, park, or ZIP code, or allow location in Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let tapFailure { Text(tapFailure.message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Tap a campground on the map, or search, to see its details.")
            }
            status
            if !search.results.isEmpty {
                Section {
                    ForEach(search.results) { listing in
                        NavigationLink(value: listing) { CampgroundRow(listing: listing) }
                    }
                } header: {
                    Text(search.results.count == 1 ? "1 campground" : "\(search.results.count) campgrounds")
                } footer: {
                    Text("Places from Apple Maps. Book on the campground’s website, then come back and tap Add trip. RoamReady doesn’t book or show availability.")
                }
            }
        }
        .navigationDestination(for: CampgroundListing.self) { CampgroundDetailView(listing: $0) }
        .navigationDestination(item: $opened) { CampgroundDetailView(listing: $0) }
        .searchable(text: $text, prompt: "Campground, city, park, or ZIP code")
        .onSubmit(of: .search) {
            guard cleanedSearchText(text) != nil else { return }
            search.run(.text(text, near: visibleRegion), using: finder)
        }
        .onChange(of: tapped) { _, feature in
            guard let feature else { return }
            tapped = nil
            Task {
                do { opened = try await finder.listing(for: feature); tapFailure = nil }
                catch { tapFailure = error as? CampFinderError ?? .failed }
            }
        }
        .onChange(of: search.results.map(\.id)) { _, _ in fitResults() }
        .task {
            // Searches nearby on its own only when permission was already given; never prompts on open.
            if search.phase == .idle, location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways {
                searchNearMe()
            }
        }
        .onDisappear { search.cancel() }
    }

    private var map: some View {
        Map(position: $camera, selection: $tapped) {
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .including(CampFinder.categories)))
        .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .onEnd) { visibleRegion = $0.region }
        .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 16))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .accessibilityLabel("Map of campgrounds and RV parks")
    }

    @ViewBuilder private var status: some View {
        switch search.phase {
        case .idle:
            EmptyView()
        case .loading:
            Section { HStack { Spacer(); ProgressView("Searching…"); Spacer() } }
        case .failed(let failure):
            Section {
                ContentUnavailableView {
                    Label(failure == .offline ? "Connection needed" : "Search didn’t finish",
                          systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.magnifyingglass")
                } description: {
                    Text(failure.message)
                } actions: {
                    if failure.canRetry { Button("Try again") { search.retry(using: finder) } }
                }
            }
        case .loaded:
            if search.results.isEmpty {
                Section {
                    ContentUnavailableView("No campgrounds found", systemImage: "magnifyingglass",
                                           description: Text("Apple Maps doesn’t list every campground. Try a wider area, a nearby town, or the campground’s name. You can always add a trip by name."))
                }
            }
        }
    }

    private func searchNearMe() {
        locating = true
        Task {
            defer { locating = false }
            guard let here = await location.currentLocation() else { return }
            let region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
            camera = .region(region)
            search.run(.area(region), using: finder)
        }
    }

    private func searchVisibleArea() {
        guard let visibleRegion else { return }
        search.run(.area(visibleRegion), using: finder)
    }

    /// Text searches move the map to what they found; area searches keep the person's view.
    private func fitResults() {
        guard case .text? = search.current else { return }
        let coordinates = search.results.prefix(25).map(\.coordinate) + (search.center.map { [$0] } ?? [])
        guard let first = coordinates.first else { return }
        var minLatitude = first.latitude, maxLatitude = first.latitude, minLongitude = first.longitude, maxLongitude = first.longitude
        for coordinate in coordinates {
            minLatitude = min(minLatitude, coordinate.latitude); maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude); maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.05, (maxLatitude - minLatitude) * 1.4),
                                    longitudeDelta: max(0.05, (maxLongitude - minLongitude) * 1.4))
        camera = .region(MKCoordinateRegion(center: center, span: span))
    }
}

/// A result row: name, saved state, kind, and address or phone when Apple Maps has them.
struct CampgroundRow: View {
    let listing: CampgroundListing
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(listing.name).font(.headline)
                SavedMarker(campgroundID: listing.id)
            }
            if let address = listing.address { Text(address).font(.subheadline).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                if let kind = listing.kind { Text(kind.title) }
                if listing.websiteLink != nil { Label("Website", systemImage: "globe").labelStyle(.titleAndIcon) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Shows which of the owner's lists a campground is on.
struct SavedMarker: View {
    @Query private var saved: [SavedCampground]
    @Query private var trips: [Trip]
    let campgroundID: String
    var body: some View {
        let library = CampgroundLists(saved: saved, trips: trips)
        let lists = CampgroundList.allCases.filter { library.contains(campgroundID, on: $0) }
        if !lists.isEmpty {
            Image(systemName: lists.contains(.favorite) ? "star.fill" : lists.contains(.wantToGo) ? "bookmark.fill" : "checkmark.seal.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("Saved: " + lists.map(\.title).joined(separator: ", "))
        }
    }
}
