import Foundation

/// A bounded snapshot of useful rig facts. Registration and photo data are deliberately excluded.
/// Construct it while reading the library, before handing the request to an async generator.
public struct CampingRigContext: Encodable, Sendable {
    public let type: RigType
    private let make: String
    private let model: String
    private let year: Int?
    private let floorplan: String
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
        floorplan = Self.bounded(rig.floorplan)
        lengthFeet = rig.lengthFeet.flatMap { $0.isFinite ? $0 : nil }
        slideCount = rig.slideCount
        axleCount = rig.axleCount
        hasBunkhouse = rig.hasBunkhouse
        equipment = rig.equipment
    }

    /// JSON keeps owner-entered text quoted rather than interpolating it as prompt instructions.
    var reference: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "Rig category: \(type.title)"
        }
        return text
    }

    private static func bounded(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }
}
