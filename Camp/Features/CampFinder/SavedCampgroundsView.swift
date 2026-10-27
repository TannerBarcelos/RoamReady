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
    @Environment(\.mainTabActions) private var tabActions
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailure: String?
    @Query private var saved: [SavedCampground]
    @Query private var trips: [Trip]
    var body: some View {
        let lists = CampgroundLists(saved: saved, trips: trips)
        List {
            if lists.count == 0 {
                ContentUnavailableView {
                    Label { Text("No saved campgrounds") } icon: {
                        Image(systemName: "bookmark").foregroundStyle(.tint)
                    }
                } description: {
                    Text("Save places as you explore. Your lists stay on this iPhone and open offline.")
                }
                Section {
                    ForEach(CampgroundList.allCases) { list in
                        Label { VStack(alignment: .leading, spacing: 2) {
                            Text(list.title)
                            Text(list.purpose).font(.caption).foregroundStyle(.secondary)
                        } } icon: { Image(systemName: list.symbol).foregroundStyle(.tint) }
                    }
                }
                Section {
                    // Pop back first: this screen is also pushed from Camp Finder itself.
                    Button("Open Camp Finder", systemImage: "map") { dismiss(); tabActions.showCampFinder() }
                        .frame(maxWidth: .infinity).buttonStyle(.borderedProminent)
                }.listRowBackground(Color.clear)
            } else {
                listSections(lists)
            }
        }
        .navigationTitle("Your campgrounds")
        .alert("Couldn’t update your campgrounds", isPresented: Binding(
            get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
            Button("OK") { saveFailure = nil }
        } message: { Text(saveFailure ?? "") }
    }

    @ViewBuilder private func listSections(_ lists: CampgroundLists) -> some View {
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
                            do {
                                try SavedCampground.set(id, name: "", region: "", on: list, false, in: context)
                                library.save()
                            } catch { saveFailure = error.localizedDescription }
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(name(id, lists: lists) ?? "this campground") from \(list.title)")
                    }
                }
            }
        }
        if !lists.otherPlaces.isEmpty {
            Section {
                ForEach(lists.otherPlaces, id: \.self) { Text($0) }
            } header: { Text("Other places you’ve camped") } footer: {
                Text("Older trips entered by name.")
            }
        }
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

/// Profile's link to the campground lists, with how many places they hold.
struct YourCampgroundsLink: View {
    @Query private var saved: [SavedCampground]
    @Query private var trips: [Trip]
    var body: some View {
        let count = CampgroundLists(saved: saved, trips: trips).count
        NavigationLink { SavedCampgroundsView() } label: {
            LabeledContent { Text(count == 0 ? "None yet" : String(count)) } label: {
                WrappingLabel("Your campgrounds", systemImage: "bookmark")
            }
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

    /// What the list is for, shown before anything is saved.
    var purpose: String {
        switch self {
        case .wantToGo: "Places you’re considering, saved from Camp Finder"
        case .beenTo: "Fills in from your completed trips"
        case .favorite: "The ones you’d return to"
        }
    }
}
