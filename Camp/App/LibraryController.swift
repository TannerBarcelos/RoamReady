import Foundation
import Observation
import SwiftData
import CampPersistence

/// Opens the SwiftData library once per session. Apple manages its iCloud lifecycle.
/// Screens read and write the library through SwiftData directly.
@MainActor @Observable
final class LibraryController {
    private(set) var container: ModelContainer?
    private(set) var openFailure: String?
    private(set) var saveFailure: String?
    private(set) var iCloud = ICloudSettings(containerIdentifier: Bundle.main.object(forInfoDictionaryKey: "RoamReadyMirroringContainerIdentifier") as? String)
    let documentFiles = DocumentFileCache(directory: URL.cachesDirectory.appending(path: "Documents", directoryHint: .isDirectory))
    /// The Assistant's document search index. This controller opens it with the library, keeps it current as
    /// documents change, and erases it with everything else. It belongs to the library session, not to the
    /// Assistant sheet, so indexing continues after the sheet closes.
    let documentAssistant = DocumentAssistantIndex(directory: LibraryController.searchDirectory)
    /// Not in the library folder: the index is disposable, never synced, and excluded from backups.
    private static var searchDirectory: URL {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-document-assistant-fixture") {
            // The fixture owns a throwaway index; the real one is never touched.
            return URL.temporaryDirectory.appending(path: "DocumentAssistantFixture-Search", directoryHint: .isDirectory)
        }
        if let index = arguments.firstIndex(of: "-workflow-ui-test"), arguments.indices.contains(index + 1) {
            return directory.appending(path: "Search", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Search", directoryHint: .isDirectory)
    }
    private static var directory: URL {
        #if DEBUG
        // Each workflow test owns a real disk library; relaunch keeps it, other tests never see it.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-workflow-ui-test"),
           arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) {
            return URL.temporaryDirectory.appending(path: "WorkflowTests/\(id.uuidString)", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
    }

    func open() {
        guard container == nil else { return }
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-navigation-ui-test") {
                container = try NavigationUITestLibrary.make()
                openFailure = nil
                if let context = container?.mainContext { documentAssistant.open(context: context) }
                return
            }
            #endif
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            container = try LibraryStore.container(at: Self.directory.appending(path: "RoamReady.store"), cloudKitContainer: iCloud.containerForSession)
            #if DEBUG
            if let container { try SampleTrips.seedIfRequested(in: container) }
            #endif
            iCloud.startObserving()
            openFailure = nil
            if let container { documentAssistant.open(context: container.mainContext) }
        } catch {
            openFailure = "RoamReady couldn’t open your library. Nothing was deleted. \(error.localizedDescription)"
        }
    }

    /// Writes pending changes now. SwiftData also saves on its own; this surfaces a failure.
    func save() {
        guard let context = container?.mainContext, context.hasChanges else { return }
        do { try context.save(); saveFailure = nil; documentAssistant.scheduleSync() }
        catch { saveFailure = "Your latest changes haven’t been saved to this device. \(error.localizedDescription)" }
    }

    /// Use when the caller must not report success until the local write completes.
    func saveOrThrow() throws {
        guard let context = container?.mainContext else { throw CocoaError(.fileWriteUnknown) }
        if context.hasChanges { try context.save() }
        saveFailure = nil
        documentAssistant.scheduleSync()
    }

    /// Erase all data on this device: the library, the search index, caches, imports, and settings. The caller
    /// has already deleted the iCloud copy. The index writer is stopped first, so nothing it was doing can
    /// recreate its files after they are removed.
    func eraseDevice() async throws {
        await documentAssistant.erase()
        await close()
        let fileManager = FileManager.default
        for location in [Self.directory, Self.searchDirectory, documentFiles.directory, WeatherStore.directory]
        where fileManager.fileExists(atPath: location.path) {
            try fileManager.removeItem(at: location)
        }
        // Staged imports, the export archive, and photo previews are kept in the temporary folder.
        let temporary = fileManager.temporaryDirectory
        for name in (try? fileManager.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix("RoamReady") {
            try fileManager.removeItem(at: temporary.appending(path: name))
        }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        iCloud = ICloudSettings(containerIdentifier: iCloud.containerIdentifier)
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

    /// Used only for explicit full-library erase, never for connectivity or account changes.
    private func close() async {
        iCloud.stopObserving()
        container = nil
        try? await Task.sleep(for: .milliseconds(300))
    }
}
