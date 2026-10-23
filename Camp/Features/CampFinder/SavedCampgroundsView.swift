import SwiftUI
import MapKit
import CampCore
import Campgrounds

/// The owner's campground lists (#30). Works offline: names are saved with each entry, and
/// campgrounds from completed trips come from the trips themselves.
struct SavedCampgroundsView: View {
    @Environment(CampStore.self) private var store
    var body: some View {
        List {
            ForEach(CampgroundList.allCases) { list in
                let ids = store.library.campgroundIDs(on: list)
                Section(list.title) {
                    if ids.isEmpty {
                        Text(emptyText(list)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(ids, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(id))
                                if let region = store.savedCampgrounds[id]?.region, !region.isEmpty {
                                    Text(region).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") {
                                store.setCampground(id, name: name(id), region: "", on: list, false)
                            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(name(id)) from \(list.title)")
                        }
                    }
                }
            }
            let otherPlaces = Array(Set(store.state.trips.filter { $0.campgroundID == nil && $0.isCompleted() }.map(\.campgroundName))).sorted()
            if !otherPlaces.isEmpty {
                Section {
                    ForEach(otherPlaces, id: \.self) { Text($0) }
                } header: { Text("Other places you’ve camped") } footer: {
                    Text("Trips entered by name rather than from Camp Finder.")
                }
            }
        }
        .navigationTitle("Your campgrounds")
    }
    private func name(_ id: String) -> String {
        if let saved = store.savedCampgrounds[id]?.name, !saved.isEmpty { return saved }
        return store.state.trips.first { $0.campgroundID == id }?.campgroundName ?? "Campground \(id)"
    }
    private func emptyText(_ list: CampgroundList) -> String {
        switch list {
        case .wantToGo: "Add campgrounds from Camp Finder."
        case .beenTo: "Campgrounds from your completed trips appear here."
        case .favorite: "Star the campgrounds you love in Camp Finder."
        }
    }
}

extension CampgroundList {
    var symbol: String {
        switch self {
        case .wantToGo: "bookmark"
        case .beenTo: "checkmark.seal"
        case .favorite: "star"
        }
    }
}
