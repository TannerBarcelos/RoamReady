import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct PlanView: View {
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    @Environment(\.mainTabActions) private var tabActions
    var body: some View {
        let upcoming = trips.filter { !$0.isCompleted() }
        let completed = trips.filter { $0.isCompleted() }.reversed()
        List {
            if trips.isEmpty {
                ContentUnavailableView {
                    Label { Text("No trips planned") } icon: {
                        Image(systemName: "calendar.badge.plus").foregroundStyle(.tint)
                    }
                } description: {
                    Text("Booked a campsite? Add it here to get checklists, the forecast, and a place for your photos and notes.")
                } actions: {
                    Button("Add a trip", systemImage: "plus", action: tabActions.addTrip).buttonStyle(.borderedProminent)
                    Button("Still deciding? Browse Camp Finder", action: tabActions.showCampFinder).buttonStyle(.bordered)
                }
            }
            if !upcoming.isEmpty { Section("Upcoming & current") { ForEach(upcoming) { TripRow(trip: $0) } } }
            if !completed.isEmpty { Section("Completed trips") { ForEach(Array(completed)) { TripRow(trip: $0) } } }
            Section { YourCampgroundsLink() }
        }
        .navigationTitle("Plan")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { AssistantToolbarButton() } }
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
