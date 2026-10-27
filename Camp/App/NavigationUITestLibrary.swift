#if DEBUG
import Foundation
import SwiftData
import CampCore
import CampPersistence

/// Isolated fixtures for navigation tests; the owner's on-disk library is never opened.
@MainActor
enum NavigationUITestLibrary {
    static func make() throws -> ModelContainer {
        let container = try LibraryStore.inMemory()
        let context = container.mainContext
        context.insert(CamperProfile(name: "Riley", experience: .comfortable))
        let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries",
                                      year: 2024, lengthFeet: 19.5), to: context)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for (name, start, end) in [("Current Pines", -1, 1), ("Overlapping Creek", 0, 2),
                                   ("Upcoming Lake", 7, 9), ("Past Meadows", -7, -5)] {
            var draft = TripDraft(campgroundName: name,
                                 arrival: calendar.date(byAdding: .day, value: start, to: today)!,
                                 departure: calendar.date(byAdding: .day, value: end, to: today)!)
            draft.campgroundTimeZoneIdentifier = calendar.timeZone.identifier
            _ = try Trip.create(draft, rig: rig, in: context)
        }
        try context.save()
        return container
    }
}
#endif
