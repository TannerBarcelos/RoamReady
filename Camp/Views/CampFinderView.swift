import SwiftUI
import MapKit
import CampCore

struct CampFinderView: View {
    @Environment(CampStore.self) private var store
    @State private var filter = CampgroundFilter()
    @State private var showFilters = false
    @State private var showMap = true
    @State private var savedOnly = false
    @State private var camera = MapCameraPosition.automatic
    @Environment(Connectivity.self) private var connection
    @State private var directory = OnlineCampgroundDirectory()

    var saved: Set<String> { store.savedCampgroundIDs }
    var results: [Campground] {
        directory.campgrounds.filter { filter.matches($0) && (!savedOnly || saved.contains($0.id)) }
    }
    var activeFilters: Int {
        filter.requiredAmenities.count + (filter.noElectricHookups ? 1 : 0) + (filter.rigType == nil ? 0 : 1)
        + (filter.minimumRigLengthFeet == nil ? 0 : 1) + (filter.maximumNightlyPriceUSD == nil ? 0 : 1)
    }

    var body: some View {
        OnlineFeatureGate(feature: "Camp Finder") { onlineContent }
    }
    private var onlineContent: some View {
        List {
            Section {
                HStack {
                    Button { showFilters = true } label: { Label(activeFilters == 0 ? "Filters" : "Filters · \(activeFilters)", systemImage: "line.3.horizontal.decrease") }
                        .buttonStyle(.bordered)
                    Toggle("Saved", isOn: $savedOnly).toggleStyle(.button).buttonStyle(.bordered)
                    Spacer()
                    Button { showMap.toggle() } label: { Label(showMap ? "Show list" : "Show map", systemImage: showMap ? "list.bullet" : "map") }
                        .labelStyle(.iconOnly).buttonStyle(.bordered)
                }
                if showMap {
                    if connection.connected {
                        Map(position: $camera) {
                            ForEach(Array(results.prefix(200))) { place in
                                Annotation(place.name, coordinate: place.coordinate) {
                                    NavigationLink { CampgroundDetailView(campground: place) } label: {
                                        Image(systemName: "tent.fill").font(.title3).padding(10).foregroundStyle(.white).background(.blue, in: Circle())
                                    }.accessibilityLabel(place.name)
                                }
                            }
                        }
                        .mapControls { MapCompass(); MapScaleView() }
                        .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 16))
                        .onChange(of: results.map(\.id)) { _, _ in camera = .automatic }
                    } else {
                        ContentUnavailableView("Campgrounds are still here", systemImage: "wifi.slash", description: Text("Search the saved directory below. The map needs a connection."))
                            .frame(minHeight: 180)
                    }
                }
                if directory.loading { ProgressView("Loading campground directory…") }
                if let failure = directory.failure {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                    Button("Retry directory") { Task { await directory.load() } }
                }
                if results.count > 200 { Text("Map shows the first 200 results. Search or filter to narrow the area.").font(.caption).foregroundStyle(.secondary) }
            } footer: { Text(directory.notice) }
            Section("\(results.count) campgrounds") {
                ForEach(results) { campground in
                    NavigationLink { CampgroundDetailView(campground: campground) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(campground.name).font(.headline)
                                if saved.contains(campground.id) { Image(systemName: "bookmark.fill").foregroundStyle(.blue).accessibilityLabel("Saved") }
                            }
                            Text(campground.region).font(.subheadline).foregroundStyle(.secondary)
                            if !campground.availableAmenities.isEmpty {
                                Text(campground.availableAmenities.prefix(3).map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if results.isEmpty {
                    ContentUnavailableView.search(text: filter.query)
                    Button("Clear filters") { filter = CampgroundFilter(); savedOnly = false }
                }
            }
        }
        .navigationTitle("Camp Finder")
        .task(id: connection.isOnline) { if connection.isOnline { await directory.load() } }
        .searchable(text: $filter.query, prompt: "Campground, park, or state")
        .sheet(isPresented: $showFilters) { CampgroundFiltersView(filter: $filter) }
    }
}

struct CampgroundFiltersView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: CampgroundFilter
    var body: some View {
        NavigationStack {
            Form {
                Section("Your rig") {
                    Picker("Rig type", selection: $filter.rigType) {
                        Text("Any type").tag(nil as RigType?)
                        ForEach(RigType.allCases) { Text($0.title).tag(Optional($0)) }
                    }.onChange(of: filter.rigType) { _, type in
                        if type == nil || type == .tent || type == .carCamping { filter.minimumRigLengthFeet = nil }
                    }
                    if let rig = store.state.profile?.rig {
                        Button("Use my \(rig.type.title.lowercased())") { filter.use(rig) }
                    }
                    if let type = filter.rigType, type.isRV {
                        LabeledContent("Minimum length (ft)") {
                            TextField("Any", text: numberBinding(\.minimumRigLengthFeet))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section("Hookups & amenities") {
                    ForEach(CampAmenity.allCases) { amenity in
                        Toggle(amenity.title, isOn: Binding(
                            get: { filter.requiredAmenities.contains(amenity) },
                            set: { value in
                                if value {
                                    filter.requiredAmenities.insert(amenity)
                                    if [.electricHookup, .amp30, .amp50].contains(amenity) { filter.noElectricHookups = false }
                                } else { filter.requiredAmenities.remove(amenity) }
                            }
                        ))
                    }
                    Toggle("No electric hookups", isOn: $filter.noElectricHookups)
                        .onChange(of: filter.noElectricHookups) { _, value in
                            if value { filter.requiredAmenities.subtract([.electricHookup, .amp30, .amp50]) }
                        }
                }
                Section {
                    TextField("Maximum nightly rate (USD)", text: numberBinding(\.maximumNightlyPriceUSD)).keyboardType(.decimalPad)
                } header: { Text("Budget") } footer: {
                    Text("Filters include only confirmed information. Campgrounds with unknown prices or amenities are excluded when you require them. Amenities may apply to selected sites only; verify the specific site before booking.")
                }
                Button("Reset filters", role: .destructive) { filter = CampgroundFilter() }
            }
            .navigationTitle("Filters").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func numberBinding(_ keyPath: WritableKeyPath<CampgroundFilter, Double?>) -> Binding<String> {
        Binding(get: { filter[keyPath: keyPath].map { String(format: "%g", $0) } ?? "" },
                set: { value in filter[keyPath: keyPath] = Double(value).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } })
    }
}

struct CampgroundDetailView: View {
    @Environment(CampStore.self) private var store
    let campground: Campground
    @State private var planning = false
    var saved: Bool { store.savedCampgroundIDs.contains(campground.id) }
    var previousTrips: [Trip] {
        store.state.trips.filter {
            $0.campgroundID == campground.id || ($0.campgroundID == nil && $0.campgroundName.localizedCaseInsensitiveCompare(campground.name) == .orderedSame)
        }
            .sorted { $0.arrival > $1.arrival }
    }
    var body: some View {
        OnlineFeatureGate(feature: "Campground discovery") { onlineContent }
    }
    private var onlineContent: some View {
        List {
            Section {
                Text(campground.region).foregroundStyle(.secondary)
                Text(campground.notes)
                Button(saved ? "Remove from saved" : "Save campground", systemImage: saved ? "bookmark.fill" : "bookmark") {
                    store.toggleSavedCampground(campground.id)
                }
            }
            Section {
                // The app never books: reserving happens on the provider's own site.
                if let url = campground.reserveLink {
                    Link(destination: url) { Label("Reserve on provider site", systemImage: "safari") }
                        .accessibilityHint("Opens the campground's reservation page in Safari")
                }
                Button("Add trip", systemImage: "calendar.badge.plus") { planning = true }
                    .accessibilityHint("Enter a booking you've already made at this campground")
                if let url = campground.websiteLink {
                    Link(destination: url) { Label("Website", systemImage: "globe") }
                        .accessibilityHint("Opens the official website in Safari")
                }
                if let url = campground.phoneLink, let phone = campground.phone {
                    Link(destination: url) { Label("Call \(phone)", systemImage: "phone") }
                        .accessibilityLabel("Call campground, \(phone)")
                }
                if let url = campground.emailLink, let email = campground.email {
                    Link(destination: url) { Label(email, systemImage: "envelope") }
                        .accessibilityLabel("Email campground, \(email)")
                }
                Button("Directions", systemImage: "car") { openDirections() }
                    .accessibilityHint("Opens Apple Maps with driving directions")
            } footer: { Text("Reservations are made with the campground or its provider. RoamReady doesn't book or show availability. After you reserve, tap Add trip to save the booking.") }
            Section {
                NavigationLink { CampsiteListView(campground: campground) } label: {
                    Label("Explore individual campsites", systemImage: "number.square")
                }
            }
            Section("Known amenities") {
                ForEach(CampAmenity.allCases) { amenity in
                    LabeledContent(amenity.title, value: campground.availability(of: amenity).map { $0 ? "Available at some sites" : "Not provided" } ?? "Unknown")
                        .font(.subheadline)
                }
            }
            if !previousTrips.isEmpty {
                Section("Your memories here") {
                    ForEach(previousTrips) { trip in
                        NavigationLink { MemoriesView(tripID: trip.id) } label: {
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
            Section {
                if let url = campground.sourceLink { Link("Official campground information", destination: url) }
                Text(attribution).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(campground.name)
        .sheet(isPresented: $planning) { NewTripView(initialCampground: campground) }
    }
    private var attribution: String {
        let facts = campground.id.hasPrefix("ridb-")
            ? "Facts from Recreation.gov, as of \(campground.checkedAt). Data: Recreation Information Database (RIDB)."
            : "Checked \(campground.checkedAt)."
        return facts + " Prices and restrictions can change. Confirm the exact site with the operator."
    }
    private func openDirections() {
        let item = MKMapItem(location: CLLocation(latitude: campground.latitude, longitude: campground.longitude), address: nil)
        item.name = campground.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

struct CampgroundPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Campground) -> Void
    @State private var query = ""
    @Environment(Connectivity.self) private var connectivity
    @State private var directory = OnlineCampgroundDirectory()
    var body: some View {
        OnlineFeatureGate(feature: "Campground search") { onlineContent }
    }
    private var onlineContent: some View {
        List {
            Section {
                ForEach(directory.campgrounds.filter { query.isEmpty || ($0.name + " " + $0.region).localizedCaseInsensitiveContains(query) }) { place in
                    Button { onSelect(place) } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(place.name); Text(place.region).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if directory.loading { ProgressView("Loading campground directory…") }
                if let failure = directory.failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            } footer: { Text(directory.notice) }
        }
        .navigationTitle("Choose campground").navigationBarTitleDisplayMode(.inline)
        .task(id: connectivity.isOnline) { if connectivity.isOnline { await directory.load() } }
        .searchable(text: $query, prompt: "Campground or state")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
