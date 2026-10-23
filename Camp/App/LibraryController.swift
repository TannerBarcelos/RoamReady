import Foundation
import Observation
import SwiftData
import CampPersistence

/// Opens the SwiftData library, with or without iCloud, and reopens it when sync is turned on or
/// off or the iCloud account changes. Screens read and write the library through SwiftData directly.
@MainActor @Observable
final class LibraryController {
    private(set) var container: ModelContainer?
    private(set) var openFailure: String?
    private(set) var saveFailure: String?
    let sync = CloudSyncController()
    let documentFiles = DocumentFileCache(directory: URL.cachesDirectory.appending(path: "Documents", directoryHint: .isDirectory))
    private static let directory = URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)

    func open(online: Bool) async {
        guard container == nil else { return }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let cloudKitContainer = await sync.containerForLaunch(online: online)
            container = try LibraryStore.container(at: Self.directory.appending(path: "RoamReady.store"), cloudKitContainer: cloudKitContainer)
            sync.start(syncing: cloudKitContainer != nil) { [weak self] in await self?.reopen(online: false) }
            openFailure = nil
        } catch {
            openFailure = "RoamReady couldn’t open your library. Nothing was deleted. \(error.localizedDescription)"
        }
    }

    /// Writes pending changes now. SwiftData also saves on its own; this surfaces a failure.
    func save() {
        guard let context = container?.mainContext, context.hasChanges else { return }
        do { try context.save(); saveFailure = nil }
        catch { saveFailure = "Your latest changes haven’t been saved to this iPhone. \(error.localizedDescription)" }
    }

    /// Applies the iCloud setting now. Reopening never deletes local data or the iCloud copy.
    func setCloudSync(_ enabled: Bool, online: Bool) async {
        sync.setRequested(enabled)
        await reopen(online: online)
    }

    /// Re-checks iCloud, e.g. after signing in to iCloud in Settings or reconnecting.
    func reopen(online: Bool) async {
        save()
        await close()
        await open(online: online)
    }

    /// Erase all data on this device: the library, caches, imports, and settings. The caller has
    /// already deleted the iCloud copy.
    func eraseDevice() async throws {
        await close()
        let fileManager = FileManager.default
        for location in [Self.directory, documentFiles.directory, DocumentImport.directory, WeatherStore.directory]
        where fileManager.fileExists(atPath: location.path) {
            try fileManager.removeItem(at: location)
        }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        saveFailure = nil
    }

    /// The zip export. It holds readable copies of every document, so it gets the store's protection.
    func export() throws -> URL {
        save()
        guard let context = container?.mainContext, saveFailure == nil else { throw CocoaError(.fileWriteUnknown) }
        let url = URL.temporaryDirectory.appending(path: "RoamReady Export.zip")
        try LibraryExport.write(from: context, to: url, workspace: URL.temporaryDirectory.appending(path: UUID().uuidString))
        documentFiles.protect(url)
        return url
    }

    /// Lets SwiftUI release the old container's views before another one opens the same store.
    private func close() async {
        sync.stop()
        container = nil
        try? await Task.sleep(for: .milliseconds(300))
    }
}
