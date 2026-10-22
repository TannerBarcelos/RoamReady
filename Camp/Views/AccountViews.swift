import SwiftUI
import AuthenticationServices

struct AccountWelcomeView: View {
    @Environment(AccountSession.self) private var account
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(systemName: "tent.2").font(.system(size: 44)).foregroundStyle(.blue)
                    Text(account.hasPinnedAccount ? "Welcome back" : "Your next adventure starts here").font(.largeTitle.bold())
                    Text("Create your account and set up your rig while online. Then your planned trips, checklists, photos, and notes travel with you—even without reception.")
                }
                Section {
                    if connectivity.isOnline {
                        SignInWithAppleButton(account.hasPinnedAccount ? .signIn : .signUp) { request in
                            account.prepare(request)
                        } onCompletion: { result in
                            account.complete(result, online: connectivity.isOnline)
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                    } else {
                        Label("Connect to finish account setup", systemImage: "wifi.slash")
                        Text("Downloading the app does not complete onboarding. Connect to Wi-Fi or cellular data before your first trip.").foregroundStyle(.secondary)
                    }
                    if let failure = account.failure ?? account.startupFailure { Text(failure).foregroundStyle(.red) }
                } footer: {
                    Text("Sign in once online. Your saved trips remain available offline while you stay signed in.")
                }
                if account.hasPinnedAccount {
                    Section { Text("Use the Apple Account originally linked to this library. Signing out does not delete trips or permit a different account to open them.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("RoamReady")
            .confirmationDialog("Link the existing library on this device?", isPresented: Binding(
                get: { account.needsLegacyAdoption }, set: { if !$0 { account.cancelAdoption() } }
            ), titleVisibility: .visible) {
                Button("Link my existing library") { account.adoptLegacyLibrary(online: connectivity.isOnline) }
                Button("Cancel", role: .cancel) { account.cancelAdoption() }
            } message: {
                Text("This device has camping data from an earlier build without accounts. Confirm it is yours before linking it permanently to this Apple Account. Nothing will be deleted.")
            }
        }
    }
}

struct AccountSettingsView: View {
    @Environment(AccountSession.self) private var account
    @Environment(Connectivity.self) private var connectivity
    @Environment(CampStore.self) private var store
    @State private var signingOut = false
    @State private var signOutFailure: String?
    @State private var preparingSignOut = false
    var body: some View {
        OnlineFeatureGate(feature: "Account changes") {
            List {
                Section("Apple Account") {
                    Label("Signed in with Apple", systemImage: "person.crop.circle.badge.checkmark")
                    if !account.displayName.isEmpty { LabeledContent("Name", value: account.displayName) }
                    if !account.email.isEmpty { LabeledContent("Email", value: account.email) }
                    Text("Your library remains available offline while you stay signed in. Apple supplies your name and email only when you first grant access.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign out", role: .destructive) { signingOut = true }
                        .disabled(preparingSignOut || store.isSaving || store.saveFailure != nil)
                    if store.saveFailure != nil { Text("Save your latest changes before signing out.").foregroundStyle(.secondary) }
                    if let signOutFailure { Text(signOutFailure).foregroundStyle(.red) }
                    if let failure = account.failure { Text(failure).foregroundStyle(.red) }
                } footer: {
                    Text("Signing out locks this device’s library and keeps its data. Reopening it requires an internet connection and the same Apple Account.")
                }
                Section {
                    if AccountDeletion.isAvailable {
                        NavigationLink { DeleteAccountView() } label: {
                            Label("Delete account", systemImage: "person.crop.circle.badge.xmark").foregroundStyle(.red)
                        }
                    } else {
                        Text("Account deletion isn’t available in this development build. Signing out does not delete local or iCloud data.")
                    }
                } header: { Text("Account removal") }
            }
        }
        .navigationTitle("Account")
        .confirmationDialog("Sign out and lock your saved library?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    preparingSignOut = true
                    defer { preparingSignOut = false }
                    await store.flushForBackground()
                    guard store.saveFailure == nil, !store.isSaving else {
                        signOutFailure = "Your latest changes need saving. Retry saving before signing out."
                        return
                    }
                    account.signOut(online: connectivity.isOnline)
                }
            }
        }
    }
}

/// Delete account (#12). Explicit about what is erased, confirmed with a fresh Sign in with Apple,
/// and blocked offline. Reports the exact step that failed instead of claiming success.
struct DeleteAccountView: View {
    @Environment(AccountSession.self) private var account
    @Environment(Connectivity.self) private var connectivity
    @Environment(CampStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var understood = false
    @State private var step: AccountDeletion.Step?
    @State private var failure: String?
    @State private var expectedState: String?
    var body: some View {
        Form {
            Section {
                Text("Deleting your account permanently erases:").font(.headline)
                ForEach(Self.erased, id: \.self) { Label($0, systemImage: "trash").font(.subheadline) }
            } footer: {
                Text("Export your library first from Profile if you want a copy. Original photos in your photo library are not touched. Other iPhones and iPads signed in to the same iCloud account stop syncing and keep what they already have until you delete the app there.")
            }
            Section {
                Toggle("I understand this can’t be undone", isOn: $understood)
            }
            Section {
                if !connectivity.isOnline {
                    Label("Deleting your account needs a connection", systemImage: "wifi.slash")
                } else if let step {
                    ProgressView(step.rawValue + "…")
                } else {
                    SignInWithAppleButton(.continue) { request in
                        let state = UUID().uuidString
                        expectedState = state
                        request.state = state
                        request.requestedScopes = []
                    } onCompletion: { result in
                        let decided = outcome(of: result)
                        Task { await delete(decided) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 50)
                    .disabled(!understood)
                    .opacity(understood ? 1 : 0.4)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            } header: { Text("Confirm with Apple") } footer: {
                Text("Apple asks you to confirm. RoamReady then revokes its Sign in with Apple access, deletes your iCloud data, and erases this iPhone, in that order.")
            }
        }
        .navigationTitle("Delete account")
        .interactiveDismissDisabled(step != nil)
    }

    static let erased = [
        "Your trips, bookings, checklists, and their progress",
        "Notes and every saved note version, site notes, and ratings",
        "Trip and rig photos saved in RoamReady",
        "Your rigs, their default checklists, and all documents",
        "Saved campgrounds, cached forecasts, and settings",
        "Your iCloud copy, and RoamReady’s Sign in with Apple access",
    ]

    private enum Outcome: Sendable { case confirmed(AccountDeletion.Confirmation), cancelled, failed }

    /// Runs synchronously in the completion handler, so the non-Sendable credential never crosses a task.
    private func outcome(of result: Result<ASAuthorization, Error>) -> Outcome {
        switch result {
        case .failure(let error):
            return (error as? ASAuthorizationError)?.code == .canceled ? .cancelled : .failed
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let expectedState, credential.state == expectedState,
                  let confirmation = AccountDeletion.Confirmation(credential) else { return .failed }
            return .confirmed(confirmation)
        }
    }

    private func delete(_ outcome: Outcome) async {
        defer { expectedState = nil }
        failure = nil
        guard connectivity.isOnline else { failure = "Deleting your account needs a connection."; return }
        switch outcome {
        case .cancelled: return
        case .failed: failure = "Apple couldn’t confirm your account. Nothing was deleted."
        case .confirmed(let confirmation):
            await store.flushForBackground()
            do {
                try await AccountDeletion.run(confirmation, account: account, store: store) { step = $0 }
            } catch {
                failure = error.localizedDescription
            }
            step = nil
        }
    }
}
