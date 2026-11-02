import Foundation

/// The units an ingredient's amount is chosen from. The raw value is what is stored (and synced), so
/// it must never change; `title` is what the owner sees.
public enum IngredientUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case lb, oz, g, kg
    case gal, qt, pt, cup, flOz, tbsp, tsp, liter, milliliter
    case dozen, pack, can, bottle, bag, box, bunch, loaf, slice
    public var id: String { rawValue }
    /// Short and not pluralized, so "1 can" and "2 can" read the same everywhere.
    public var title: String {
        switch self {
        case .flOz: "fl oz"
        case .liter: "L"
        case .milliliter: "mL"
        default: rawValue
        }
    }
}

/// A positive number and an optional unit, like "2 lb", "1½ cup", or "6". Amounts with the same unit
/// add up; amounts with different units, or one with none, never do.
public struct IngredientAmount: Equatable, Codable, Sendable {
    public let value: Double
    public let unit: IngredientUnit?

    /// Nil unless `value` is finite and greater than zero.
    public init?(_ value: Double, unit: IngredientUnit? = nil) {
        guard value.isFinite, value > 0 else { return nil }
        self.value = value; self.unit = unit
    }

    private enum CodingKeys: String, CodingKey { case value, unit }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Double.self, forKey: .value)
        guard let amount = IngredientAmount(value, unit: try container.decodeIfPresent(IngredientUnit.self, forKey: .unit)) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "An amount is a positive number.")
        }
        self = amount
    }

    /// "2 lb", "1½ cup", "6", "0.58 oz". The number alone when there's no unit.
    public var text: String { unit.map { "\(Self.text(for: value)) \($0.title)" } ?? Self.text(for: value) }

    /// The sum when both use the same unit, otherwise nil.
    public func adding(_ other: IngredientAmount) -> IngredientAmount? {
        guard unit == other.unit else { return nil }
        return IngredientAmount(value + other.value, unit: unit)
    }

    /// One total per unit, in the order each unit first appears. "No unit" is its own group.
    /// A total may not be one of `choices`; show it with `text`.
    public static func totals(of amounts: [IngredientAmount]) -> [IngredientAmount] {
        var order: [IngredientUnit?] = [], sums: [IngredientUnit?: Double] = [:]
        for amount in amounts {
            if sums[amount.unit] == nil { order.append(amount.unit) }
            sums[amount.unit, default: 0] += amount.value
        }
        return order.compactMap { unit in sums[unit].flatMap { IngredientAmount($0, unit: unit) } }
    }

    // MARK: Choices

    /// What the Amount picker offers besides "None": common fractions, then whole numbers up to 50.
    public static let choices: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 1, 1.5, 2, 2.5, 3] + (4...50).map(Double.init)

    /// `choices`, plus `current` in its place when it isn't one of them (for example a value another app
    /// version saved), so a picker can still show it.
    public static func choices(including current: Double?) -> [Double] {
        guard let current, current.isFinite, current > 0, !choices.contains(where: { matches($0, current) }) else { return choices }
        return (choices + [current]).sorted()
    }

    /// True when two amounts differ only by floating-point error.
    public static func matches(_ a: Double, _ b: Double) -> Bool { abs(a - b) < tolerance }

    // MARK: Formatting

    private static let tolerance = 1e-6
    private static let fractions: [(numerator: Int, denominator: Int, glyph: String)] = [
        (1, 8, "⅛"), (1, 6, "⅙"), (1, 4, "¼"), (1, 3, "⅓"), (3, 8, "⅜"), (1, 2, "½"),
        (5, 8, "⅝"), (2, 3, "⅔"), (3, 4, "¾"), (5, 6, "⅚"), (7, 8, "⅞"),
    ]

    /// A whole number, or a whole number with the nearest common fraction when the value is that
    /// fraction (so 1/3 + 1/3 reads "⅔"), otherwise at most 2 decimals. The decimal separator is
    /// always ".", so a total reads the same in every locale.
    public static func text(for value: Double) -> String {
        guard value.isFinite else { return "" }
        if value < 1_000_000 {
            let whole = value.rounded(.down)
            let remainder = value - whole
            if remainder < tolerance { return String(Int(whole)) }
            if 1 - remainder < tolerance { return String(Int(whole) + 1) }
            if let match = fractions.first(where: { matches(Double($0.numerator) / Double($0.denominator), remainder) }) {
                return (whole > 0 ? String(Int(whole)) : "") + match.glyph
            }
        }
        var decimal = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while decimal.hasSuffix("0") { decimal.removeLast() }
        if decimal.hasSuffix(".") { decimal.removeLast() }
        return decimal
    }
}
