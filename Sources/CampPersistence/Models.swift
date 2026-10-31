import Foundation
import SwiftData
import CampCore

// The library's SwiftData models. CloudKit mirroring requires every attribute to be optional or have
// a default, every relationship to be optional, and no unique constraints; these follow those rules.
// Until the CloudKit schema is promoted to Production (#6) they can change freely. After that, only
// add optional attributes or models: never rename, retype, or remove one, or change cloud encryption.

@Model
public final class CamperProfile {
    public var name: String = ""
    public var experience: Experience = Experience.new
    public var createdAt: Date = Date.now
    public init(name: String = "", experience: Experience = .new) {
        self.name = name; self.experience = experience
    }
}

@Model
public final class Rig: RigDetails {
    public var type: RigType = RigType.travelTrailer
    public var make: String = ""
    public var model: String = ""
    public var year: Int?
    public var floorplan: String = ""
    public var emoji: String = "🚐"
    /// A resized JPEG, or nil to show the emoji.
    @Attribute(.externalStorage) public var photo: Data?
    /// New photos use Apple's encryption even when small enough to sync inline.
    @Attribute(.externalStorage, .allowsCloudEncryption) public var protectedPhoto: Data?
    public var equipment: Equipment = Equipment()
    public var lengthFeet: Double?
    public var slideCount: Int?
    public var axleCount: Int?
    public var hasBunkhouse: Bool?
    /// Normalized registration (see `RigDraft.normalized`), encrypted in iCloud like other identifying details.
    @Attribute(.allowsCloudEncryption) public var vin: String = ""
    @Attribute(.allowsCloudEncryption) public var licensePlate: String = ""
    @Attribute(.allowsCloudEncryption) public var plateRegion: String = ""
    /// Set when the owner replaces this rig. Archived rigs leave the trip picker, don't count toward
    /// `RigPolicy.maxActiveRigs`, and stay on the trips that used them.
    public var archivedAt: Date?
    public var createdAt: Date = Date.now
    /// Distinguishes intentionally empty defaults from an older rig without generated lists.
    public var hasConfiguredDefaults: Bool = false
    /// The rig's default setup and teardown lists, copied into each new trip.
    @Relationship(deleteRule: .cascade, inverse: \ChecklistStep.rig) public var defaultSteps: [ChecklistStep]? = []
    @Relationship(inverse: \Trip.rig) public var trips: [Trip]? = []
    @Relationship(inverse: \StoredDocument.rig) public var documents: [StoredDocument]? = []
    public init() {}
}

/// One booking at one campground, with its checklists, notes, and photos.
@Model
public final class Trip: TripDetails {
    /// Optional cover selected for this trip, separate from its memory photos.
    @Attribute(.externalStorage, .allowsCloudEncryption) public var coverPhotoData: Data?

    public var campgroundName: String = ""
    public var campgroundID: String?
    public var latitude: Double?
    public var longitude: Double?
    public var arrival: Date = Date.now
    public var departure: Date = Date.now
    public var planningTimeZoneIdentifier: String?
    public var campgroundTimeZoneIdentifier: String?
    public var siteNumber: String = ""
    public var loop: String?
    public var site: SiteDetails?
    public var confirmationNumber: String?
    public var bookingProvider: String?
    public var bookingURL: String?
    public var checkInMinutes: Int?
    public var checkOutMinutes: Int?
    public var totalCost: Double?
    public var amountPaid: Double?
    public var cancellationDeadline: Date?
    public var completedAt: Date?
    public var notes: String = ""
    public var rating: SiteRating = SiteRating.unrated
    public var createdAt: Date = Date.now
    /// Nil only when the rig record hasn't synced yet; shown as "Rig unavailable".
    public var rig: Rig?
    @Relationship(deleteRule: .cascade, inverse: \ChecklistStep.trip) public var steps: [ChecklistStep]? = []
    @Relationship(deleteRule: .cascade, inverse: \TripPhoto.trip) public var photos: [TripPhoto]? = []
    @Relationship(deleteRule: .cascade, inverse: \NoteRevision.trip) public var noteRevisions: [NoteRevision]? = []
    /// The trip's menu. Additive relationship: older records read as an empty menu.
    @Relationship(deleteRule: .cascade, inverse: \TripMeal.trip) public var meals: [TripMeal]? = []
    /// Deleting the trip keeps its documents; they become unattached.
    @Relationship(inverse: \StoredDocument.trip) public var documents: [StoredDocument]? = []
    public init() {}
}

/// A step on a trip's checklist, or on a rig's default list when `rig` is set.
@Model
public final class ChecklistStep {
    public var title: String = ""
    public var detail: String = ""
    public var section: String = ""
    public var status: ChecklistStatus = ChecklistStatus.pending
    /// The owner's notes, separate from the generated guidance in `detail`.
    public var notes: String = ""
    /// Persist a primitive value: SwiftData can fail to materialize a defaulted Codable enum
    /// when opening an older store. Keep unknown values intact for forward compatibility.
    public var priorityValue: String?
    /// Retain priorities written by development builds before the raw-value representation.
    /// Optional storage avoids the failing enum default during schema materialization.
    @Attribute(originalName: "priority") private var storedPriority: ChecklistPriority?
    public var priority: ChecklistPriority {
        get {
            if let priorityValue { return ChecklistPriority(rawValue: priorityValue) ?? .none }
            return storedPriority ?? .none
        }
        set { priorityValue = newValue.rawValue }
    }
    public var phase: ChecklistPhase = ChecklistPhase.setup
    public var position: Int = 0
    public var trip: Trip?
    public var rig: Rig?
    public init() {}
}

@Model
public final class TripPhoto {
    /// A resized JPEG.
    @Attribute(.externalStorage) public var image: Data?
    @Attribute(.externalStorage, .allowsCloudEncryption) public var protectedImage: Data?
    public var caption: String = ""
    public var createdAt: Date = Date.now
    public var trip: Trip?
    public init(image: Data) { self.protectedImage = image }

    public var imageData: Data? { protectedImage ?? image }
}

/// A saved version of a trip's notes, so earlier text can be restored.
@Model
public final class NoteRevision {
    public var body: String = ""
    public var createdAt: Date = Date.now
    public var trip: Trip?
    public init(body: String) { self.body = body }
}

/// One meal on one day of a trip's menu. There's no separate menu record: a to-one menu created on
/// two devices before they sync would merge into two. Standard meals are stored when their first
/// dish is added, so sync can also produce two of the same meal; the menu shows them as one.
@Model
public final class TripMeal {
    /// Days after arrival, so the meal stays on the same trip day when the dates move.
    public var dayOffset: Int = 0
    /// A raw `MealKind`, so a kind written by a newer app version is kept rather than failing to load.
    public var kindValue: String = "other"
    /// The owner's name for an added meal. Standard meals use their kind's title.
    public var title: String = ""
    /// Orders added meals within their day.
    public var position: Int = 0
    public var createdAt: Date = Date.now
    public var trip: Trip?
    @Relationship(deleteRule: .cascade, inverse: \MenuDish.meal) public var dishes: [MenuDish]? = []
    public init(day: Int = 0, kind: MealKind = .other) { dayOffset = day; kindValue = kind.rawValue }
}

/// A whole plate within a meal, with its notes, photo, and recipe items.
@Model
public final class MenuDish {
    public var name: String = ""
    public var notes: String = ""
    /// A resized JPEG.
    @Attribute(.externalStorage, .allowsCloudEncryption) public var protectedPhoto: Data?
    public var position: Int = 0
    public var createdAt: Date = Date.now
    public var meal: TripMeal?
    @Relationship(deleteRule: .cascade, inverse: \DishItem.dish) public var items: [DishItem]? = []
    public init() {}
}

/// One line of a dish's recipe, like "Ribeye, 2 lb".
@Model
public final class DishItem {
    public var name: String = ""
    public var quantity: String = ""
    public var position: Int = 0
    public var dish: MenuDish?
    public init() {}
}

/// A campground on the owner's lists (#30). Name and region are kept for campgrounds entered by name
/// or previously saved places, so the lists work offline; an Apple Maps place keeps only its ID.
@Model
public final class SavedCampground {
    public var campgroundID: String = ""
    public var name: String = ""
    public var region: String = ""
    public var wantToGo: Bool = false
    public var favorite: Bool = false
    /// Nil follows the trips: a completed trip here counts as been here. True or false is the
    /// owner's explicit choice.
    public var beenTo: Bool?
    public init(campgroundID: String) { self.campgroundID = campgroundID }
}

/// A PDF, image, or link attached to a rig or trip, or unattached when neither is set.
/// Personal text fields are end-to-end encrypted in iCloud; file bytes live in `content`.
@Model
public final class StoredDocument {
    /// Identifies this document, including legacy sealed files and exported copies.
    public var documentID: UUID = UUID()
    @Attribute(.allowsCloudEncryption) public var title: String = ""
    @Attribute(.allowsCloudEncryption) public var notes: String = ""
    @Attribute(.allowsCloudEncryption) public var link: String?
    @Attribute(.allowsCloudEncryption) public var filename: String?
    /// Raw values, so a value written by a newer app version is kept rather than failing to load.
    public var categoryValue: String = "other"
    public var protectionValue: String = "standard"
    public var contentTypeValue: String?
    public var byteCount: Int?
    /// SHA-256 of the original file bytes.
    public var checksum: String?
    public var issuedOn: Date?
    public var expiresOn: Date?
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now
    /// The owner's per-document opt-in for the Assistant. Only an Other document honors it; every other
    /// category is decided by `AssistantDocumentEligibility`. Additive attribute: older records read as off.
    public var includeInAssistant: Bool = false
    public var rig: Rig?
    public var trip: Trip?
    /// Separate so listing documents never loads file bytes, and so a file can arrive from iCloud
    /// after its details.
    @Relationship(deleteRule: .cascade, inverse: \DocumentContent.document) public var content: DocumentContent?
    public init() {}
}

@Model
public final class DocumentContent {
    /// Legacy bytes, retained so existing libraries and CloudKit schemas stay readable.
    @Attribute(.externalStorage) public var bytes: Data?
    /// Legacy application-encrypted file key. New writes don't create their own keys.
    @Attribute(.allowsCloudEncryption) public var key: Data?
    /// Apple manages both inline field encryption and large-asset encryption.
    /// A new field avoids changing encryption on an existing CloudKit schema field.
    @Attribute(.externalStorage, .allowsCloudEncryption) public var protectedBytes: Data?
    /// The file these bytes are, matched against `StoredDocument.checksum`.
    public var checksum: String = ""
    public var document: StoredDocument?
    public init() {}
}
