import SwiftUI
import MapKit
import SwiftData
import CampCore
import Campgrounds
import CampPersistence

/// The owner's campground lists (#30). The marks work offline. A Camp Finder (Apple Maps) place is
/// saved by its identifier only, so its name comes from a trip there, or is looked up in Apple Maps
/// as its row appears while online.
struct SavedCampgroundsView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(CampFinder.self) private var finder
    @Environment(Connectivity.self) private var connectivity
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
                            row(id, lists: lists)
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") {
                                try? SavedCampground.set(id, name: "", region: "", on: list, false, in: context)
                                library.save()
                            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(name(id, lists: lists) ?? "this campground") from \(list.title)")
                        }
                    }
                }
            }
            let otherPlaces = Array(Set(trips.filter { $0.campgroundID == nil && $0.isCompleted() }.map(\.campgroundName))).sorted()
            if !otherPlaces.isEmpty {
                Section {
                    ForEach(otherPlaces, id: \.self) { Text($0) }
                } header: { Text("Other places you’ve camped") } footer: {
                    Text("Older trips entered by name.")
                }
            }
        }
        .navigationTitle("Your campgrounds")
    }

    @ViewBuilder private func row(_ id: String, lists: CampgroundLists) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(name(id, lists: lists) ?? "Saved campground")
            if let detail = detail(id, lists: lists) { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        if case .appleMaps(let identifier) = CampgroundIdentity(id), connectivity.isOnline {
            NavigationLink { CampgroundDetailView(identifier: identifier) } label: { label }
                // One lookup per row as it scrolls into view, never the whole list at once.
                .task(id: connectivity.isOnline) {
                    if finder.cachedListing(for: id) == nil { _ = try? await finder.listing(identifier: identifier) }
                }
        } else {
            label
        }
    }

    /// Apple Maps' name while looked up this session, then the owner's own name from a trip or the
    /// saved entry (campgrounds entered by name or previously saved).
    private func name(_ id: String, lists: CampgroundLists) -> String? {
        finder.cachedListing(for: id)?.name ?? lists.name(id)
    }

    private func detail(_ id: String, lists: CampgroundLists) -> String? {
        if let listing = finder.cachedListing(for: id) { return listing.address }
        if let region = lists.entry(id)?.region, !region.isEmpty { return region }
        if CampgroundIdentity(id).isAppleMapsPlace, lists.name(id) == nil {
            return connectivity.isOnline ? "Loading from Apple Maps…" : "Details load when you’re online"
        }
        return nil
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
