import Foundation

public enum RigType: String, Codable, CaseIterable, Identifiable, Sendable {
    case travelTrailer, fifthWheel, motorhome, camperVan, truckCamper, popUp, carCamping, tent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .travelTrailer: "Travel trailer"
        case .fifthWheel: "Fifth wheel"
        case .motorhome: "Motorhome"
        case .camperVan: "Camper van"
        case .truckCamper: "Truck camper"
        case .popUp: "Pop-up camper"
        case .carCamping: "Car camping"
        case .tent: "Tent"
        }
    }
    public var isTowable: Bool { [.travelTrailer, .fifthWheel, .popUp].contains(self) }
    public var isRV: Bool { self != .carCamping && self != .tent }
    public var defaultEmoji: String {
        switch self {
        case .tent: "⛺️"
        case .carCamping: "🚙"
        default: "🚐"
        }
    }
}

public struct Equipment: Codable, Equatable, Sendable {
    public var shorePower: Bool
    public var freshWater: Bool
    public var sewer: Bool
    public var slideOuts: Bool
    public var propane: Bool
    public init(shorePower: Bool = true, freshWater: Bool = true, sewer: Bool = true,
                slideOuts: Bool = false, propane: Bool = true) {
        self.shorePower = shorePower; self.freshWater = freshWater; self.sewer = sewer
        self.slideOuts = slideOuts; self.propane = propane
    }
    public static let none = Equipment(shorePower: false, freshWater: false, sewer: false, propane: false)
}

public struct Rig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var type: RigType
    public var make: String
    public var model: String
    public var year: Int?
    public var floorplan: String
    public var emoji: String
    public var photoFilename: String?
    public var equipment: Equipment
    public init(id: UUID = UUID(), type: RigType = .travelTrailer, make: String = "", model: String = "",
                year: Int? = nil, floorplan: String = "", emoji: String = "🚐",
                photoFilename: String? = nil, equipment: Equipment = Equipment()) {
        self.id = id; self.type = type; self.make = make; self.model = model; self.year = year
        self.floorplan = floorplan; self.emoji = emoji; self.photoFilename = photoFilename
        self.equipment = equipment
    }
    public var displayName: String {
        let name = [make, model, floorplan].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? type.title : name
    }
}

public enum Experience: String, Codable, CaseIterable, Identifiable, Sendable {
    case new, comfortable, experienced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .new: "Just getting started"
        case .comfortable: "A few trips under my belt"
        case .experienced: "Experienced camper"
        }
    }
}

public struct CamperProfile: Codable, Equatable, Sendable {
    public var name: String
    public var experience: Experience
    public var rig: Rig
    public init(name: String = "", experience: Experience = .new, rig: Rig = Rig()) {
        self.name = name; self.experience = experience; self.rig = rig
    }
}

public enum ChecklistStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending, completed, skipped
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct ChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var section: String
    public var status: ChecklistStatus
    public init(id: UUID = UUID(), title: String, detail: String = "", section: String = "My checklist",
                status: ChecklistStatus = .pending) {
        self.id = id; self.title = title; self.detail = detail; self.section = section; self.status = status
    }
    public var isFinished: Bool { status != .pending }
    public func freshCopy() -> ChecklistItem {
        ChecklistItem(title: title, detail: detail, section: section)
    }
}

public struct ChecklistTemplates: Codable, Equatable, Sendable {
    public var version: Int
    public var sourceURL: String
    public var setup: [ChecklistItem]
    public var teardown: [ChecklistItem]
    public init(version: Int = 1, sourceURL: String = ChecklistFactory.sourceURL,
                setup: [ChecklistItem] = [], teardown: [ChecklistItem] = []) {
        self.version = version; self.sourceURL = sourceURL; self.setup = setup; self.teardown = teardown
    }
}

public enum SiteRating: String, Codable, CaseIterable, Identifiable, Sendable {
    case unrated, wouldReturn, avoid
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .unrated: "Not rated"
        case .wouldReturn: "Would stay again"
        case .avoid: "Try somewhere else"
        }
    }
}

public struct TripPhoto: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var filename: String
    public var caption: String
    public var createdAt: Date
    public init(id: UUID = UUID(), filename: String, caption: String = "", createdAt: Date = Date()) {
        self.id = id; self.filename = filename; self.caption = caption; self.createdAt = createdAt
    }
}

public struct Trip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var campgroundName: String
    public var latitude: Double?
    public var longitude: Double?
    public var arrival: Date
    public var departure: Date
    public var siteNumber: String
    public var notes: String
    public var rating: SiteRating
    public var setup: [ChecklistItem]
    public var teardown: [ChecklistItem]
    public var photos: [TripPhoto]
    /// Immutable context at creation; older archives may not have these fields.
    public var rigSnapshot: Rig?
    public var campgroundID: String?
    public var planningTimeZoneIdentifier: String?
    public var campgroundTimeZoneIdentifier: String?
    public init(id: UUID = UUID(), campgroundName: String, latitude: Double? = nil, longitude: Double? = nil,
                arrival: Date, departure: Date, siteNumber: String = "", notes: String = "",
                rating: SiteRating = .unrated, setup: [ChecklistItem] = [],
                teardown: [ChecklistItem] = [], photos: [TripPhoto] = [], rigSnapshot: Rig? = nil,
                campgroundID: String? = nil, planningTimeZoneIdentifier: String? = nil,
                campgroundTimeZoneIdentifier: String? = nil) {
        self.id = id; self.campgroundName = campgroundName; self.latitude = latitude; self.longitude = longitude
        self.arrival = arrival; self.departure = departure; self.siteNumber = siteNumber; self.notes = notes
        self.rating = rating; self.setup = setup; self.teardown = teardown; self.photos = photos
        self.rigSnapshot = rigSnapshot; self.campgroundID = campgroundID
        self.planningTimeZoneIdentifier = planningTimeZoneIdentifier
        self.campgroundTimeZoneIdentifier = campgroundTimeZoneIdentifier
    }
    public static func create(campgroundName: String, arrival: Date, departure: Date, rig: Rig,
                              templates: ChecklistTemplates? = nil, latitude: Double? = nil,
                              longitude: Double? = nil) throws -> Trip {
        let source = templates ?? ChecklistFactory.templates(for: rig)
        let trip = Trip(campgroundName: campgroundName.trimmingCharacters(in: .whitespacesAndNewlines),
                        latitude: latitude, longitude: longitude, arrival: arrival, departure: departure,
                        setup: source.setup.map { $0.freshCopy() }, teardown: source.teardown.map { $0.freshCopy() },
                        rigSnapshot: rig, planningTimeZoneIdentifier: TimeZone.current.identifier)
        try trip.validate()
        return trip
    }
    public var setupProgress: Double { Self.progress(setup) }
    public var teardownProgress: Double { Self.progress(teardown) }
    private static func progress(_ items: [ChecklistItem]) -> Double {
        items.isEmpty ? 0 : Double(items.filter(\.isFinished).count) / Double(items.count)
    }
    public func validate() throws {
        guard !campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CampError.missingCampground
        }
        guard arrival.timeIntervalSince1970.isFinite, departure.timeIntervalSince1970.isFinite,
              departure >= arrival else { throw CampError.invalidDates }
        guard (latitude == nil) == (longitude == nil) else { throw CampError.invalidCoordinates }
        if let latitude, let longitude {
            guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else { throw CampError.invalidCoordinates }
        }
        try validateChecklist(setup + teardown)
        guard Set(photos.map(\.id)).count == photos.count else { throw CampError.duplicateIdentifiers }
        for photo in photos { try validateFilename(photo.filename) }
        if let filename = rigSnapshot?.photoFilename { try validateFilename(filename) }
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var profile: CamperProfile?
    public var trips: [Trip]
    public var templates: ChecklistTemplates?
    public init(profile: CamperProfile? = nil, trips: [Trip] = [], templates: ChecklistTemplates? = nil) {
        self.profile = profile; self.trips = trips; self.templates = templates
    }
    public func validated() throws -> AppState {
        guard Set(trips.map(\.id)).count == trips.count else { throw CampError.duplicateIdentifiers }
        for trip in trips { try trip.validate() }
        if let filename = profile?.rig.photoFilename { try validateFilename(filename) }
        if let templates { try validateChecklist(templates.setup + templates.teardown) }
        return self
    }
}

public enum CampError: Error, LocalizedError, Equatable, Sendable {
    case missingCampground, invalidDates, invalidCoordinates, duplicateIdentifiers, emptyChecklistTitle
    case invalidPhotoFilename, unsupportedSchema(Int)
    public var errorDescription: String? {
        switch self {
        case .missingCampground: "Enter a campground or destination name."
        case .invalidDates: "Departure must be on or after arrival."
        case .invalidCoordinates: "The campground coordinates are invalid."
        case .duplicateIdentifiers: "The saved data contains duplicate identifiers. Your existing file was not changed."
        case .emptyChecklistTitle: "Every checklist step needs a title."
        case .invalidPhotoFilename: "A photo reference is invalid. Your existing file was not changed."
        case .unsupportedSchema(let version): "This data uses an unsupported format (version \(version)). Update the app before opening it."
        }
    }
}

private func validateChecklist(_ items: [ChecklistItem]) throws {
    guard Set(items.map(\.id)).count == items.count else { throw CampError.duplicateIdentifiers }
    guard items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw CampError.emptyChecklistTitle
    }
}

private func validateFilename(_ filename: String) throws {
    guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
          !filename.contains("\\"), !filename.contains("\0") else { throw CampError.invalidPhotoFilename }
}

public struct RigCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let coverageNote: String
    public let records: [RigCatalogRecord]
    public init(schemaVersion: Int = 1, coverageNote: String, records: [RigCatalogRecord]) {
        self.schemaVersion = schemaVersion; self.coverageNote = coverageNote; self.records = records
    }
    public static func decode(_ data: Data) throws -> RigCatalog {
        let result = try JSONDecoder().decode(RigCatalog.self, from: data)
        guard result.schemaVersion == 1 else { throw CampError.unsupportedSchema(result.schemaVersion) }
        return result
    }
}

public struct RigCatalogRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let make: String
    public let model: String
    public let year: Int
    public let floorplan: String?
    public let rigType: RigType
    public let sourceURL: String
    public let imageURL: String?
    public let imageRights: String
    public init(id: String, make: String, model: String, year: Int, floorplan: String? = nil,
                rigType: RigType, sourceURL: String, imageURL: String? = nil, imageRights: String) {
        self.id = id; self.make = make; self.model = model; self.year = year; self.floorplan = floorplan
        self.rigType = rigType; self.sourceURL = sourceURL; self.imageURL = imageURL; self.imageRights = imageRights
    }
}
