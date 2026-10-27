import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// Repeatable storage-scale coverage. Synthetic media exercises external storage, not image decode.
@MainActor
struct LibraryScaleTests {
    @Test func aLargeLibraryReopensAndFetchesWithoutLosingRelationships() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let store = try LibraryStore.container(at: url, cloudKitContainer: nil)
            let context = store.mainContext
            context.autosaveEnabled = false
            let rig = try Rig.add(RigDraft(type: .tent), to: context)
            let arrival = Date(timeIntervalSince1970: 1_800_000_000)
            // 32 MiB of synthetic content: object/relationship scale, independent of camera hardware.
            let photo = Data(repeating: 42, count: 16 * 1024)
            for index in 0..<300 {
                let trip = try Trip.create(TripDraft(campgroundName: "Scale Campground \(index)",
                    arrival: arrival.addingTimeInterval(Double(index) * 86400),
                    departure: arrival.addingTimeInterval(Double(index + 2) * 86400)), rig: rig, in: context)
                for _ in 0..<(index < 200 ? 7 : 6) { trip.addPhoto(photo) }
                if index % 25 == 24 { try context.save() }
            }
            try context.save()
        }
        let written = clock.now
        let reopened = try LibraryStore.container(at: url, cloudKitContainer: nil)
        let trips = try reopened.mainContext.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.arrival)]))
        #expect(trips.count == 300)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<TripPhoto>()) == 2_000)
        #expect(trips.reduce(0) { $0 + $1.sortedPhotos.count } == 2_000)
        #expect(trips.allSatisfy { $0.rig != nil && !$0.steps(.setup).isEmpty })
        #expect(trips.first?.sortedPhotos.first?.imageData?.count == 16 * 1024)
        print("Large-library storage: write=\(start.duration(to: written)), reopen/fetch=\(written.duration(to: clock.now))")
    }
}
