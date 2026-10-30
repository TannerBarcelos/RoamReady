#if DEBUG
import Foundation
import SwiftData
import UIKit
import CampCore
import CampPersistence
import DocumentVault

/// Isolated fixtures for navigation tests; the owner's on-disk library is never opened.
@MainActor
enum NavigationUITestLibrary {
    static func make() throws -> ModelContainer {
        let container = try LibraryStore.inMemory()
        let context = container.mainContext
        context.insert(CamperProfile(name: "Riley", experience: .comfortable))
        let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries",
                                      year: 2024, lengthFeet: 19.5), to: context)
        if DocumentAssistantFixture.isRequested { try DocumentAssistantFixture.seed(rig: rig, in: context) }
        if DocumentReadinessFixture.isRequested { try DocumentReadinessFixture.seed(rig: rig, in: context) }
        // `-empty-library` keeps the profile and rig but adds no trips.
        if ProcessInfo.processInfo.arguments.contains("-empty-library") {
            try context.save()
            return container
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var trips: [Trip] = []
        for (name, start, end) in [("Current Pines", -1, 1), ("Overlapping Creek", 0, 2),
                                   ("Upcoming Lake", 7, 9), ("Past Meadows", -7, -5)] {
            var draft = TripDraft(campgroundName: name,
                                 arrival: calendar.date(byAdding: .day, value: start, to: today)!,
                                 departure: calendar.date(byAdding: .day, value: end, to: today)!)
            draft.campgroundTimeZoneIdentifier = calendar.timeZone.identifier
            trips.append(try Trip.create(draft, rig: rig, in: context))
        }
        // The Duo resize checks open a photo and a document; other runs keep the plain fixtures.
        if DuoWorkspace.isForcedForUITests, let current = trips.first {
            let jpeg = sampleImage()
            current.addPhoto(jpeg)
            current.sortedPhotos.first?.caption = "Site 14 from the road"
            try StoredDocument.add(DocumentMetadata(title: "Campground map", category: .reservation),
                                   contents: DocumentPayload(bytes: jpeg, filename: "campground-map.jpg"),
                                   trip: current, in: context)
        }
        try context.save()
        return container
    }

    private static func sampleImage() -> Data {
        let size = CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 500, width: 1200, height: 300))
            UIColor.systemOrange.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 900, y: 80, width: 180, height: 180))
        }
    }
}
#endif
