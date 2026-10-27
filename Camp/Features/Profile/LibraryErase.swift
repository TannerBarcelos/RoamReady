import Foundation
import CloudKit

/// "Erase all data": the app has no accounts, so this is the full deletion path. It deletes the
/// app's iCloud data first, then everything on this device; each step must succeed before the next.
/// A failure names the step and stops, so a half-erased library never looks finished.
@MainActor
enum LibraryErase {
    enum Step: String, Sendable {
        case iCloud = "Deleting your iCloud data"
        case device = "Erasing this device"
    }

    struct Failure: LocalizedError {
        let step: Step
        let reason: String
        var errorDescription: String? {
            switch step {
            case .iCloud: "Nothing was erased. Your iCloud data couldn’t be deleted. \(reason)"
            case .device: "Your iCloud data was deleted, but this device couldn’t be fully erased. \(reason) Try again, or delete the app."
            }
        }
    }

    static func run(library: LibraryController, progress: (Step) -> Void) async throws {
        progress(.iCloud)
        if let containerIdentifier = library.iCloud.containerIdentifier {
            do { try await deleteCloudData(containerIdentifier: containerIdentifier) }
            catch let failure as Failure { throw failure }
            catch { throw Failure(step: .iCloud, reason: error.localizedDescription) }
        }
        progress(.device)
        do { try await library.eraseDevice() } catch { throw Failure(step: .device, reason: error.localizedDescription) }
    }

    /// SwiftData's CloudKit mirroring keeps everything in one private zone; deleting it removes the
    /// app's iCloud data. Other devices see the zone disappear and stop syncing; their local copy stays.
    private static func deleteCloudData(containerIdentifier: String) async throws {
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else {
            throw Failure(step: .iCloud, reason: "Sign in to iCloud on this device, then try again.")
        }
        let zone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        do { _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zone) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone { /* Already gone. */ }
        catch let error as CKError where error.code == .networkUnavailable || error.code == .networkFailure {
            throw Failure(step: .iCloud, reason: "Erasing your iCloud data needs a connection.")
        }
    }
}
