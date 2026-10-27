import Foundation

/// A bounded snapshot of useful rig facts. Registration and photo data are deliberately excluded.
/// Construct it while reading the library, before handing the request to an async generator.
public struct CampingRigContext: Sendable {
    public let type: RigType
    private let make: String
    private let model: String
    private let year: Int?
    private let floorplanCode: String
    private let lengthFeet: Double?
    private let slideCount: Int?
    private let axleCount: Int?
    private let hasBunkhouse: Bool?
    private let equipment: Equipment

    public init(_ rig: some RigDetails) {
        type = rig.type
        make = Self.bounded(rig.make)
        model = Self.bounded(rig.model)
        year = rig.year
        floorplanCode = Self.bounded(rig.floorplan)
        lengthFeet = rig.lengthFeet.flatMap { $0.isFinite ? $0 : nil }
        slideCount = rig.slideCount
        axleCount = rig.axleCount
        hasBunkhouse = rig.hasBunkhouse
        equipment = rig.equipment
    }

    /// Explicit labels separate identifiers from dimensions for the small on-device model.
    /// Owner-entered strings stay JSON-quoted rather than becoming prompt instructions.
    var reference: String {
        var facts = ["Rig category: \(type.title)"]
        if !make.isEmpty { facts.append("Manufacturer: \(Self.quoted(make))") }
        if !model.isEmpty { facts.append("Model name: \(Self.quoted(model))") }
        if let year { facts.append("Model year: \(year)") }
        if !floorplanCode.isEmpty { facts.append("Floorplan code: \(Self.quoted(floorplanCode)) (identifier, not a length)") }
        if let lengthFeet { facts.append("Overall length: \(String(format: "%g", lengthFeet)) ft") }
        if let slideCount { facts.append("Slide-out count: \(slideCount)") }
        else { facts.append("Slide-outs selected: \(Self.yesNo(equipment.slideOuts))") }
        if let axleCount { facts.append("Axle count: \(axleCount)") }
        if let hasBunkhouse { facts.append("Bunkhouse: \(Self.yesNo(hasBunkhouse))") }
        facts += ["Shore power selected: \(Self.yesNo(equipment.shorePower))",
                  "Fresh water selected: \(Self.yesNo(equipment.freshWater))",
                  "Wastewater connection selected: \(Self.yesNo(equipment.sewer))",
                  "Propane selected: \(Self.yesNo(equipment.propane))"]
        return facts.joined(separator: "\n")
    }

    private static func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    private static func bounded(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }
}
