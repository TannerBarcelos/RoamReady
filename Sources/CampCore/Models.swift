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
    /// Owner-entered details. Optional so rigs saved before these fields existed still load.
    public var lengthFeet: Double?
    public var slideCount: Int?
    public var axleCount: Int?
    public var hasBunkhouse: Bool?
    public init(id: UUID = UUID(), type: RigType = .travelTrailer, make: String = "", model: String = "",
                year: Int? = nil, floorplan: String = "", emoji: String = "🚐",
                photoFilename: String? = nil, equipment: Equipment = Equipment(),
                lengthFeet: Double? = nil, slideCount: Int? = nil, axleCount: Int? = nil, hasBunkhouse: Bool? = nil) {
        self.id = id; self.type = type; self.make = make; self.model = model; self.year = year
        self.floorplan = floorplan; self.emoji = emoji; self.photoFilename = photoFilename
        self.equipment = equipment; self.lengthFeet = lengthFeet; self.slideCount = slideCount
        self.axleCount = axleCount; self.hasBunkhouse = hasBunkhouse
    }
    public var displayName: String {
        let name = [make, model, floorplan].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? type.title : name
    }
    /// Short owner-entered facts, e.g. "2024 · 19 ft · 1 slide · Bunkhouse".
    public var detailSummary: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let lengthFeet { parts.append(String(format: "%g ft", lengthFeet)) }
        if let slideCount, slideCount > 0 { parts.append(slideCount == 1 ? "1 slide" : "\(slideCount) slides") }
        if let axleCount { parts.append(axleCount == 1 ? "1 axle" : "\(axleCount) axles") }
        if hasBunkhouse == true { parts.append("Bunkhouse") }
        return parts.joined(separator: " · ")
    }

    public static let yearRange = 1950...2100
    public static let lengthRange = 5.0...65.0
    /// 0 means the owner said there are no slide-outs; nil means not specified.
    public static let slideRange = 0...8
    public static let axleRange = 1...4

    /// RVs need year, make, model, and length; tents and car camping need none of them.
    /// Checked when the owner saves the form, not on load, so older profiles remain readable.
    public func validateDetails() throws {
        if type.isRV {
            guard let year, !make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let lengthFeet else {
                throw CampError.incompleteRig
            }
            guard Self.yearRange.contains(year), lengthFeet.isFinite, Self.lengthRange.contains(lengthFeet) else {
                throw CampError.invalidRigDetails
            }
        } else if let year, !Self.yearRange.contains(year) {
            throw CampError.invalidRigDetails
        }
        if let slideCount, !Self.slideRange.contains(slideCount) { throw CampError.invalidRigDetails }
        if let axleCount, !Self.axleRange.contains(axleCount) { throw CampError.invalidRigDetails }
    }
    public var hasRequiredDetails: Bool { (try? validateDetails()) != nil }
    public var detailsProblem: String? {
        do { try validateDetails(); return nil } catch { return (error as? CampError)?.errorDescription }
    }
    /// True once any required field has a value, so a blank form doesn't open with an error.
    public var hasStartedDetails: Bool {
        year != nil || lengthFeet != nil || !make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The form's error message: hidden on a blank form, shown as soon as the owner starts.
    public var visibleDetailsProblem: String? { hasStartedDetails ? detailsProblem : nil }

    /// A specified count also sets the slide-out checklist steps; "not specified" leaves them alone.
    public mutating func setSlideCount(_ value: Int?) {
        slideCount = value
        if let value { equipment.slideOuts = value > 0 }
    }
    /// Clears type-specific details after the owner picks a different rig type.
    public mutating func resetDetailsForType() {
        equipment = type.isRV ? Equipment() : .none
        emoji = type.defaultEmoji
        make = ""; model = ""; floorplan = ""; year = nil
        lengthFeet = nil; slideCount = nil; axleCount = nil; hasBunkhouse = nil
    }

    /// ASCII digits only, at most four; anything else yields nil.
    public static func parseYear(_ text: String) -> Int? {
        let digits = text.filter { $0.isASCII && $0.isNumber }.prefix(4)
        return digits.isEmpty ? nil : Int(digits)
    }
    /// Accepts "23.5" or "23,5". Non-numeric, non-finite, or non-positive input yields nil.
    public static func parseLength(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }
    public var yearText: String { year.map(String.init) ?? "" }
    public var lengthText: String { lengthFeet.map { String(format: "%g", $0) } ?? "" }
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
    public var id: UUID
    public var version: Int
    public var sourceURL: String
    public var setup: [ChecklistItem]
    public var teardown: [ChecklistItem]
    public init(id: UUID = UUID(), version: Int = 1, sourceURL: String = ChecklistFactory.sourceURL,
                setup: [ChecklistItem] = [], teardown: [ChecklistItem] = []) {
        self.id = id; self.version = version; self.sourceURL = sourceURL; self.setup = setup; self.teardown = teardown
    }
    private enum CodingKeys: String, CodingKey { case id, version, sourceURL, setup, teardown }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        version = try c.decode(Int.self, forKey: .version)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        setup = try c.decode([ChecklistItem].self, forKey: .setup)
        teardown = try c.decode([ChecklistItem].self, forKey: .teardown)
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
    case invalidPhotoFilename, unsupportedSchema(Int), incompleteRig, invalidRigDetails
    public var errorDescription: String? {
        switch self {
        case .missingCampground: "Enter a campground or destination name."
        case .invalidDates: "Departure must be on or after arrival."
        case .invalidCoordinates: "The campground coordinates are invalid."
        case .duplicateIdentifiers: "The saved data contains duplicate identifiers. Your existing file was not changed."
        case .emptyChecklistTitle: "Every checklist step needs a title."
        case .invalidPhotoFilename: "A photo reference is invalid. Your existing file was not changed."
        case .unsupportedSchema(let version): "This data uses an unsupported format (version \(version)). Update the app before opening it."
        case .incompleteRig: "Enter your rig’s year, make, model, and length."
        case .invalidRigDetails: "Check your rig details. Year, length, slides, or axles are outside the supported range."
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
