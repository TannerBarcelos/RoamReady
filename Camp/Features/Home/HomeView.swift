import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct HomeView: View {
    @Query private var profiles: [CamperProfile]
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    @State private var planning = false
    /// The next trip that isn't over, or else the most recent one.
    private var featured: Trip? { trips.first { !$0.isCompleted() } ?? trips.last }

    var body: some View {
        List {
            if let profile = profiles.first {
                Section {
                    HStack(spacing: 16) {
                        if let rig = rigs.active.first { RigImage(rig: rig) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name.isEmpty ? "Welcome back" : "Hello, \(profile.name)").font(.title3.bold())
                            if let rig = rigs.active.first { Text(rig.displayName).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let trip = featured {
                Section {
                    NavigationLink { TripDetailView(trip: trip) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(trip.campgroundName).font(.title2.bold())
                            Text(trip.dateSummary).font(.subheadline).foregroundStyle(.secondary)
                            if !trip.siteNumber.isEmpty { Label("Site \(trip.siteNumber)", systemImage: "mappin").font(.subheadline) }
                            SaveStatus()
                        }.padding(.vertical, 6)
                    }
                    NavigationLink { ChecklistView(trip: trip) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Continue setup").font(.headline)
                            ProgressSummary(steps: trip.steps(.setup))
                        }.padding(.vertical, 4)
                    }
                } header: { Text(trip.isCompleted() ? "Latest trip" : "Your next adventure") }
                Section("Your trip") {
                    ForEach(ChecklistPhase.allCases) { phase in
                        NavigationLink { ChecklistView(trip: trip, initialPhase: phase) } label: {
                            let steps = trip.steps(phase)
                            Label("\(phase.title) checklist", systemImage: "checklist")
                            Spacer(); Text("\(steps.filter(\.isFinished).count) / \(steps.count)").foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink { MemoriesView(trip: trip) } label: { Label("Photos & site notes", systemImage: "photo.on.rectangle") }
                }
            } else {
                ContentUnavailableView {
                    Label("Your next adventure starts here", systemImage: "tent.2")
                } description: {
                    Text("Booked a campsite? Add the trip and your setup and teardown checklists will be ready automatically.")
                } actions: { Button("Add a trip") { planning = true }.buttonStyle(.borderedProminent) }
            }
            Section("Next trip") { Button("Add a trip", systemImage: "plus") { planning = true } }
        }
        .navigationTitle("Home")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CurrentWeatherBadge() } }
        .sheet(isPresented: $planning) { NewTripView() }
    }
}
