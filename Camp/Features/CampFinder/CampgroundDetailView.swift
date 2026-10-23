import SwiftUI
import MapKit
import SwiftData
import CampCore
import Campgrounds
import CampPersistence

struct CampgroundDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Query private var saved: [SavedCampground]
    @Query(sort: \Trip.arrival, order: .reverse) private var trips: [Trip]
    let campground: Campground
    @State private var planning = false
    var previousTrips: [Trip] {
        trips.filter {
            $0.campgroundID == campground.id || ($0.campgroundID == nil && $0.campgroundName.localizedCaseInsensitiveCompare(campground.name) == .orderedSame)
        }
    }
    var body: some View {
        OnlineFeatureGate(feature: "Campground discovery") { onlineContent }
    }
    private var onlineContent: some View {
        List {
            Section {
                Text(campground.region).foregroundStyle(.secondary)
                Text(campground.notes)
            }
            Section {
                ForEach(CampgroundList.allCases) { list in
                    Toggle(isOn: Binding(get: { CampgroundLists(saved: saved, trips: trips).contains(campground.id, on: list) },
                                         set: { included in
                                             try? SavedCampground.set(campground.id, name: campground.name, region: campground.region, on: list, included, in: context)
                                             library.save()
                                         })) {
                        Label(list.title, systemImage: list.symbol)
                    }
                }
            } header: { Text("Your lists") } footer: {
                Text("Campgrounds from your completed trips are added to Been here automatically. Turn it off to remove one.")
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
