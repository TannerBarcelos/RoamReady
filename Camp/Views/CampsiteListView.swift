import SwiftUI
import CampCore

struct CampsiteListView: View {
    @Environment(Connectivity.self) private var connectivity
    let campground: Campground
    @State private var sites: [CampsiteSnapshot] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var query = ""
    @State private var rigOnly = false
    @Environment(CampStore.self) private var store
    private var results: [CampsiteSnapshot] {
        sites.filter { site in
            (query.isEmpty || (site.name + " " + site.loop + " " + site.kind).localizedCaseInsensitiveContains(query))
            && (!rigOnly || store.state.profile.map { site.equipment[$0.rig.type.rawValue] != nil } == true)
        }
    }
    var body: some View {
        OnlineFeatureGate(feature: "Campsite details") {
            List {
                Section {
                    Toggle("Show sites permitting my rig type", isOn: $rigOnly)
                    Text("Snapshot information, not live availability. A permitted rig type does not guarantee that your rig’s length or equipment fits.").font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView("Loading site details…") }
                if let failure { Text(failure).foregroundStyle(.secondary); Button("Retry") { Task { await load() } } }
                ForEach(results) { site in
                    NavigationLink {
                        CampsiteDetailView(site: site, campground: campground)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(site.name.isEmpty ? "Site \(site.id)" : "Site \(site.name)").font(.headline)
                            Text([site.loop, site.kind.capitalized].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !loading, failure == nil, results.isEmpty { Text("No matching site records in this snapshot. Check the operator for complete current information.").foregroundStyle(.secondary) }
            }
            .searchable(text: $query, prompt: "Site number or loop")
        }
        .navigationTitle("Campsites")
        .task(id: connectivity.isOnline) { if connectivity.isOnline { await load() } }
    }
    private func load() async {
        guard connectivity.isOnline else { return }
        loading = true; failure = nil
        defer { loading = false }
        guard campground.id.hasPrefix("ridb-"), let base = OnlineCampgroundDirectory.baseURL else {
            failure = "Site details aren’t available for this campground in the configured dataset."; return
        }
        do { sites = try await CampsiteDirectory.shared.sites(facilityID: String(campground.id.dropFirst(5)), baseURL: base).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        catch { failure = "Site details couldn’t be downloaded. Please retry when connected." }
    }
}

struct CampsiteDetailView: View {
    let site: CampsiteSnapshot
    let campground: Campground
    var body: some View {
        OnlineFeatureGate(feature: "Campsite details") {
            List {
                Section {
                    LabeledContent("Loop", value: site.loop.isEmpty ? "Not listed" : site.loop)
                    LabeledContent("Site type", value: site.kind.capitalized)
                    LabeledContent("Vehicle access", value: site.vehicleAccessible.map { $0 ? "Listed as accessible by vehicle" : "Not listed as accessible by vehicle" } ?? "Unknown")
                }
                Section("Permitted equipment") {
                    ForEach(RigType.allCases.filter { site.equipment[$0.rawValue] != nil }) { type in
                        LabeledContent(type.title, value: site.maximumLengthFeet(for: type).map { "Up to \(Int($0)) ft" } ?? "Length limit not published")
                    }
                    if site.equipment.isEmpty { Text("Not published. Verify with the operator.") }
                }
                Section("Published site attributes") {
                    ForEach(site.attributes.keys.sorted(), id: \.self) { key in LabeledContent(key, value: site.attributes[key] ?? "") }
                }
                Section {
                    if let url = URL(string: "https://www.recreation.gov/camping/campsites/\(site.id)") { Link("Verify site and booking information", destination: url) }
                    Text("Source updated \(site.updatedAt). Snapshot facts can change; verify restrictions and current availability before booking.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(site.name.isEmpty ? "Campsite" : "Site \(site.name)")
    }
}
