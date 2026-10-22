import Foundation
import AuthenticationServices
import CryptoKit
import Observation
import Security

/// Device-local authentication using Apple's native authorization result.
/// This is not a server session: no backend token verification/account service exists yet.
@MainActor @Observable
final class AccountSession {
    private(set) var signedIn = false
    private(set) var displayName = ""
    private(set) var email = ""
    private(set) var failure: String?
    private(set) var startupFailure: String?
    private(set) var needsLegacyAdoption = false
    private(set) var checking = false
    @ObservationIgnored private var credential: LocalCredential?
    @ObservationIgnored private var pending: LocalCredential?
    @ObservationIgnored private var expectedState: String?
    @ObservationIgnored private var authRevision = 0
    @ObservationIgnored private let ownerURL = URL.applicationSupportDirectory
        .appendingPathComponent("RoamReadyAccount", isDirectory: true).appendingPathComponent("owner.json")

    var canAccessLibrary: Bool { signedIn && startupFailure == nil }
    var hasPinnedAccount: Bool { credential != nil || FileManager.default.fileExists(atPath: ownerURL.path) }

    init() {
        do {
            credential = try AccountKeychain.read()
            if let credential {
                if let owner = try readOwner(), owner != credential.userID { throw AccountError.identityMismatch }
                signedIn = credential.signedIn
                displayName = credential.name
                email = credential.email
            }
        } catch {
            startupFailure = "Your account credentials could not be opened. Your camping library has not been changed. \(error.localizedDescription)"
        }
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        failure = nil
        let state = UUID().uuidString
        expectedState = state
        request.state = state
        request.nonce = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        request.requestedScopes = [.fullName, .email]
    }

    func complete(_ result: Result<ASAuthorization, Error>, online: Bool) {
        defer { expectedState = nil }
        guard online else { failure = "Reconnect to finish signing in. Your saved trips have not changed."; return }
        do {
            let authorization = try result.get()
            guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                  !apple.user.isEmpty, let expectedState, apple.state == expectedState,
                  apple.identityToken != nil, apple.authorizationCode != nil else { throw AccountError.invalidCredential }
            let pinned = try readOwner() ?? credential?.userID
            if let pinned, pinned != apple.user { throw AccountError.identityMismatch }
            let name = apple.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? credential?.name ?? ""
            let record = LocalCredential(userID: apple.user, name: name, email: apple.email ?? credential?.email ?? "", signedIn: true)
            if pinned == nil && existingLibraryHasFiles {
                pending = record
                needsLegacyAdoption = true
            } else {
                try establish(record)
            }
        } catch {
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            failure = error.localizedDescription
        }
    }

    func adoptLegacyLibrary(online: Bool) {
        guard online, let pending else { return }
        do { try establish(pending); self.pending = nil; needsLegacyAdoption = false }
        catch { failure = error.localizedDescription }
    }
    func cancelAdoption() { pending = nil; needsLegacyAdoption = false }

    func signOut(online: Bool) {
        guard online else { failure = "Connect to the internet to change your account."; return }
        guard var record = credential else { return }
        do {
            record.signedIn = false
            try AccountKeychain.write(record)
            authRevision += 1
            credential = record
            signedIn = false
        } catch { failure = error.localizedDescription }
    }

    func verifyWhenOnline(_ online: Bool) async {
        guard online, signedIn, !checking, let credential else { return }
        let revision = authRevision
        checking = true
        defer { checking = false }
        let state: Verification = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: credential.userID) { state, error in
                guard error == nil else { continuation.resume(returning: .unreachable); return }
                switch state {
                case .authorized: continuation.resume(returning: .authorized)
                case .revoked, .notFound, .transferred: continuation.resume(returning: .revoked)
                @unknown default: continuation.resume(returning: .unreachable)
                }
            }
        }
        guard revision == authRevision, signedIn, self.credential?.userID == credential.userID else { return }
        // Transient errors never strand an established camper offline.
        if state == .revoked {
            var record = credential
            record.signedIn = false
            do { try AccountKeychain.write(record); self.credential = record }
            catch { failure = "Apple revoked access; the local sign-in marker could not be updated. \(error.localizedDescription)" }
            signedIn = false
            failure = "Sign in with the same Apple Account to reopen your saved library. Your trips are still on this device."
        }
    }

    /// Whether `userID` is the Apple user this device's library belongs to.
    func isOwner(_ userID: String) -> Bool {
        let pinned = (try? readOwner()) ?? credential?.userID
        return pinned == userID
    }

    /// Last step of account deletion: forget the owner on this device and return to sign-in.
    func eraseLocalAccount() throws {
        try AccountKeychain.delete()
        if FileManager.default.fileExists(atPath: ownerURL.deletingLastPathComponent().path) {
            try FileManager.default.removeItem(at: ownerURL.deletingLastPathComponent())
        }
        authRevision += 1
        credential = nil; pending = nil
        signedIn = false; displayName = ""; email = ""
        failure = nil; startupFailure = nil; needsLegacyAdoption = false
    }

    private func establish(_ record: LocalCredential) throws {
        try FileManager.default.createDirectory(at: ownerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record.userID).write(to: ownerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try AccountKeychain.write(record)
        authRevision += 1
        credential = record
        displayName = record.name; email = record.email
        startupFailure = nil; failure = nil; signedIn = true
    }
    private func readOwner() throws -> String? {
        guard FileManager.default.fileExists(atPath: ownerURL.path) else { return nil }
        return try JSONDecoder().decode(String.self, from: Data(contentsOf: ownerURL))
    }
    private var existingLibraryHasFiles: Bool {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Camp", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty == false
    }
    private enum Verification: Sendable { case authorized, revoked, unreachable }
}

private struct LocalCredential: Codable {
    var userID: String
    var name: String
    var email: String
    var signedIn: Bool
}

private enum AccountError: LocalizedError {
    case invalidCredential, identityMismatch, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Apple did not return a valid sign-in credential. Please try again."
        case .identityMismatch: "This device’s camping library belongs to a different Apple Account. Sign in with its original account. Account switching is not available in this build; no camping data was changed."
        case .keychain(let status): "Secure account storage is unavailable (\(status)). Unlock this device and try again."
        }
    }
}

private enum AccountKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "RoamReady") + ".apple-identity",
         kSecAttrAccount as String: "local-library-owner"]
    }
    static func read() throws -> LocalCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AccountError.keychain(status) }
        return try JSONDecoder().decode(LocalCredential.self, from: data)
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain(status) }
    }
    static func write(_ record: LocalCredential) throws {
        let data = try JSONEncoder().encode(record)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw AccountError.keychain(added) }
        } else if status != errSecSuccess { throw AccountError.keychain(status) }
    }
}
