import SwiftUI
import MapKit
import CampCore
import Campgrounds

struct HomeView: View {
    @Environment(CampStore.self) private var store
    @State private var planning = false
    var featured: Trip? {
        store.state.trips.filter { !$0.isCompleted() }.sorted { $0.arrival < $1.arrival }.first
            ?? store.state.trips.sorted { $0.arrival > $1.arrival }.first
    }
    var body: some View {
        List {
            if let profile = store.state.profile {
                Section {
                    HStack(spacing: 16) {
                        if let rig = store.activeRig { RigImage(rig: rig) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name.isEmpty ? "Welcome back" : "Hello, \(profile.name)").font(.title3.bold())
                            if let rig = store.activeRig { Text(rig.displayName).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let trip = featured {
                Section {
                    NavigationLink { TripDetailView(tripID: trip.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(trip.campgroundName).font(.title2.bold())
                            Text(trip.dateSummary).font(.subheadline).foregroundStyle(.secondary)
                            if !trip.siteNumber.isEmpty { Label("Site \(trip.siteNumber)", systemImage: "mappin") .font(.subheadline) }
                            SaveStatus()
                        }.padding(.vertical, 6)
                    }
                    NavigationLink { ChecklistView(tripID: trip.id) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Continue setup").font(.headline)
                            ProgressSummary(items: trip.setup)
                        }.padding(.vertical, 4)
                    }
                } header: { Text(trip.isCompleted() ? "Latest trip" : "Your next adventure") }
                Section("Your trip") {
                    NavigationLink { ChecklistView(tripID: trip.id) } label: {
                        Label("Setup checklist", systemImage: "checklist")
                        Spacer(); Text("\(trip.setupFinished) / \(trip.setup.count)").foregroundStyle(.secondary)
                    }
                    NavigationLink { ChecklistView(tripID: trip.id, initialPhase: .teardown) } label: {
                        Label("Teardown checklist", systemImage: "checklist")
                        Spacer(); Text("\(trip.teardownFinished) / \(trip.teardown.count)").foregroundStyle(.secondary)
                    }
                    NavigationLink { MemoriesView(tripID: trip.id) } label: { Label("Photos & site notes", systemImage: "photo.on.rectangle") }
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
        .sheet(isPresented: $planning) { NewTripView() }
    }
}
