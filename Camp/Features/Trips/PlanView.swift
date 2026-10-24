import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct PlanView: View {
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    var body: some View {
        let upcoming = trips.filter { !$0.isCompleted() }
        let completed = trips.filter { $0.isCompleted() }.reversed()
        List {
            if trips.isEmpty {
                ContentUnavailableView("No trips yet", systemImage: "calendar.badge.plus", description: Text("After you reserve a campsite, tap Trip below to add the booking and we’ll prepare your checklists."))
            }
            if !upcoming.isEmpty { Section("Upcoming & current") { ForEach(upcoming) { TripRow(trip: $0) } } }
            if !completed.isEmpty { Section("Completed trips") { ForEach(Array(completed)) { TripRow(trip: $0) } } }
            Section { NavigationLink { SavedCampgroundsView() } label: { Label("Your campgrounds", systemImage: "bookmark") } }
        }
        .navigationTitle("Plan")
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
