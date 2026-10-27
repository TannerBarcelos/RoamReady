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
    /// Everything but a tent is a vehicle or trailer with a VIN and a plate.
    public var hasRegistration: Bool { self != .tent }
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

/// The owner-entered facts about a rig, shared by the stored rig and the form's draft so the rules
/// live in one place.
public protocol RigDetails {
    var type: RigType { get }
    var make: String { get }
    var model: String { get }
    var year: Int? { get }
    var floorplan: String { get }
    var equipment: Equipment { get }
    /// Optional because tents and car camping have none; RVs require them when the form is saved.
    var lengthFeet: Double? { get }
    /// 0 means the owner said there are no slide-outs; nil means not specified.
    var slideCount: Int? { get }
    var axleCount: Int? { get }
    var hasBunkhouse: Bool? { get }
    /// Optional registration, stored normalized: an uppercase VIN without spaces or dashes, an
    /// uppercase plate, and the state or province that issued it.
    var vin: String { get }
    var licensePlate: String { get }
    var plateRegion: String { get }
}

public extension RigDetails {
    var displayName: String {
        let name = [make, model, floorplan].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? type.title : name
    }
    /// Short owner-entered facts, e.g. "2024 · 19 ft · 1 slide · Bunkhouse".
    var detailSummary: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let lengthFeet { parts.append(String(format: "%g ft", lengthFeet)) }
        if let slideCount, slideCount > 0 { parts.append(slideCount == 1 ? "1 slide" : "\(slideCount) slides") }
        if let axleCount { parts.append(axleCount == 1 ? "1 axle" : "\(axleCount) axles") }
        if hasBunkhouse == true { parts.append("Bunkhouse") }
        return parts.joined(separator: " · ")
    }
    /// The plate and where it's registered, e.g. "8ABC123 · CA". Empty without a plate.
    var plateSummary: String {
        [licensePlate, plateRegion].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// RVs need year, make, model, and length; tents and car camping need none of them.
    /// Checked when the owner saves the form, never on load, so a synced rig always stays readable.
    func validateDetails() throws {
        if type.isRV {
            guard let year, !make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let lengthFeet else {
                throw CampError.incompleteRig
            }
            guard RigDraft.yearRange.contains(year), lengthFeet.isFinite, RigDraft.lengthRange.contains(lengthFeet) else {
                throw CampError.invalidRigDetails
            }
        } else if let year, !RigDraft.yearRange.contains(year) {
            throw CampError.invalidRigDetails
        }
        if let slideCount, !RigDraft.slideRange.contains(slideCount) { throw CampError.invalidRigDetails }
        if let axleCount, !RigDraft.axleRange.contains(axleCount) { throw CampError.invalidRigDetails }
        try validateRegistration()
    }
    /// The VIN and plate are optional, but an entered one must be readable at a check-in desk.
    func validateRegistration() throws {
        let normalizedVIN = RigDraft.normalizedVIN(vin)
        if !normalizedVIN.isEmpty, !RigDraft.isValidVIN(normalizedVIN, year: year) { throw CampError.invalidVIN }
        if RigDraft.normalizedPlate(licensePlate).count > RigDraft.maxPlateLength { throw CampError.invalidPlate }
    }
    var hasRequiredDetails: Bool { (try? validateDetails()) != nil }
    var detailsProblem: String? {
        do { try validateDetails(); return nil } catch { return (error as? CampError)?.errorDescription }
    }
    var registrationProblem: String? {
        do { try validateRegistration(); return nil } catch { return (error as? CampError)?.errorDescription }
    }
}

/// The rig form's editable copy. Saving applies it to the stored rig.
public struct RigDraft: RigDetails, Equatable, Codable, Sendable {
    public var type: RigType
    public var make: String
    public var model: String
    public var year: Int?
    public var floorplan: String
    public var emoji: String
    /// A resized JPEG, or nil to show the emoji.
    public var photo: Data?
    public var equipment: Equipment
    public var lengthFeet: Double?
    public var slideCount: Int?
    public var axleCount: Int?
    public var hasBunkhouse: Bool?
    /// As typed; saving stores the normalized forms.
    public var vin: String
    public var licensePlate: String
    public var plateRegion: String
    /// Exports leave the photo out; it is shared separately.
    private enum CodingKeys: String, CodingKey {
        case type, make, model, year, floorplan, emoji, equipment, lengthFeet, slideCount, axleCount, hasBunkhouse
        case vin, licensePlate, plateRegion
    }
    public init(type: RigType = .travelTrailer, make: String = "", model: String = "", year: Int? = nil,
                floorplan: String = "", emoji: String = "🚐", photo: Data? = nil, equipment: Equipment = Equipment(),
                lengthFeet: Double? = nil, slideCount: Int? = nil, axleCount: Int? = nil, hasBunkhouse: Bool? = nil,
                vin: String = "", licensePlate: String = "", plateRegion: String = "") {
        self.type = type; self.make = make; self.model = model; self.year = year
        self.floorplan = floorplan; self.emoji = emoji; self.photo = photo
        self.equipment = equipment; self.lengthFeet = lengthFeet; self.slideCount = slideCount
        self.axleCount = axleCount; self.hasBunkhouse = hasBunkhouse
        self.vin = vin; self.licensePlate = licensePlate; self.plateRegion = plateRegion
    }

    public static let yearRange = 1950...2100
    public static let lengthRange = 5.0...65.0
    public static let slideRange = 0...8
    public static let axleRange = 1...4
    /// Vehicles built for the 1981 model year on carry the standard 17-character VIN.
    public static let standardVINYear = 1981
    public static let maxPlateLength = 12

    /// Uppercase, without the spaces and dashes people type to group the characters.
    public static func normalizedVIN(_ text: String) -> String {
        String(text.uppercased().filter { !$0.isWhitespace && $0 != "-" })
    }
    /// A standard VIN is 17 letters and digits without I, O, or Q, which read as 1 and 0. Older
    /// vehicles used shorter manufacturer serials, so a known pre-1981 year accepts 1–17 letters and digits.
    /// The check digit isn't verified: it's only required in North America.
    public static func isValidVIN(_ vin: String, year: Int?) -> Bool {
        let isAlphanumeric = vin.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if let year, year < standardVINYear { return isAlphanumeric && (1...17).contains(vin.count) }
        return isAlphanumeric && vin.count == 17 && !vin.contains { "IOQ".contains($0) }
    }
    /// Uppercase with surrounding and repeated spaces removed; plates keep their own spacing and dashes.
    public static func normalizedPlate(_ text: String) -> String {
        text.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// True once any required field has a value, so a blank form doesn't open with an error.
    public var hasStartedDetails: Bool {
        year != nil || lengthFeet != nil || !make.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !Self.normalizedVIN(vin).isEmpty || !Self.normalizedPlate(licensePlate).isEmpty
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
        vin = ""; licensePlate = ""; plateRegion = ""
    }
    /// The draft as it's stored: registration normalized and trimmed, and cleared for a tent.
    public var normalized: RigDraft {
        var draft = self
        draft.vin = type.hasRegistration ? Self.normalizedVIN(vin) : ""
        draft.licensePlate = type.hasRegistration ? Self.normalizedPlate(licensePlate) : ""
        draft.plateRegion = type.hasRegistration ? plateRegion.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return draft
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

/// The single place the active-rig limit lives. A future paid tier changes only this value
/// (sold through StoreKit in-app purchase).
public enum RigPolicy {
    public static let maxActiveRigs = 1
}
