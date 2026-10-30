import SwiftUI
import SwiftData
import CampCore
import CampPersistence

/// What Home shows beside itself on Duo. Values, not model references, so the workspace can
/// keep them while the display folds and gain destinations without holding stale models.
enum HomeDestination: Hashable {
    case trip(PersistentIdentifier)
    case checklist(PersistentIdentifier, ChecklistPhase)

    var tripID: PersistentIdentifier {
        switch self { case .trip(let id), .checklist(let id, _): id }
    }
}

/// Home's root. It owns Home's clock and, on Duo, the split view's selection, so both outlive
/// the columns as the display changes size. Other iPhones get Home alone in `MainTabs`' stack.
struct HomeWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.usesDuoWorkspace) private var usesDuoWorkspace
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    @State private var now = Date()
    @State private var selection: HomeDestination?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        Group {
            if usesDuoWorkspace {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    HomeView(now: now, selection: listSelection)
                        .assistantToolbarItem()
                } detail: {
                    detail
                }
                #if DEBUG
                // The cover display collapses the detail, so UI tests read what it would show.
                .overlay(alignment: .topLeading) {
                    if DuoWorkspace.exposesUITestMarker {
                        Color.clear.frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityLabel(shownTrip?.campgroundName ?? "None")
                            .accessibilityIdentifier("homeDetailTrip")
                            .allowsHitTesting(false)
                        Color.clear.frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityLabel(shownChecklist?.title ?? "None")
                            .accessibilityIdentifier("homeDetailChecklist")
                            .allowsHitTesting(false)
                    }
                }
                #endif
            } else {
                HomeView(now: now)
            }
        }
        // A deleted trip takes its pick with it, so the detail falls back to the featured trip.
        .onChange(of: trips.map(\.persistentModelID)) { _, ids in
            if let id = selection?.tripID, !ids.contains(id) { selection = nil }
        }
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

    /// The pick, while its trip is still in the library.
    private var validSelection: HomeDestination? {
        selection.flatMap { pick in trips.contains { $0.persistentModelID == pick.tripID } ? pick : nil }
    }

    private var shownTrip: Trip? { trips.displayedTrip(selected: validSelection?.tripID, asOf: now) }

    private var shownChecklist: ChecklistPhase? {
        if case .checklist(_, let phase)? = validSelection { phase } else { nil }
    }

    /// Side by side, the featured trip is highlighted until the owner picks another. Collapsed,
    /// only a pick counts, so Home stays in front until a trip is tapped.
    private var listSelection: Binding<HomeDestination?> {
        Binding(get: {
            horizontalSizeClass == .compact ? validSelection
                : validSelection ?? shownTrip.map { .trip($0.persistentModelID) }
        }, set: { selection = $0 })
    }

    @ViewBuilder private var detail: some View {
        if let trip = shownTrip {
            // A new pick starts a fresh stack rather than keeping the last pick's pushed screens.
            NavigationStack {
                if let phase = shownChecklist {
                    ChecklistView(trip: trip, initialPhase: phase)
                } else {
                    TripDetailView(trip: trip)
                }
            }
            .id(validSelection ?? .trip(trip.persistentModelID))
        } else {
            ContentUnavailableView("No trip to show", systemImage: "tent",
                                   description: Text("Your current or next trip appears here."))
                .accessibilityIdentifier("homeDetailEmpty")
        }
    }
}
