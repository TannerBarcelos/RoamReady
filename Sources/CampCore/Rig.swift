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
    }
    var hasRequiredDetails: Bool { (try? validateDetails()) != nil }
    var detailsProblem: String? {
        do { try validateDetails(); return nil } catch { return (error as? CampError)?.errorDescription }
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
    /// Exports leave the photo out; it is shared separately.
    private enum CodingKeys: String, CodingKey {
        case type, make, model, year, floorplan, emoji, equipment, lengthFeet, slideCount, axleCount, hasBunkhouse
    }
    public init(type: RigType = .travelTrailer, make: String = "", model: String = "", year: Int? = nil,
                floorplan: String = "", emoji: String = "🚐", photo: Data? = nil, equipment: Equipment = Equipment(),
                lengthFeet: Double? = nil, slideCount: Int? = nil, axleCount: Int? = nil, hasBunkhouse: Bool? = nil) {
        self.type = type; self.make = make; self.model = model; self.year = year
        self.floorplan = floorplan; self.emoji = emoji; self.photo = photo
        self.equipment = equipment; self.lengthFeet = lengthFeet; self.slideCount = slideCount
        self.axleCount = axleCount; self.hasBunkhouse = hasBunkhouse
    }

    public static let yearRange = 1950...2100
    public static let lengthRange = 5.0...65.0
    public static let slideRange = 0...8
    public static let axleRange = 1...4

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

/// The single place the active-rig limit lives. A future paid tier changes only this value
/// (sold through StoreKit in-app purchase).
public enum RigPolicy {
    public static let maxActiveRigs = 1
}
