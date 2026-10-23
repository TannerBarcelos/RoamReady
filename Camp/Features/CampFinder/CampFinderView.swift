import SwiftUI
import MapKit
import SwiftData
import CampCore
import Campgrounds
import CampPersistence

struct CampFinderView: View {
    @Query private var saved: [SavedCampground]
    @Query private var trips: [Trip]
    @State private var filter = CampgroundFilter()
    @State private var showFilters = false
    @State private var showMap = true
    @State private var list: CampgroundList?
    @State private var camera = MapCameraPosition.automatic
    @Environment(Connectivity.self) private var connection
    @State private var directory = OnlineCampgroundDirectory()

    private var lists: CampgroundLists { CampgroundLists(saved: saved, trips: trips) }
    var results: [Campground] {
        let lists = lists
        return directory.campgrounds.filter { place in filter.matches(place) && (list.map { lists.contains(place.id, on: $0) } ?? true) }
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
                    Menu {
                        Picker("Show", selection: $list) {
                            Text("All campgrounds").tag(CampgroundList?.none)
                            ForEach(CampgroundList.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                    } label: { Label(list?.title ?? "All", systemImage: list == nil ? "bookmark" : "bookmark.fill") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { showMap.toggle() } label: { Label(showMap ? "Show list" : "Show map", systemImage: showMap ? "list.bullet" : "map") }
                        .labelStyle(.iconOnly).buttonStyle(.bordered)
                }
                if showMap {
                    if connection.isOnline {
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
                                let lists = CampgroundList.allCases.filter { self.lists.contains(campground.id, on: $0) }
                                if !lists.isEmpty {
                                    Image(systemName: lists.contains(.favorite) ? "star.fill" : "bookmark.fill").foregroundStyle(.blue)
                                        .accessibilityLabel(lists.map(\.title).joined(separator: ", "))
                                }
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
                    Button("Clear filters") { filter = CampgroundFilter(); list = nil }
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
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
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
                    if let rig = rigs.active.first {
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
