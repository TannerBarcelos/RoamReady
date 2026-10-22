import SwiftUI
import MapKit
import CampCore
import Campgrounds

struct PlanView: View {
    @Environment(CampStore.self) private var store
    @State private var planning = false
    var upcoming: [Trip] { store.state.trips.filter { !$0.isCompleted() }.sorted { $0.arrival < $1.arrival } }
    var completed: [Trip] { store.state.trips.filter { $0.isCompleted() }.sorted { $0.arrival > $1.arrival } }
    var body: some View {
        List {
            if store.state.trips.isEmpty {
                ContentUnavailableView("No trips yet", systemImage: "calendar.badge.plus", description: Text("After you reserve a campsite, add the booking here and we’ll prepare your checklists."))
            }
            if !upcoming.isEmpty { Section("Upcoming & current") { ForEach(upcoming) { TripRow(trip: $0) } } }
            if !completed.isEmpty { Section("Completed trips") { ForEach(completed) { TripRow(trip: $0) } } }
            Section { NavigationLink { SavedCampgroundsView() } label: { Label("Your campgrounds", systemImage: "bookmark") } }
            Button("Add a trip", systemImage: "plus") { planning = true }
        }
        .navigationTitle("Plan")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New trip", systemImage: "plus") { planning = true } } }
        .sheet(isPresented: $planning) { NewTripView() }
    }
}

struct TripRow: View {
    let trip: Trip
    var body: some View {
        NavigationLink { TripDetailView(tripID: trip.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.campgroundName).font(.headline)
                Text(trip.dateSummary).font(.subheadline).foregroundStyle(.secondary)
                if !trip.siteNumber.isEmpty { Text("Site \(trip.siteNumber)").font(.caption).foregroundStyle(.secondary) }
                if trip.isCompleted() { Label("Completed", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }
    }
}
