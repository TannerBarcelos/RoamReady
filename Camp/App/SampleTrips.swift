#if DEBUG
import Foundation
import SwiftData
import CampCore
import CampPersistence

/// Adds sample trips to the owner's real library for trying layouts with many trips. Runs only with
/// the `-seed-sample-trips` launch argument. Seeded trips carry a `SAMPLE-` confirmation number, so
/// launching again doesn't add duplicates.
@MainActor
enum SampleTrips {
    static let launchArgument = "-seed-sample-trips"
    private static let marker = "SAMPLE-"

    static func seedIfRequested(in container: ModelContainer) throws {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        let context = container.mainContext
        let existing = try context.fetch(FetchDescriptor<Trip>())
        guard !existing.contains(where: { $0.confirmationNumber?.hasPrefix(marker) == true }) else { return }
        guard let rig = try context.fetch(FetchDescriptor<Rig>(sortBy: [SortDescriptor(\.createdAt)]))
            .first(where: { !$0.isArchived }) else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        // Day offsets from today: a few upcoming, one far off, and a few already finished.
        let samples: [(name: String, site: String, start: Int, nights: Int, latitude: Double, longitude: Double, timeZone: String)] = [
            ("Pfeiffer Big Sur State Park", "112", 4, 3, 36.2509, -121.7836, "America/Los_Angeles"),
            ("Fallen Leaf Campground", "48", 12, 4, 38.9223, -120.0477, "America/Los_Angeles"),
            ("Upper Pines, Yosemite", "A21", 23, 2, 37.7365, -119.5627, "America/Los_Angeles"),
            ("Kirk Creek Campground", "7", 41, 3, 35.9894, -121.4954, "America/Los_Angeles"),
            ("Mather Campground, Grand Canyon", "Juniper 204", 75, 5, 36.0560, -112.1236, "America/Phoenix"),
            ("Emerald Bay State Park", "19", -21, 2, 38.9541, -120.1100, "America/Los_Angeles"),
            ("Doheny State Beach", "88", -45, 3, 33.4622, -117.6857, "America/Los_Angeles"),
        ]
        for (index, sample) in samples.enumerated() {
            let arrival = calendar.date(byAdding: .day, value: sample.start, to: today)!
            var draft = TripDraft(campgroundName: sample.name, arrival: arrival,
                                  departure: calendar.date(byAdding: .day, value: sample.nights, to: arrival)!,
                                  latitude: sample.latitude, longitude: sample.longitude,
                                  campgroundTimeZoneIdentifier: sample.timeZone)
            draft.siteNumber = sample.site
            draft.confirmationNumber = "\(marker)\(index + 1)"
            _ = try Trip.create(draft, rig: rig, in: context)
        }
        try context.save()
    }
}
#endif
