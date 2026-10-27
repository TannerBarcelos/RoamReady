import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mainTabActions) private var tabActions
    @Query private var profiles: [CamperProfile]
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    @State private var now = Date()
    private var currentTrip: Trip? { trips.first { $0.isActive(asOf: now) } }
    /// Trips whose arrival day is still ahead, soonest first.
    private var upcomingTrips: [Trip] { trips.filter { $0.daysUntilArrival(asOf: now) != nil } }
    private var otherTrips: [Trip] {
        let featured = currentTrip ?? upcomingTrips.first
        return trips.filter { !$0.isCompleted(asOf: now) && $0.persistentModelID != featured?.persistentModelID }
    }

    var body: some View {
        List {
            if let profile = profiles.first {
                Section {
                    HStack(spacing: 16) {
                        if let rig = rigs.active.first { RigImage(rig: rig, size: 48) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name.isEmpty ? "Welcome back" : "Hello, \(profile.name)").font(.headline)
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
            } else if let next = upcomingTrips.first, let days = next.daysUntilArrival(asOf: now) {
                Section {
                    NavigationLink { TripDetailView(trip: next) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(days == 1 ? "Starts tomorrow" : "Starts in \(days) days")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(.tint.opacity(0.12), in: .capsule)
                            Text(next.campgroundName).font(.title2.bold())
                            Text(next.dateSummary).font(.subheadline).foregroundStyle(.secondary)
                            if !next.siteNumber.isEmpty { Label("Site \(next.siteNumber)", systemImage: "mappin").font(.subheadline) }
                        }.padding(.vertical, 6)
                    }
                    NavigationLink { ChecklistView(trip: next) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Review setup checklist").font(.headline)
                            ProgressSummary(steps: next.steps(.setup))
                        }.padding(.vertical, 4)
                    }
                } header: { Text("Next trip") } footer: {
                    Text("On arrival day, Home switches to your live trip with checklist progress and photos.")
                }
            } else {
                Section(trips.isEmpty ? "Your first trip" : "Your next trip") {
                    Button("Add a trip", systemImage: "calendar.badge.plus", action: tabActions.addTrip)
                    Button("Find a campground", systemImage: "map", action: tabActions.showCampFinder)
                }
            }
            if !otherTrips.isEmpty {
                Section(currentTrip == nil ? "Later" : "More trips") {
                    ForEach(otherTrips) { TripRow(trip: $0) }
                }
            }
        }
        .listSectionSpacing(.compact)
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
