import Foundation
import AuthenticationServices
import CloudKit

/// Deletes the account (#12), in an order that never leaves a half-deleted account looking finished:
/// 1. revoke Sign in with Apple through RoamReady's Worker,
/// 2. delete the app's iCloud data,
/// 3. erase everything on this device.
/// Each step must succeed before the next starts; a failure names the step and stops.
@MainActor
enum AccountDeletion {
    enum Step: String, Sendable {
        case revoke = "Revoking Sign in with Apple"
        case iCloud = "Deleting your iCloud data"
        case device = "Erasing this iPhone"
    }

    struct Failure: LocalizedError {
        let step: Step
        let reason: String
        var errorDescription: String? {
            switch step {
            case .revoke: "Your account wasn’t deleted. \(reason) Nothing was changed."
            case .iCloud: "Sign in with Apple was revoked, but your iCloud data couldn’t be deleted. \(reason) Your data on this iPhone is untouched; try again to finish."
            case .device: "Your Apple sign-in and iCloud data were deleted, but this iPhone couldn’t be fully erased. \(reason) Try again, or delete the app."
            }
        }
    }

    /// The Worker's base URL, from Info.plist. Absent in builds without a deployed Worker.
    static var serviceURL: URL? {
        let value = Bundle.main.object(forInfoDictionaryKey: "RoamReadyAccountServiceURL") as? String ?? ""
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
    static var isAvailable: Bool { serviceURL != nil }

    /// What a fresh Sign in with Apple confirmation returns, taken out of the credential object.
    struct Confirmation: Sendable {
        let user: String
        let identityToken: String
        let authorizationCode: String
        init?(_ credential: ASAuthorizationAppleIDCredential) {
            guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                  let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
            user = credential.user; identityToken = token; authorizationCode = code
        }
    }

    /// `confirmation` comes from a fresh Sign in with Apple confirmation for the library's owner.
    static func run(_ confirmation: Confirmation, account: AccountSession, store: CampStore,
                    progress: (Step) -> Void) async throws {
        guard let serviceURL else { throw Failure(step: .revoke, reason: "Account deletion isn’t available in this build.") }
        let identityToken = confirmation.identityToken, authorizationCode = confirmation.authorizationCode
        guard account.isOwner(confirmation.user) else {
            throw Failure(step: .revoke, reason: "Confirm with the Apple Account that owns this library.")
        }

        progress(.revoke)
        try await revoke(serviceURL: serviceURL, identityToken: identityToken, authorizationCode: authorizationCode)

        progress(.iCloud)
        if let containerIdentifier = store.sync.containerIdentifier {
            do { try await deleteCloudData(containerIdentifier: containerIdentifier) }
            catch { throw Failure(step: .iCloud, reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }

        progress(.device)
        do {
            try await store.eraseLibrary()
            try account.eraseLocalAccount()
        } catch { throw Failure(step: .device, reason: error.localizedDescription) }
    }

    private struct ServiceError: Decodable { let error: String; let message: String? }

    private static func revoke(serviceURL: URL, identityToken: String, authorizationCode: String) async throws {
        var request = URLRequest(url: serviceURL.appendingPathComponent("v1/account/revoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["identityToken": identityToken, "authorizationCode": authorizationCode])
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure(step: .revoke, reason: "Deleting your account needs a connection.") }
        guard let http = response as? HTTPURLResponse else { throw Failure(step: .revoke, reason: "The account service didn’t respond.") }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data))?.message
            throw Failure(step: .revoke, reason: message ?? "The account service returned an error (\(http.statusCode)).")
        }
    }

    /// Core Data's CloudKit mirroring keeps everything in one private zone; deleting it removes the
    /// app's iCloud data. Other devices see the zone disappear and stop syncing; their local copy stays.
    private static func deleteCloudData(containerIdentifier: String) async throws {
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else {
            throw Failure(step: .iCloud, reason: "Sign in to iCloud on this iPhone, then try again.")
        }
        let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        do { _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone { /* Already gone. */ }
    }
}
