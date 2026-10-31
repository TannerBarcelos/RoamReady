import SwiftUI
import MapKit
import SwiftData
import CampCore
import Campgrounds
import CampPersistence

/// Camp Finder (#26): campgrounds and RV parks from Apple Maps. The map shows only campground
/// and RV park places, so they appear as you pan; tap one, or search, to see its details.
/// Online only in v1. Nothing here is user data; saving and trips go through SwiftData.
///
/// At regular width a system arrangement lays out the results and map, including around a fold.
/// At compact width the map stays at the top of the list. Search, camera, and selection live
/// here, above that switch, so moving between the layouts keeps them and doesn't search again.
struct CampFinderView: View {
    @Environment(CampFinder.self) private var finder
    @Environment(AppPermissions.self) private var permissions
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var resultsPath = NavigationPath()
    @State private var search = CampFinderSearch()
    @State private var location = LocationProvider()
    @State private var text = ""
    @State private var camera = MapCameraPosition.automatic
    @State private var visibleRegion: MKCoordinateRegion?
    /// Where the map was last left, so a rebuilt map opens in the same place.
    @State private var lastCamera: MapCamera?
    @State private var tapped: MapFeature?
    /// The campground whose details are open after a tap on the map or a search result.
    @State private var opened: CampgroundListing?
    @State private var tapFailure: CampFinderError?
    @State private var locating = false
    @State private var locationTask: Task<Void, Never>?
    @State private var locationRequest: UUID?

    var body: some View {
        content
    }

    /// Bars belong to the results column so search never extends across the map.
    private func resultsPane(includesMap: Bool) -> some View {
        NavigationStack(path: $resultsPath) {
            OnlineFeatureGate(feature: "Camp Finder", retry: retryDiscovery) {
                results(includesMap: includesMap)
                    .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Campground, city, park, or ZIP code")
                    .onSubmit(of: .search) {
                        guard connectivity.isOnline, cleanedSearchText(text) != nil else { return }
                        cancelLocation()
                        tapFailure = nil
                        search.run(.text(text, near: visibleRegion), using: finder)
                    }
            }
            .navigationTitle("Camp Finder")
            .assistantToolbarItem()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SavedCampgroundsView() } label: { Label("Your campgrounds", systemImage: "bookmark") }
                }
            }
        }
    }

    private var separatesMapAndResults: Bool { horizontalSizeClass == .regular }

    private var showsUserLocation: Bool {
        #if DEBUG
        // Deterministic discovery tests use a synthetic fix instead of the simulator's privacy database.
        if ProcessInfo.processInfo.arguments.contains("-camp-finder-ui-test") { return false }
        #endif
        return permissions.locationAllowed
    }

    private var content: some View {
        // Presentation and search lifecycle stay above the adaptive panes so resizing preserves state.
        ZStack {
            adaptiveResults
        }
        // One presentation across all widths keeps an open place stable during resizing.
        .sheet(item: $opened) { CampgroundDetailSheet(listing: $0) }
        .onChange(of: tapped) { _, feature in
            guard let feature else { return }
            tapped = nil
            guard connectivity.isOnline else { return }
            Task {
                do {
                    let listing = try await finder.listing(for: feature)
                    guard connectivity.isOnline else { return }
                    opened = listing; tapFailure = nil
                } catch {
                    guard connectivity.isOnline else { return }
                    tapFailure = error as? CampFinderError ?? .failed
                }
            }
        }
        .onChange(of: search.results.map(\.id)) { _, _ in fitResults() }
        .onChange(of: separatesMapAndResults) { _, _ in
            // The map is rebuilt in its new place; open it where the person left it.
            if let lastCamera, !camera.followsUserLocation { camera = .camera(lastCamera) }
        }
        .task(id: [connectivity.isOnline, permissions.locationAllowed]) {
            guard connectivity.isOnline else { cancelDiscovery(); return }
            if let lastCamera, !camera.followsUserLocation { camera = .camera(lastCamera) }
            if search.wasInterrupted {
                search.retry(using: finder)
            } else if search.current == nil, permissions.locationAllowed {
                searchNearMe()
            }
        }
        .onDisappear { cancelDiscovery() }
    }

    @ViewBuilder private var adaptiveResults: some View {
        if separatesMapAndResults {
            #if targetEnvironment(macCatalyst)
            // Catalyst's SwiftUI SDK does not expose ArrangementView.
            regularPanes
            #else
            if #available(iOS 27.1, *) {
                // The system handles division regions. The results own their navigation
                // and search bars inside the primary pane; the map gets its full column.
                ArrangementView {
                    resultsPane(includesMap: false)
                } secondary: {
                    map
                }
                .arrangementViewStyle(.split)
            } else {
                regularPanes
            }
            #endif
        } else {
            resultsPane(includesMap: true)
        }
    }

    /// Flexible native panes for platforms and runtimes without the arrangement API.
    private var regularPanes: some View {
        HStack(spacing: 0) {
            resultsPane(includesMap: false).frame(maxWidth: .infinity)
            Divider()
            map.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func results(includesMap: Bool) -> some View {
        List {
            Section {
                if includesMap { listMap }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        nearMeButton
                        searchAreaButton
                    }
                    VStack(spacing: 12) {
                        nearMeButton
                        searchAreaButton
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .controlSize(.large)
                if permissions.locationDenied {
                    Text("Location access is off. Search by city, park, or ZIP code, or allow location in Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                    OpenPermissionSettingsButton()
                }
                if let tapFailure { Text(tapFailure.message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Near me: 50-mile radius. Search: visible map area.")
                    .accessibilityIdentifier("campFinderSearchHelp")
            }
            status
            if !search.results.isEmpty {
                Section {
                    ForEach(search.results) { listing in
                        Button { showDetails(for: listing) } label: { CampgroundRow(listing: listing) }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("campgroundResult")
                    }
                } header: {
                    Text(search.results.count == 1 ? "1 campground" : "\(search.results.count) campgrounds")
                } footer: {
                    Text("Places from Apple Maps. Book on the campground’s website, then come back and tap Add trip. RoamReady doesn’t book or show availability.")
                }
            }
        }
        .accessibilityIdentifier("campFinderResults")
    }

    private var nearMeButton: some View {
        Button { searchNearMe() } label: {
            Label("Near me", systemImage: permissions.locationDenied ? "location.slash" : "location.fill")
                .labelStyle(.titleAndIcon).fixedSize()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).disabled(!connectivity.isOnline || locating || permissions.locationDenied)
        .accessibilityIdentifier("campFinderNearMe")
    }

    private var searchAreaButton: some View {
        Button { searchVisibleArea() } label: {
            Label("Search", systemImage: "arrow.clockwise")
                .labelStyle(.titleAndIcon).fixedSize()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).disabled(!connectivity.isOnline || visibleRegion == nil)
        .accessibilityIdentifier("campFinderSearchArea")
        .accessibilityHint("Finds campgrounds in the visible map area")
    }

    @ViewBuilder private var map: some View {
        if connectivity.isOnline {
            interactiveMap
        } else {
            ContentUnavailableView("Map unavailable offline", systemImage: "wifi.slash")
                .accessibilityIdentifier("campFinderOfflineMap")
        }
    }

    private var interactiveMap: some View {
        Map(position: $camera, selection: $tapped) {
            if showsUserLocation { UserAnnotation() }
            ForEach(search.results) { listing in
                Annotation(listing.name, coordinate: listing.coordinate) {
                    Button { showDetails(for: listing) } label: {
                        RigGlyph(type: listing.kind == .rvPark ? .travelTrailer : .tent)
                            .padding(10).background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(listing.name)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .including(CampFinder.categories)))
        .mapControls {
            if showsUserLocation { MapUserLocationButton() }
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { visibleRegion = $0.region; lastCamera = $0.camera }
        .accessibilityLabel("Map of campgrounds and RV parks")
        .accessibilityIdentifier("campFinderMap")
    }

    private var listMap: some View {
        map
            .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 16))
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    @ViewBuilder private var status: some View {
        switch search.phase {
        case .idle:
            if locating {
                Section { HStack { Spacer(); ProgressView("Finding your location…"); Spacer() } }
            }
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
                    if failure.canRetry { Button("Try again", action: retryDiscovery) }
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

    private func showDetails(for listing: CampgroundListing) {
        guard connectivity.isOnline else { return }
        tapFailure = nil
        opened = listing
    }

    private func searchNearMe() {
        guard connectivity.isOnline, !permissions.locationDenied, !locating else { return }
        let request = UUID()
        locationRequest = request
        locating = true
        tapFailure = nil
        locationTask = Task {
            defer {
                if locationRequest == request { locating = false; locationTask = nil; locationRequest = nil }
            }
            guard !Task.isCancelled, locationRequest == request, connectivity.isOnline else { return }
            let here = await location.currentLocation()
            guard !Task.isCancelled, locationRequest == request, connectivity.isOnline else { return }
            guard let here else {
                if !location.isDenied, !permissions.locationDenied { tapFailure = .locationUnavailable }
                return
            }
            let region = CampFinder.nearbyRegion(around: here.coordinate)
            visibleRegion = region
            camera = .region(region)
            search.run(.nearby(here.coordinate), using: finder)
        }
    }

    private func searchVisibleArea() {
        guard connectivity.isOnline, let visibleRegion else { return }
        cancelLocation()
        tapFailure = nil
        search.run(.area(visibleRegion), using: finder)
    }

    private func cancelLocation() {
        locationTask?.cancel()
        locationTask = nil
        locationRequest = nil
        locating = false
        location.cancelPendingRequest()
    }

    private func cancelDiscovery() {
        cancelLocation()
        search.cancel()
    }

    private func retryDiscovery() {
        guard connectivity.isOnline else { return }
        tapFailure = nil
        if search.current != nil { search.retry(using: finder) }
        else if permissions.locationAllowed { searchNearMe() }
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

/// Campground details keep their own stack and presentation while the underlying window resizes.
private struct CampgroundDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let listing: CampgroundListing
    var body: some View {
        NavigationStack {
            CampgroundDetailView(listing: listing)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("closeCampground")
                    }
                }
        }
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
