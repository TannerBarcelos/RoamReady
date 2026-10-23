import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct PlanView: View {
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    @State private var planning = false
    var body: some View {
        let upcoming = trips.filter { !$0.isCompleted() }
        let completed = trips.filter { $0.isCompleted() }.reversed()
        List {
            if trips.isEmpty {
                ContentUnavailableView("No trips yet", systemImage: "calendar.badge.plus", description: Text("After you reserve a campsite, add the booking here and we’ll prepare your checklists."))
            }
            if !upcoming.isEmpty { Section("Upcoming & current") { ForEach(upcoming) { TripRow(trip: $0) } } }
            if !completed.isEmpty { Section("Completed trips") { ForEach(Array(completed)) { TripRow(trip: $0) } } }
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
        NavigationLink { TripDetailView(trip: trip) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.campgroundName).font(.headline)
                Text(trip.dateSummary).font(.subheadline).foregroundStyle(.secondary)
                if !trip.siteNumber.isEmpty { Text("Site \(trip.siteNumber)").font(.caption).foregroundStyle(.secondary) }
                if trip.isCompleted() { Label("Completed", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }
    }
}
