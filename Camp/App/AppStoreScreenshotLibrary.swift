#if DEBUG
import Foundation
import SwiftData
import CampCore
import CampPersistence
import DocumentVault
import UIKit

/// `-app-store-screenshots`: an in-memory demo library for App Store screenshots, with real campground
/// names and a trip in progress. The owner's library is never opened, and Pro access is pinned on.
@MainActor
enum AppStoreScreenshotLibrary {
    static let launchArgument = "-app-store-screenshots"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static func make() throws -> ModelContainer {
        let container = try LibraryStore.inMemory()
        let context = container.mainContext
        context.insert(CamperProfile(name: "Sam", experience: .comfortable))
        let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Airstream", model: "Basecamp 20X",
                                      year: 2025, emoji: "🏕️", lengthFeet: 20), to: context)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let stays: [(name: String, site: String, start: Int, nights: Int, latitude: Double, longitude: Double, zone: String)] = [
            ("Pfeiffer Big Sur State Park", "112", -1, 3, 36.2509, -121.7836, "America/Los_Angeles"),
            ("Fallen Leaf Campground", "48", 9, 4, 38.9223, -120.0477, "America/Los_Angeles"),
            ("Upper Pines, Yosemite", "A21", 23, 2, 37.7365, -119.5627, "America/Los_Angeles"),
            ("Mather Campground, Grand Canyon", "Juniper 204", 52, 5, 36.0560, -112.1236, "America/Phoenix"),
            ("Emerald Bay State Park", "19", -30, 2, 38.9541, -120.1100, "America/Los_Angeles"),
        ]
        var trips: [Trip] = []
        for (index, stay) in stays.enumerated() {
            let arrival = calendar.date(byAdding: .day, value: stay.start, to: today)!
            var draft = TripDraft(campgroundName: stay.name, arrival: arrival,
                                  departure: calendar.date(byAdding: .day, value: stay.nights, to: arrival)!,
                                  latitude: stay.latitude, longitude: stay.longitude,
                                  campgroundTimeZoneIdentifier: stay.zone)
            draft.siteNumber = stay.site
            draft.confirmationNumber = "RR-\(4821 + index * 137)"
            trips.append(try Trip.create(draft, rig: rig, in: context))
        }

        // The current trip is part-way through setup, with a menu and site notes.
        if let current = trips.first {
            for step in current.steps(.setup).prefix(5) { step.status = .completed }
            current.notes = "Level pad, afternoon shade from the redwoods. Quietest sites are on the river loop."
            current.rating = .wouldReturn
            let menu: [(day: Int, kind: MealKind, dish: String, items: [DishItemDraft])] = [
                (0, .dinner, "Campfire chili", [
                    DishItemDraft(name: "Ground beef", amount: 2, unit: .lb, category: .meatSeafood),
                    DishItemDraft(name: "Kidney beans", amount: 2, unit: .can, category: .cannedGoods),
                    DishItemDraft(name: "Yellow onion", amount: 1, category: .produce),
                    DishItemDraft(name: "Cornbread mix", amount: 1, unit: .box, category: .bakery)]),
                (1, .breakfast, "Skillet pancakes and bacon", [
                    DishItemDraft(name: "Pancake mix", amount: 1, unit: .box, category: .breakfastCereal),
                    DishItemDraft(name: "Bacon", amount: 1, unit: .lb, category: .meatSeafood),
                    DishItemDraft(name: "Eggs", amount: 1, unit: .dozen, category: .dairyEggs),
                    DishItemDraft(name: "Maple syrup", amount: 1, unit: .bottle, category: .condimentsSpices)]),
                (1, .lunch, "Trail sandwiches", [
                    DishItemDraft(name: "Sourdough", amount: 1, unit: .loaf, category: .bakery),
                    DishItemDraft(name: "Turkey", amount: 1, unit: .lb, category: .meatSeafood),
                    DishItemDraft(name: "Apples", amount: 4, category: .produce)]),
                (1, .dinner, "Foil-packet salmon and potatoes", [
                    DishItemDraft(name: "Salmon fillets", amount: 4, category: .meatSeafood),
                    DishItemDraft(name: "Baby potatoes", amount: 2, unit: .lb, category: .produce),
                    DishItemDraft(name: "Lemons", amount: 2, category: .produce)]),
                (2, .breakfast, "Breakfast burritos", [
                    DishItemDraft(name: "Tortillas", amount: 1, unit: .pack, category: .bakery),
                    DishItemDraft(name: "Shredded cheese", amount: 1, unit: .bag, category: .dairyEggs)]),
                (2, .snack, "S’mores", [
                    DishItemDraft(name: "Graham crackers", amount: 1, unit: .box, category: .snacks),
                    DishItemDraft(name: "Marshmallows", amount: 1, unit: .bag, category: .snacks),
                    DishItemDraft(name: "Chocolate bars", amount: 4, category: .snacks)]),
            ]
            for entry in menu {
                let dish = try current.addDish(MenuDishDraft(name: entry.dish), to: .standard(day: entry.day, kind: entry.kind))
                for item in entry.items { try dish.addItem(item) }
            }
            for have in ["Kidney beans", "Maple syrup", "Graham crackers", "Eggs"] {
                current.setHave(true, forGroceryKey: GroceryList.key(for: have))
            }
        }
        if let current = trips.first {
            try StoredDocument.add(DocumentMetadata(title: "Big Sur reservation", category: .reservation),
                                   contents: DocumentPayload(bytes: page(["Reservation confirmed", "Pfeiffer Big Sur State Park",
                                                                          "Site 112 · 3 nights", "Check-in 2:00 PM · Check-out 12:00 PM",
                                                                          "Confirmation RR-4821"]),
                                                             filename: "big-sur-reservation.jpg"),
                                   trip: current, in: context)
        }
        try StoredDocument.add(DocumentMetadata(title: "Basecamp owner’s manual", category: .manual),
                               contents: DocumentPayload(bytes: page(["Owner’s manual", "Basecamp 20X", "Setup, leveling, water, and power"]),
                                                         filename: "basecamp-manual.jpg"),
                               rig: rig, in: context)
        if let past = trips.last { past.setCompleted(true) }
        try context.save()
        return container
    }

    /// A plain letter-size page with a few lines of text, so document rows open to something readable.
    private static func page(_ lines: [String]) -> Data {
        let size = CGSize(width: 850, height: 1100)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                let font = UIFont.systemFont(ofSize: index == 0 ? 44 : 28, weight: index == 0 ? .bold : .regular)
                (line as NSString).draw(at: CGPoint(x: 70, y: 90 + index * 70), withAttributes: [.font: font, .foregroundColor: UIColor.darkGray])
            }
        }
    }
}
#endif
