import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct HomeView: View {
    @Environment(\.mainTabActions) private var tabActions
    @Environment(AppPermissions.self) private var permissions
    let weather: LocalWeather
    @Query private var profiles: [CamperProfile]
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    let now: Date
    let selection: HomeDestination?
    let openDestination: (HomeDestination) -> Void
    private var currentTrip: Trip? { trips.first { $0.isActive(asOf: now) } }
    /// Trips whose arrival day is still ahead, soonest first.
    private var upcomingTrips: [Trip] { trips.filter { $0.daysUntilArrival(asOf: now) != nil } }
    private var otherTrips: [Trip] {
        let featured = trips.featuredTrip(asOf: now)
        return trips.filter { !$0.isCompleted(asOf: now) && $0.persistentModelID != featured?.persistentModelID }
    }

    var body: some View {
        // Highlight follows navigation. SwiftUI's selection reconciliation must not navigate:
        // it can echo an old row or clear selection while the detail stack is pushing a page.
        List(selection: .constant(selection)) { sections }
        .accessibilityIdentifier("homeTripList")
        .listSectionSpacing(.compact)
        .navigationTitle("Home")
    }

    @ViewBuilder private var sections: some View {
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
                tripLink(trip) {
                    HomeTripHeader(trip: trip)
                }
                .accessibilityIdentifier("tripRow-\(trip.campgroundName)")
                ForEach(ChecklistPhase.allCases) { phase in
                    checklistLink(trip, phase) {
                        HomeChecklistSummary(phase: phase, steps: trip.steps(phase))
                    }
                    .accessibilityIdentifier("homeChecklist-\(phase.rawValue)")
                }
                menuLink(trip)
                destinationButton(.memories(trip.persistentModelID)) { Label("Photos & site notes", systemImage: "photo.on.rectangle") }
                    .accessibilityIdentifier("homeMemories")
            } header: { Text("Current trip") }
        } else if let next = upcomingTrips.first, let days = next.daysUntilArrival(asOf: now) {
            Section {
                tripLink(next) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(days == 1 ? "Starts tomorrow" : "Starts in \(days) days")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(.tint.opacity(0.12), in: .capsule)
                        HomeTripHeader(trip: next)
                    }.padding(.vertical, 6)
                }
                .accessibilityIdentifier("tripRow-\(next.campgroundName)")
                checklistLink(next, .setup) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Review setup checklist").font(.headline)
                        ProgressSummary(steps: next.steps(.setup))
                    }.padding(.vertical, 4)
                }
                menuLink(next)
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
            Section("Later trips") {
                ForEach(otherTrips) { trip in
                    tripLink(trip) { TripRowLabel(trip: trip) }
                        .accessibilityIdentifier("tripRow-\(trip.campgroundName)")
                }
            }
        }
        if permissions.locationAllowed, let conditions = weather.conditions {
            Section {
                WeatherAttribution(legalURL: conditions.attributionURL, lightMarkURL: conditions.lightMarkURL,
                                   darkMarkURL: conditions.darkMarkURL)
            } footer: {
                Text("Weather near you · Updated \(conditions.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                if let failure = weather.failure { Text(failure) }
            }
        }
    }

    private func tripLink<Label: View>(_ trip: Trip, @ViewBuilder label: () -> Label) -> some View {
        destinationButton(.trip(trip.persistentModelID), label: label)
    }

    private func menuLink(_ trip: Trip) -> some View {
        destinationButton(.menu(trip.persistentModelID)) { MenuEntryLabel(summary: trip.menuSummary) }
            .accessibilityIdentifier("homeMenu")
    }

    private func checklistLink<Label: View>(_ trip: Trip, _ phase: ChecklistPhase,
                                           @ViewBuilder label: () -> Label) -> some View {
        destinationButton(.checklist(trip.persistentModelID, phase), label: label)
    }

    /// A selected row must still perform its action, including clearing the trip's pushed pages.
    private func destinationButton<Label: View>(_ destination: HomeDestination, @ViewBuilder label: () -> Label) -> some View {
        Button { openDestination(destination) } label: {
            HStack {
                label()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .tag(destination)
    }
}
