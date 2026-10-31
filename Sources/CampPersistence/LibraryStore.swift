import Foundation
import SwiftData
import CampCore

/// Builds the library's SwiftData container. SwiftData owns the SQLite store, external files,
/// persistent history, and, when a container identifier is given, private CloudKit mirroring.
public enum LibraryStore {
    public static var schema: Schema {
        Schema([CamperProfile.self, Rig.self, Trip.self, ChecklistStep.self, TripPhoto.self, NoteRevision.self,
                SavedCampground.self, StoredDocument.self, DocumentContent.self,
                TripMeal.self, MenuDish.self, DishItem.self])
    }

    /// `cloudKitContainer` nil keeps the library on this device only.
    public static func container(at url: URL, cloudKitContainer: String?) throws -> ModelContainer {
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: cloudKitContainer.map { .private($0) } ?? .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// For previews and tests.
    public static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
}

public extension ModelContext {
    func profile() throws -> CamperProfile? {
        try fetch(FetchDescriptor<CamperProfile>(sortBy: [SortDescriptor(\.createdAt)])).first
    }
    func rigs() throws -> [Rig] { try fetch(FetchDescriptor<Rig>(sortBy: [SortDescriptor(\.createdAt)])) }
    func activeRigs() throws -> [Rig] { try rigs().active }
}

public extension Array where Element == Rig {
    var active: [Rig] { filter { !$0.isArchived && !$0.isDeleted } }
    var archived: [Rig] { filter { $0.isArchived && !$0.isDeleted } }
    /// Sync can merge two devices' rigs into more active rigs than the policy allows. Nothing is
    /// hidden or deleted; the owner is asked to archive one.
    var needsRigResolution: Bool { active.count > RigPolicy.maxActiveRigs }
}
