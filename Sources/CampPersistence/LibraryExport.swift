#if canImport(SwiftData)
import Foundation
import SwiftData
import CampCore
import DocumentVault

/// Profile › Prepare export: a zip with `library.json` (profile, rigs and their defaults, trips with
/// their checklists and notes, saved campgrounds), `documents.json`, and `Documents/` holding each
/// document's verified original file. End-to-end encrypted documents are exported readable: the
/// archive is the user's own copy, outside iCloud's protection. Trip photos are shared individually.
public enum LibraryExport {
    public struct Summary: Equatable, Sendable {
        public let included: Int
        public let linkOnly: Int
        public let notDownloaded: Int
    }

    /// Writes the archive to `archiveURL`, using `workspace` for the files being zipped.
    @discardableResult
    public static func write(from context: ModelContext, to archiveURL: URL, workspace: URL) throws -> Summary {
        let root = workspace.appending(path: "RoamReady Export", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: root.appending(path: "Documents"), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601

        let library = Library(
            profile: try context.profile().map { Library.Profile(name: $0.name, experience: $0.experience) },
            rigs: try context.rigs().map { Library.RigEntry(details: $0.draft, archivedAt: $0.archivedAt, defaults: $0.defaultTemplate) },
            trips: try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.arrival)])).map { trip in
                Library.TripEntry(details: TripDraft(trip), rig: trip.rig?.displayName, notes: trip.notes, rating: trip.rating,
                                  setup: trip.steps(.setup).map(\.draft), teardown: trip.steps(.teardown).map(\.draft),
                                  photoCaptions: trip.sortedPhotos.map(\.caption))
            },
            savedCampgrounds: try context.fetch(FetchDescriptor<SavedCampground>(sortBy: [SortDescriptor(\.campgroundID)])).map {
                Library.Saved(campgroundID: $0.campgroundID, name: $0.name, region: $0.region,
                              wantToGo: $0.wantToGo, favorite: $0.favorite, beenTo: $0.beenTo)
            })
        try encoder.encode(library).write(to: root.appending(path: "library.json"), options: .atomic)

        var entries: [Entry] = []
        for document in try context.fetch(FetchDescriptor<StoredDocument>(sortBy: [SortDescriptor(\.createdAt)])) {
            var status = Entry.Status.linkOnly, path: String?
            if let file = document.file {
                if let bytes = try? document.contents() {
                    let relative = "Documents/\(document.documentID.uuidString.prefix(8)) \(file.filename)"
                    try bytes.write(to: root.appending(path: relative), options: .atomic)
                    status = .included; path = relative
                } else { status = .notDownloaded }
            }
            entries.append(Entry(owner: document.rig.map { "rig: \($0.displayName)" } ?? document.trip.map { "trip: \($0.campgroundName)" },
                                 title: document.title, category: document.categoryValue, notes: document.notes,
                                 issuedOn: document.issuedOn, expiresOn: document.expiresOn, link: document.link,
                                 protection: document.protectionValue, file: document.file, createdAt: document.createdAt,
                                 status: status, path: path))
        }
        try encoder.encode(Manifest(documents: entries)).write(to: root.appending(path: "documents.json"), options: .atomic)
        try zip(root, to: archiveURL)
        return Summary(included: entries.filter { $0.status == .included }.count,
                       linkOnly: entries.filter { $0.status == .linkOnly }.count,
                       notDownloaded: entries.filter { $0.status == .notDownloaded }.count)
    }

    /// The system zips a directory when it is coordinated for uploading; no archive code ships here.
    private static func zip(_ folder: URL, to destination: URL) throws {
        var coordinationError: NSError?, result: Result<Void, any Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipped in
            result = Result {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                // The coordinator's archive is temporary; it must be copied before the block returns.
                try FileManager.default.copyItem(at: zipped, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    private struct Library: Encodable {
        struct Profile: Encodable { let name: String; let experience: Experience }
        struct RigEntry: Encodable { let details: RigDraft; let archivedAt: Date?; let defaults: ChecklistTemplate }
        struct TripEntry: Encodable {
            let details: TripDraft; let rig: String?; let notes: String; let rating: SiteRating
            let setup: [ChecklistStepDraft]; let teardown: [ChecklistStepDraft]; let photoCaptions: [String]
        }
        struct Saved: Encodable { let campgroundID, name, region: String; let wantToGo, favorite: Bool; let beenTo: Bool? }
        var schemaVersion = 2
        let profile: Profile?
        let rigs: [RigEntry]
        let trips: [TripEntry]
        let savedCampgrounds: [Saved]
    }

    /// One document's entry in `documents.json`.
    struct Entry: Encodable {
        enum Status: String, Encodable { case included, linkOnly, notDownloaded }
        let owner: String?
        let title, category, notes: String
        let issuedOn, expiresOn: Date?
        let link: String?
        let protection: String
        let file: DocumentFile?
        let createdAt: Date
        let status: Status
        let path: String?
    }
    private struct Manifest: Encodable { var schemaVersion = 2; let documents: [Entry] }
}
#endif
