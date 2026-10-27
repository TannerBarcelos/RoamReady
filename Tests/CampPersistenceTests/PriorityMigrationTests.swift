import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// Snapshot of the original priority attribute, before switching to raw-value storage.
private enum EnumPrioritySchema {
    @Model final class ChecklistStep {
        var title: String = ""
        var detail: String = ""
        var section: String = ""
        var status: ChecklistStatus = ChecklistStatus.pending
        var notes: String = ""
        // A high default lets this fixture exercise previously saved data without reproducing
        // the runtime's failing `.none` enum default at schema construction.
        var priority: ChecklistPriority = ChecklistPriority.high
        var phase: ChecklistPhase = ChecklistPhase.setup
        var position: Int = 0
        init() {}
    }
}

/// Snapshot of main's optional enum representation. Keep its column name during the merge.
private enum OptionalPrioritySchema {
    @Model final class ChecklistStep {
        var title: String = ""
        var detail: String = ""
        var section: String = ""
        var status: ChecklistStatus = ChecklistStatus.pending
        var notes: String = ""
        @Attribute(originalName: "priority") var storedPriority: ChecklistPriority?
        var phase: ChecklistPhase = ChecklistPhase.setup
        var position: Int = 0
        init() {}
    }
}

@MainActor
struct PriorityMigrationTests {
    @Test func enumPrioritiesFromDevelopmentLibrariesRemainReadable() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: EnumPrioritySchema.ChecklistStep.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            for priority in ChecklistPriority.allCases {
                let step = EnumPrioritySchema.ChecklistStep()
                step.title = priority.rawValue
                step.priority = priority
                old.mainContext.insert(step)
            }
            try old.mainContext.save()
        }
        let migrated = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let steps = try migrated.mainContext.fetch(FetchDescriptor<ChecklistStep>())
        #expect(steps.count == ChecklistPriority.allCases.count)
        for step in steps {
            #expect(step.priority.rawValue == step.title)
            step.priority = .medium
        }
        try migrated.mainContext.save()
        let reopened = try LibraryStore.container(at: url, cloudKitContainer: nil)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<ChecklistStep>()).allSatisfy { $0.priority == .medium })
    }

    @Test func optionalPrioritiesFromMainRemainReadable() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: OptionalPrioritySchema.ChecklistStep.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            for priority in ChecklistPriority.allCases {
                let step = OptionalPrioritySchema.ChecklistStep()
                step.title = priority.rawValue
                step.storedPriority = priority
                old.mainContext.insert(step)
            }
            let missing = OptionalPrioritySchema.ChecklistStep()
            missing.title = "missing"
            old.mainContext.insert(missing)
            try old.mainContext.save()
        }
        let migrated = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let steps = try migrated.mainContext.fetch(FetchDescriptor<ChecklistStep>())
        #expect(steps.count == ChecklistPriority.allCases.count + 1)
        for step in steps {
            #expect(step.priority == (ChecklistPriority(rawValue: step.title) ?? .none))
            step.priority = .low
        }
        try migrated.mainContext.save()
        let reopened = try LibraryStore.container(at: url, cloudKitContainer: nil)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<ChecklistStep>()).allSatisfy { $0.priority == .low })
    }

}
