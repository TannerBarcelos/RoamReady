import SwiftUI
import MapKit
import SwiftData
import CampCore
import CampPersistence

/// The owner's campground lists (#30). Works offline: names are saved with each entry, and
/// campgrounds from completed trips come from the trips themselves.
struct SavedCampgroundsView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Query private var saved: [SavedCampground]
    @Query private var trips: [Trip]
    var body: some View {
        let lists = CampgroundLists(saved: saved, trips: trips)
        List {
            ForEach(CampgroundList.allCases) { list in
                let ids = lists.campgroundIDs(on: list)
                Section(list.title) {
                    if ids.isEmpty {
                        Text(emptyText(list)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(ids, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lists.name(id))
                                if let region = lists.entry(id)?.region, !region.isEmpty {
                                    Text(region).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") {
                                try? SavedCampground.set(id, name: lists.name(id), region: "", on: list, false, in: context)
                                library.save()
                            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(lists.name(id)) from \(list.title)")
                        }
                    }
                }
            }
            let otherPlaces = Array(Set(trips.filter { $0.campgroundID == nil && $0.isCompleted() }.map(\.campgroundName))).sorted()
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
