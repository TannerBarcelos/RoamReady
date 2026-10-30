import SwiftUI
import SwiftData
import CampPersistence

@main
struct RoamReadyApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @State private var library = LibraryController()
    @State private var connectivity = Connectivity()
    @State private var campFinder = CampFinder()
    @State private var permissions = AppPermissions()
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
            .environment(permissions)
            .tint(.blue)
            .preferredColorScheme(appearance.colorScheme)
            // No accounts: the library belongs to this device and its iCloud account, and opens offline.
            .task { library.open() }
            #if DEBUG
            .task { await DocumentSearchSmokeCheck.runIfRequested() }
            .task { await AssistantPerformanceBaseline.runIfRequested() }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permissions.checkOnLaunch() }
                if phase != .active { library.save() }
                library.documentAssistant.setActive(phase == .active)
            }
        }
    }
}

struct RootView: View {
    @Environment(LibraryController.self) private var library
    @Environment(AppPermissions.self) private var permissions
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
        .task { permissions.checkOnLaunch() }
        .alert("Couldn’t save changes", isPresented: Binding(get: { library.saveFailure != nil }, set: { _ in })) {
            Button("Retry") { library.save() }
        } message: { Text(library.saveFailure ?? "") }
    }

    @ViewBuilder private var profileContent: some View {
        if !permissions.hasCheckedOnLaunch {
            ProgressView("Checking permissions…")
        } else if profiles.isEmpty { OnboardingView() } else { MainTabs() }
    }
}

struct MainTabs: View {
    enum Destination: Hashable { case home, campFinder, newTrip, profile }
    @Environment(\.scenePhase) private var scenePhase
    // Selection, sheets, and the conversation outlive every size-class and window change.
    @State private var showsAssistant = CampingAssistant.showsChat
    @State private var selection = Destination.home
    @State private var addingTrip = false
    @State private var askingAssistant = false
    @State private var assistantConversation = AssistantConversation()
    var body: some View {
        TabView(selection: tabSelection) {
            // Home owns its adaptive navigation container on every platform.
            Tab("Home", systemImage: "house", value: .home) { tabRoot(stacked: false) { HomeWorkspace() } }
            // The one place to add a trip, from anywhere in the app. It opens a sheet rather than a screen.
            Tab("Trip", systemImage: "plus", value: .newTrip) { Color.clear }
            Tab("Camp Finder", systemImage: "map", value: .campFinder) { tabRoot(stacked: false) { CampFinderView() } }
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) { tabRoot { ProfileView() } }
        }
        .environment(\.mainTabActions, tabActions)
        .sheet(isPresented: $addingTrip) { NewTripView() }
        .sheet(isPresented: $askingAssistant) { AssistantView(chat: assistantConversation) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { showsAssistant = CampingAssistant.showsChat }
        }
    }

    private func tabRoot<Content: View>(stacked: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        stack(stacked) {
            if stacked { content().assistantToolbarItem() } else { content() }
        }
    }

    @ViewBuilder private func stack<Content: View>(_ stacked: Bool, @ViewBuilder content: () -> Content) -> some View {
        if stacked { NavigationStack(root: content) } else { content() }
    }

    private var tabActions: MainTabActions {
        var actions = MainTabActions(addTrip: { addingTrip = true }, showCampFinder: { selection = .campFinder })
        if showsAssistant { actions.askAssistant = { askingAssistant = true } }
        return actions
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
    /// Present only when Apple's runtime supports the Assistant.
    var askAssistant: (@MainActor () -> Void)?
}

extension View {
    /// The Assistant's navigation bar button, when `MainTabs` puts it there.
    func assistantToolbarItem(isEnabled: Bool = true) -> some View { modifier(AssistantToolbarItem(isEnabled: isEnabled)) }
}

private struct AssistantToolbarItem: ViewModifier {
    @Environment(\.mainTabActions) private var actions
    let isEnabled: Bool
    func body(content: Content) -> some View {
        content.toolbar {
            if isEnabled, let askAssistant = actions.askAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ask Assistant", systemImage: "sparkles") { askAssistant() }
                        .accessibilityIdentifier("openAssistant")
                }
            }
        }
    }
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
