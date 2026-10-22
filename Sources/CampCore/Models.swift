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
    /// Set when the owner replaces this rig. Archived rigs leave the trip picker, don't count toward
    /// `RigPolicy.maxActiveRigs`, and stay readable on the trips that used them.
    public var archivedAt: Date?
    public init(id: UUID = UUID(), type: RigType = .travelTrailer, make: String = "", model: String = "",
                year: Int? = nil, floorplan: String = "", emoji: String = "🚐",
                photoFilename: String? = nil, equipment: Equipment = Equipment(),
                lengthFeet: Double? = nil, slideCount: Int? = nil, axleCount: Int? = nil, hasBunkhouse: Bool? = nil,
                archivedAt: Date? = nil) {
        self.id = id; self.type = type; self.make = make; self.model = model; self.year = year
        self.floorplan = floorplan; self.emoji = emoji; self.photoFilename = photoFilename
        self.equipment = equipment; self.lengthFeet = lengthFeet; self.slideCount = slideCount
        self.axleCount = axleCount; self.hasBunkhouse = hasBunkhouse; self.archivedAt = archivedAt
    }
    public var isArchived: Bool { archivedAt != nil }
    /// Same owner-entered details, ignoring identity and archive state.
    public func hasSameDetails(as other: Rig) -> Bool {
        var copy = other
        copy.id = id; copy.archivedAt = archivedAt
        return copy == self
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

/// The owner's details. Rigs are separate records in `AppState.rigs`; older profiles that embedded
/// a rig are converted by `RigMigration`.
public struct CamperProfile: Codable, Equatable, Sendable {
    public var name: String
    public var experience: Experience
    public init(name: String = "", experience: Experience = .new) {
        self.name = name; self.experience = experience
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
    /// The rig these are the default lists for. Nil only in libraries saved before per-rig defaults.
    public var rigID: UUID?
    public init(id: UUID = UUID(), version: Int = 1, sourceURL: String = ChecklistFactory.sourceURL,
                setup: [ChecklistItem] = [], teardown: [ChecklistItem] = [], rigID: UUID? = nil) {
        self.id = id; self.version = version; self.sourceURL = sourceURL; self.setup = setup; self.teardown = teardown
        self.rigID = rigID
    }
    private enum CodingKeys: String, CodingKey { case id, version, sourceURL, setup, teardown, rigID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        version = try c.decode(Int.self, forKey: .version)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        setup = try c.decode([ChecklistItem].self, forKey: .setup)
        teardown = try c.decode([ChecklistItem].self, forKey: .teardown)
        rigID = try c.decodeIfPresent(UUID.self, forKey: .rigID)
    }
    /// Pending copies with fresh identities, so a copy never shares items with its source.
    public func freshCopy(rigID: UUID?) -> ChecklistTemplates {
        ChecklistTemplates(version: version, sourceURL: sourceURL, setup: setup.map { $0.freshCopy() },
                           teardown: teardown.map { $0.freshCopy() }, rigID: rigID)
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
    /// A reference to the rig in `AppState.rigs`. The UI reads the rig's current details through it;
    /// a missing rig shows as "Rig unavailable". Nil only for trips saved without a rig.
    public var rigID: UUID?
    public var campgroundID: String?
    public var planningTimeZoneIdentifier: String?
    public var campgroundTimeZoneIdentifier: String?

    // Booking details, all optional and entered by the user. A trip is one booking at one campground.
    public var loop: String?
    public var confirmationNumber: String?
    /// Who it was booked through, e.g. Recreation.gov or the campground directly.
    public var bookingProvider: String?
    /// The manage-booking page. `https` only.
    public var bookingURL: String?
    /// Minutes after midnight in the campground's time zone, on the arrival and departure days.
    public var checkInMinutes: Int?
    public var checkOutMinutes: Int?
    public var totalCost: Double?
    public var amountPaid: Double?
    /// Display only; the app never sends reminders.
    public var cancellationDeadline: Date?

    public init(id: UUID = UUID(), campgroundName: String, latitude: Double? = nil, longitude: Double? = nil,
                arrival: Date, departure: Date, siteNumber: String = "", notes: String = "",
                rating: SiteRating = .unrated, setup: [ChecklistItem] = [],
                teardown: [ChecklistItem] = [], photos: [TripPhoto] = [], rigID: UUID? = nil,
                campgroundID: String? = nil, planningTimeZoneIdentifier: String? = nil,
                campgroundTimeZoneIdentifier: String? = nil) {
        self.id = id; self.campgroundName = campgroundName; self.latitude = latitude; self.longitude = longitude
        self.arrival = arrival; self.departure = departure; self.siteNumber = siteNumber; self.notes = notes
        self.rating = rating; self.setup = setup; self.teardown = teardown; self.photos = photos
        self.rigID = rigID; self.campgroundID = campgroundID
        self.planningTimeZoneIdentifier = planningTimeZoneIdentifier
        self.campgroundTimeZoneIdentifier = campgroundTimeZoneIdentifier
    }
    /// Creating a trip is the only way it gets checklists: fresh copies of the rig's defaults
    /// (or, when the rig has none yet, the lists generated from its type). After this the trip's
    /// lists are independent of the rig's defaults.
    public static func create(campgroundName: String, arrival: Date, departure: Date, rig: Rig,
                              defaults: ChecklistTemplates? = nil, latitude: Double? = nil,
                              longitude: Double? = nil, campgroundID: String? = nil,
                              campgroundTimeZoneIdentifier: String? = nil) throws -> Trip {
        let source = defaults ?? ChecklistFactory.templates(for: rig)
        let trip = Trip(campgroundName: campgroundName.trimmingCharacters(in: .whitespacesAndNewlines),
                        latitude: latitude, longitude: longitude, arrival: arrival, departure: departure,
                        setup: source.setup.map { $0.freshCopy() }, teardown: source.teardown.map { $0.freshCopy() },
                        rigID: rig.id, campgroundID: campgroundID, planningTimeZoneIdentifier: TimeZone.current.identifier,
                        campgroundTimeZoneIdentifier: campgroundTimeZoneIdentifier)
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
        try validateBookingValues()
    }

    public static let minutesPerDay = 24 * 60

    /// Everything the booking form checks, including that check-out comes after check-in. Called when
    /// the owner creates or edits a trip, not on load: two devices editing dates and times separately
    /// could merge into an order that must not make the library unreadable.
    public func validateBooking() throws {
        try validateBookingValues()
        if let checkIn = checkInDate, let checkOut = checkOutDate, checkOut <= checkIn { throw CampError.invalidCheckTimes }
    }

    /// Per-field checks that a sync merge can't violate.
    func validateBookingValues() throws {
        if let bookingURL, !bookingURL.isEmpty {
            guard let url = URL(string: bookingURL), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
                throw CampError.invalidBookingLink
            }
        }
        for minutes in [checkInMinutes, checkOutMinutes].compactMap({ $0 }) {
            guard (0..<Self.minutesPerDay).contains(minutes) else { throw CampError.invalidCheckTimes }
        }
        for amount in [totalCost, amountPaid].compactMap({ $0 }) {
            guard amount.isFinite, amount >= 0 else { throw CampError.invalidBookingAmount }
        }
        if let cancellationDeadline, !cancellationDeadline.timeIntervalSinceReferenceDate.isFinite { throw CampError.invalidDates }
    }
}

public struct AppState: Equatable, Sendable {
    public var profile: CamperProfile?
    /// Every rig, archived ones included. See `RigPolicy` for the active-rig limit.
    public var rigs: [Rig]
    public var trips: [Trip]
    /// Default setup and teardown lists, at most one per rig (`ChecklistTemplates.rigID`).
    public var rigDefaults: [ChecklistTemplates]
    public init(profile: CamperProfile? = nil, rigs: [Rig] = [], trips: [Trip] = [], rigDefaults: [ChecklistTemplates] = []) {
        self.profile = profile; self.rigs = rigs; self.trips = trips; self.rigDefaults = rigDefaults
    }
    /// Never fails because of more than one active rig: sync can produce that, and the library must
    /// stay readable while the owner resolves it (`needsRigResolution`). Mutations enforce the limit.
    public func validated() throws -> AppState {
        guard Set(trips.map(\.id)).count == trips.count, Set(rigs.map(\.id)).count == rigs.count else { throw CampError.duplicateIdentifiers }
        for trip in trips { try trip.validate() }
        for filename in rigs.compactMap(\.photoFilename) { try validateFilename(filename) }
        let owners = rigDefaults.map(\.rigID)
        guard owners.allSatisfy({ $0 != nil }), Set(owners).count == owners.count else { throw CampError.duplicateIdentifiers }
        for defaults in rigDefaults { try validateChecklist(defaults.setup + defaults.teardown) }
        return self
    }
}

extension AppState: Codable {
    private enum CodingKeys: String, CodingKey { case profile, rigs, trips, rigDefaults }
    /// Keys of libraries saved before rigs became separate records (#28).
    private enum LegacyKeys: String, CodingKey { case profile, trips, templates }
    private struct LegacyProfile: Decodable { let rig: Rig? }
    private struct LegacyTrip: Decodable { let id: UUID; let rigSnapshot: Rig? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(CamperProfile.self, forKey: .profile)
        trips = try c.decodeIfPresent([Trip].self, forKey: .trips) ?? []
        rigs = try c.decodeIfPresent([Rig].self, forKey: .rigs) ?? []
        rigDefaults = try c.decodeIfPresent([ChecklistTemplates].self, forKey: .rigDefaults) ?? []
        guard !c.contains(.rigs) else { return }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let profileRig = try legacy.decodeIfPresent(LegacyProfile.self, forKey: .profile)?.rig
        let snapshots = try legacy.decodeIfPresent([LegacyTrip].self, forKey: .trips) ?? []
        let templates = try legacy.decodeIfPresent(ChecklistTemplates.self, forKey: .templates)
        RigMigration.migrate(&self, profileRig: profileRig, legacyTemplates: templates,
                             snapshots: Dictionary(snapshots.compactMap { trip in trip.rigSnapshot.map { (trip.id, $0) } },
                                                   uniquingKeysWith: { first, _ in first }))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encode(rigs, forKey: .rigs)
        try c.encode(trips, forKey: .trips)
        try c.encode(rigDefaults, forKey: .rigDefaults)
    }
}

public enum CampError: Error, LocalizedError, Equatable, Sendable {
    case missingCampground, invalidDates, invalidCoordinates, duplicateIdentifiers, emptyChecklistTitle
    case invalidPhotoFilename, unsupportedSchema(Int), incompleteRig, invalidRigDetails
    case invalidBookingLink, invalidCheckTimes, invalidBookingAmount
    case rigLimitReached, rigInUse, rigNotFound, rigArchived
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
        case .invalidBookingLink: "The booking link must be a secure web address starting with https://."
        case .invalidCheckTimes: "Check-out must be after check-in."
        case .invalidBookingAmount: "Costs must be zero or more."
        case .rigLimitReached: RigPolicy.maxActiveRigs == 1
            ? "You already have an active rig. Replace or archive it first."
            : "You already have \(RigPolicy.maxActiveRigs) active rigs. Archive one first."
        case .rigInUse: "Trips use this rig, so it can't be deleted. Archive it instead; past trips keep showing it."
        case .rigNotFound: "That rig is no longer available."
        case .rigArchived: "Archived rigs can't be used for new trips."
        }
    }
}

func validateChecklist(_ items: [ChecklistItem]) throws {
    guard Set(items.map(\.id)).count == items.count else { throw CampError.duplicateIdentifiers }
    guard items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw CampError.emptyChecklistTitle
    }
}

func validateFilename(_ filename: String) throws {
    guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
          !filename.contains("\\"), !filename.contains("\0") else { throw CampError.invalidPhotoFilename }
}
