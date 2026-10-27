import SwiftUI
import SwiftData
import CampPersistence

@main
struct RoamReadyApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @State private var library = LibraryController()
    @State private var connectivity = Connectivity()
    @State private var campFinder = CampFinder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = library.container {
                    RootView().modelContainer(container)
                } else if let failure = library.openFailure {
                    ContentUnavailableView {
                        Label("Your saved data needs attention", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(failure) } actions: {
                        Button("Try again") { library.open() }
                    }
                } else {
                    ProgressView("Opening your trips…")
                }
            }
            .environment(library)
            .environment(connectivity)
            .environment(campFinder)
            .tint(.blue)
            .preferredColorScheme(appearance.colorScheme)
            // No accounts: the library belongs to this device and its iCloud account, and opens offline.
            .task { library.open() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { library.save() }
            }
        }
    }
}

struct RootView: View {
    @Environment(LibraryController.self) private var library
    @Query private var profiles: [CamperProfile]
    var body: some View {
        Group {
            #if DEBUG
            if CampingAssistant.isRunningAssistantUITests { MainTabs() }
            else { profileContent }
            #else
            profileContent
            #endif
        }
        .alert("Couldn’t save changes", isPresented: Binding(get: { library.saveFailure != nil }, set: { _ in })) {
            Button("Retry") { library.save() }
        } message: { Text(library.saveFailure ?? "") }
    }

    @ViewBuilder private var profileContent: some View {
        if profiles.isEmpty { OnboardingView() } else { MainTabs() }
    }
}

struct MainTabs: View {
    enum Destination: Hashable { case home, plan, campFinder, newTrip, profile }
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAssistant = CampingAssistant.showsGlobalChat
    @State private var selection = Destination.home
    @State private var addingTrip = false
    @State private var askingAssistant = false
    @State private var assistantConversation = AssistantConversation()
    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house", value: .home) { NavigationStack { HomeView() } }
            Tab("Plan", systemImage: "calendar", value: .plan) { NavigationStack { PlanView() } }
            // The one place to add a trip, from anywhere in the app. It opens a sheet rather than a screen.
            Tab("Trip", systemImage: "plus", value: .newTrip) { Color.clear }
            Tab("Camp Finder", systemImage: "map", value: .campFinder) { NavigationStack { CampFinderView() } }
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) { NavigationStack { ProfileView() } }
        }
        // iPhone shows five tabs at most, so Assistant lives in the bar above them instead of a sixth tab.
        .tabViewBottomAccessory(isEnabled: showsAssistant) {
            Button { askingAssistant = true } label: {
                Label("Ask Assistant", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("openAssistant")
        }
        .environment(\.mainTabActions, tabActions)
        .sheet(isPresented: $addingTrip) { NewTripView() }
        .sheet(isPresented: $askingAssistant) { AssistantView(chat: assistantConversation) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { showsAssistant = CampingAssistant.showsGlobalChat }
        }
    }
    private var tabActions: MainTabActions {
        MainTabActions(addTrip: { addingTrip = true }, showCampFinder: { selection = .campFinder })
    }
    /// Choosing Trip presents the new-trip sheet and leaves the current tab selected.
    private var tabSelection: Binding<Destination> {
        Binding(get: { selection }, set: { destination in
            if destination == .newTrip { addingTrip = true } else { selection = destination }
        })
    }
}

/// Tab-level actions for empty states, so they offer a button rather than pointing at the tab bar.
struct MainTabActions {
    var addTrip: @MainActor () -> Void = {}
    var showCampFinder: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    @Entry var mainTabActions = MainTabActions()
}

enum CampUIError: LocalizedError {
    case missingRig, unreadablePhoto
    var errorDescription: String? {
        switch self {
        case .missingRig: "Add a rig in Profile before adding a trip."
        case .unreadablePhoto: "This photo couldn’t be opened. If it’s stored in iCloud Photos, download it while online and try again."
        }
    }
}
