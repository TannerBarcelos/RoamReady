import SwiftUI
import UIKit
import SwiftData
import CampCore
import CampPersistence

/// What Home shows in its adaptive detail column. Values, not model references, so the workspace can
/// keep them while the display folds and gain destinations without holding stale models.
enum HomeDestination: Hashable {
    case trip(PersistentIdentifier)
    case checklist(PersistentIdentifier, ChecklistPhase)
    case menu(PersistentIdentifier)

    var tripID: PersistentIdentifier {
        switch self { case .trip(let id), .checklist(let id, _), .menu(let id): id }
    }
}

/// Home owns its clock and split-view selection above the columns. The system collapses
/// navigation at compact width and expands it when the window has room, on every platform.
struct HomeWorkspace: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(Connectivity.self) private var connectivity
    @Environment(AppPermissions.self) private var permissions
    @Environment(\.openURL) private var openURL
    @Query(sort: \Trip.arrival) private var trips: [Trip]
    @State private var now = Date()
    @State private var selection: HomeDestination?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var weather = LocalWeather()
    @State private var showingWeatherPermissionHelp = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            HomeView(weather: weather, now: now, selection: listSelection)
                .assistantToolbarItem(isEnabled: horizontalSizeClass == .compact)
                .toolbar {
                    if horizontalSizeClass == .compact { weatherToolbar }
                }
        } detail: {
            detail
        }
        .alert("Location access is off", isPresented: $showingWeatherPermissionHelp) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow location access in Settings to show local weather. Approximate location is enough.")
        }
        .task(id: connectivity.isOnline) {
            await weather.load()
            await refreshWeather()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshWeather() } }
        }
        .onChange(of: permissions.locationAllowed) { _, _ in
            Task { await refreshWeather() }
        }
        #if DEBUG
        // The cover display collapses the detail, so UI tests read what it would show.
        .overlay(alignment: .topLeading) {
            if LayoutUITest.exposesMarkers {
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
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(showsMenu ? "Menu" : "None")
                    .accessibilityIdentifier("homeDetailMenu")
                    .allowsHitTesting(false)
            }
        }
        #endif
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

    @ToolbarContentBuilder private var weatherToolbar: some ToolbarContent {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .topBarTrailing) {
                CurrentWeatherBadge(weather: weather, openPermissionHelp: openWeatherPermissionHelp)
            }
            .axisBehavior(.verticalPreferred)
            .sharedBackgroundVisibility(.hidden)
        } else {
            standardWeatherToolbar
        }
        #else
        standardWeatherToolbar
        #endif
    }

    private var standardWeatherToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            CurrentWeatherBadge(weather: weather, openPermissionHelp: openWeatherPermissionHelp)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func openWeatherPermissionHelp() { showingWeatherPermissionHelp = true }

    private func refreshWeather() async {
        if permissions.locationAllowed && connectivity.isOnline { await weather.refresh() }
    }

    private enum DetailScreen: Hashable { case trip, checklist, menu }

    private struct DetailIdentity: Hashable {
        let trip: PersistentIdentifier
        let screen: DetailScreen
    }

    /// The pick, while its trip is still in the library.
    private var validSelection: HomeDestination? {
        selection.flatMap { pick in trips.contains { $0.persistentModelID == pick.tripID } ? pick : nil }
    }

    private var shownTrip: Trip? { trips.displayedTrip(selected: validSelection?.tripID, asOf: now) }

    private var shownChecklist: ChecklistPhase? {
        if case .checklist(_, let phase)? = validSelection { phase } else { nil }
    }

    private var showsMenu: Bool {
        if case .menu? = validSelection { true } else { false }
    }

    private var detailScreen: DetailScreen { shownChecklist != nil ? .checklist : showsMenu ? .menu : .trip }

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
            // A new trip, or switching between its details, checklist, and menu, starts a fresh stack;
            // switching the checklist's phase keeps it, along with anything pushed on top.
            NavigationStack {
                Group {
                    if let phase = shownChecklist {
                        ChecklistView(trip: trip, initialPhase: phase) { selection = .checklist(trip.persistentModelID, $0) }
                    } else if showsMenu {
                        TripMenuView(trip: trip)
                    } else {
                        TripDetailView(trip: trip)
                    }
                }
                .assistantToolbarItem()
                .toolbar { weatherToolbar }
            }
            .id(DetailIdentity(trip: trip.persistentModelID, screen: detailScreen))
        } else {
            NavigationStack {
                ContentUnavailableView("No trip to show", systemImage: "tent",
                                       description: Text("Your current or next trip appears here."))
                    .accessibilityIdentifier("homeDetailEmpty")
                    .assistantToolbarItem()
                    .toolbar { weatherToolbar }
            }
        }
    }
}
