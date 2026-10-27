import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct TripHistoryView: View {
    @Query(sort: \Trip.arrival, order: .reverse) private var trips: [Trip]
    var body: some View {
        let completed = trips.filter { $0.isCompleted() }
        List {
            if completed.isEmpty {
                ContentUnavailableView("No completed trips yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Your completed trips appear here with their photos, site notes, and checklists."))
            } else {
                ForEach(completed) { TripRow(trip: $0) }
            }
        }
        .navigationTitle("Trip history")
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
