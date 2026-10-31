import Foundation

/// The meals a trip day is planned around. Every day shows the standard four; `other` is a meal the
/// owner added and named, like "Second breakfast".
public enum MealKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack, other
    public var id: String { rawValue }
    public static let standard: [MealKind] = [.breakfast, .lunch, .dinner, .snack]
    public var isStandard: Bool { self != .other }
    public var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snacks"
        case .other: "Meal"
        }
    }
    public var systemImage: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "carrot"
        case .other: "fork.knife"
        }
    }
}

/// One civil day of a trip, as planned. Meals store the offset, so moving a trip's dates keeps
/// each meal on the same day of the trip.
public struct MenuDay: Hashable, Identifiable, Sendable {
    /// 0 is the arrival day.
    public let offset: Int
    /// The start of the day in the trip's planning time zone.
    public let date: Date
    public var id: Int { offset }
    public var number: Int { offset + 1 }
    public init(offset: Int, date: Date) { self.offset = offset; self.date = date }
}

public enum MenuPolicy {
    /// A mistyped departure shouldn't build hundreds of days. Meals past this stay listed as outside the dates.
    public static let maxDays = 60
}

public extension TripDetails {
    /// Arrival day through departure day, inclusive, in the time zone the dates were chosen in.
    /// At most `MenuPolicy.maxDays`.
    var menuDays: [MenuDay] {
        guard let span = menuSpan else { return [] }
        return (0..<min(span.count, MenuPolicy.maxDays)).compactMap { offset in
            span.calendar.date(byAdding: .day, value: offset, to: span.first).map { MenuDay(offset: offset, date: $0) }
        }
    }

    /// True when the trip has more days than its menu lists.
    var menuIsTruncated: Bool { (menuSpan?.count ?? 0) > MenuPolicy.maxDays }

    private var menuSpan: (calendar: Calendar, first: Date, count: Int)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = planningTimeZone
        guard arrival.timeIntervalSince1970.isFinite, departure.timeIntervalSince1970.isFinite else { return nil }
        let first = calendar.startOfDay(for: arrival), last = calendar.startOfDay(for: departure)
        guard first <= last, let span = calendar.dateComponents([.day], from: first, to: last).day else { return nil }
        return (calendar, first, span + 1)
    }

    /// "Day 1 · Fri, Nov 6"
    func menuTitle(for day: MenuDay) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = planningTimeZone
        return "Day \(day.number) · " + day.date.formatted(style)
    }
}

/// A dish's editable text: one whole plate, like "Steak with brussels sprouts and sourdough".
public struct MenuDishDraft: Equatable, Codable, Sendable {
    public var name: String
    public var notes: String
    public init(name: String = "", notes: String = "") { self.name = name; self.notes = notes }
    public var hasName: Bool { !cleaned.name.isEmpty }
    public var cleaned: MenuDishDraft {
        MenuDishDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                      notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func validate() throws { guard hasName else { throw CampError.missingDishName } }
}

/// One part of a dish's recipe, with a free-text amount such as "2 lb" or "1 loaf".
public struct DishItemDraft: Equatable, Codable, Sendable {
    public var name: String
    public var quantity: String
    public init(name: String = "", quantity: String = "") { self.name = name; self.quantity = quantity }
    public var hasName: Bool { !cleaned.name.isEmpty }
    public var cleaned: DishItemDraft {
        DishItemDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                      quantity: quantity.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func validate() throws { guard hasName else { throw CampError.missingItemName } }
}

/// The name of a meal the owner adds to a day.
public struct MealDraft: Equatable, Codable, Sendable {
    public var title: String
    public init(title: String = "") { self.title = title }
    public var hasTitle: Bool { !cleaned.title.isEmpty }
    public var cleaned: MealDraft { MealDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines)) }
    public func validate() throws { guard hasTitle else { throw CampError.missingMealName } }
}

/// What a trip's menu row says: "Create menu" until a dish is planned.
public struct MenuSummary: Equatable, Sendable {
    public let dishCount: Int
    public let plannedMeals: Int
    public init(dishCount: Int, plannedMeals: Int) { self.dishCount = dishCount; self.plannedMeals = plannedMeals }
    public var isEmpty: Bool { dishCount == 0 }
    public var title: String { isEmpty ? "Create menu" : "Menu" }
    /// "3 dishes · 2 meals", or nil before anything is planned.
    public var detail: String? {
        guard !isEmpty else { return nil }
        let dishes = dishCount == 1 ? "1 dish" : "\(dishCount) dishes"
        let meals = plannedMeals == 1 ? "1 meal" : "\(plannedMeals) meals"
        return "\(dishes) · \(meals)"
    }
}
