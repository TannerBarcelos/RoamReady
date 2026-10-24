import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [CamperProfile]
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    @State private var now = Date()
    private var currentTrip: Trip? { trips.first { $0.isActive(asOf: now) } }

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
            if let trip = currentTrip {
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
                } header: { Text("Current trip") }
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
                    Label("No current trip", systemImage: "tent.2")
                } description: {
                    Text("Your trip appears here from arrival through departure day. Find upcoming and past trips in Plan, or tap Trip below to add your next adventure.")
                }
            }
        }
        .navigationTitle("Home")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CurrentWeatherBadge() } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Refresh on return to the app and at the next campground midnight, even if Home
            // stays open. The one-minute cap also picks up clock/time-zone and trip-date edits.
            while !Task.isCancelled {
                now = Date()
                let midnight = trips.compactMap { trip in
                    trip.campgroundCalendar.date(byAdding: .day, value: 1,
                                                to: trip.campgroundCalendar.startOfDay(for: now))
                }.min()
                let delay = max(0.1, min(60, midnight?.timeIntervalSince(now) ?? 60))
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }
}
