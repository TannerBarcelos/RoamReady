import Foundation

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

/// A trip is one booking at one campground. These are its user-entered facts, shared by the stored
/// trip and the form's draft so date, completion, and booking rules live in one place.
public protocol TripDetails {
    var campgroundName: String { get }
    var campgroundID: String? { get }
    var latitude: Double? { get }
    var longitude: Double? { get }
    var arrival: Date { get }
    var departure: Date { get }
    /// The time zone the dates were chosen in; they stay the same civil days when the phone travels.
    var planningTimeZoneIdentifier: String? { get }
    var campgroundTimeZoneIdentifier: String? { get }
    var siteNumber: String { get }
    var loop: String? { get }
    /// The booked site's parking, length limit, and hookups. Nil until the owner enters any.
    var site: SiteDetails? { get }
    var confirmationNumber: String? { get }
    /// Who it was booked through, e.g. Recreation.gov or the campground directly.
    var bookingProvider: String? { get }
    /// The manage-booking page. `https` only.
    var bookingURL: String? { get }
    /// Minutes after midnight in the campground's time zone, on the arrival and departure days.
    var checkInMinutes: Int? { get }
    var checkOutMinutes: Int? { get }
    var totalCost: Double? { get }
    var amountPaid: Double? { get }
    /// Display only; the app never sends reminders.
    var cancellationDeadline: Date? { get }
    /// Set when the owner marks the trip complete early. A trip also completes on its own once its
    /// departure day is over (`isCompleted(asOf:)`).
    var completedAt: Date? { get }
}

public let minutesPerDay = 24 * 60

public extension TripDetails {
    var planningTimeZone: TimeZone { planningTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }

    var campgroundCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = campgroundTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? planningTimeZone
        return calendar
    }

    /// The trip's civil days as the campground experiences them. Forecasts are matched against this.
    var forecastDayWindow: ClosedRange<Date>? {
        var planning = Calendar(identifier: .gregorian)
        planning.timeZone = planningTimeZone
        let destination = campgroundCalendar
        guard let start = destination.date(from: planning.dateComponents([.year, .month, .day], from: arrival)),
              let end = destination.date(from: planning.dateComponents([.year, .month, .day], from: departure)),
              start <= end else { return nil }
        return start...end
    }

    /// Complete when the owner marked it so, or once the day after departure has begun at the
    /// campground (#31). Derived from the dates, so it needs no background work and syncs as is.
    func isCompleted(asOf now: Date = Date()) -> Bool { completedAt != nil || endedByDate(asOf: now) }

    /// Ended by its dates, as opposed to marked complete early.
    func endedByDate(asOf now: Date = Date()) -> Bool {
        guard let lastDay = forecastDayWindow?.upperBound,
              let dayAfter = campgroundCalendar.date(byAdding: .day, value: 1, to: lastDay) else { return false }
        return now >= dayAfter
    }

    /// Check-in on the arrival day, at the campground's local time.
    var checkInDate: Date? { checkInMinutes.flatMap { campgroundInstant(onDayOf: arrival, minutes: $0) } }
    /// Check-out on the departure day, at the campground's local time.
    var checkOutDate: Date? { checkOutMinutes.flatMap { campgroundInstant(onDayOf: departure, minutes: $0) } }

    /// The manage-booking link, when it is a valid `https` URL.
    var bookingLink: URL? {
        guard let bookingURL, let url = URL(string: bookingURL), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    var hasBookingDetails: Bool {
        [loop, confirmationNumber, bookingProvider, bookingURL].contains { $0 != nil } || site != nil
            || checkInMinutes != nil || checkOutMinutes != nil || totalCost != nil || amountPaid != nil
            || cancellationDeadline != nil
    }

    /// Everything the trip form checks before saving. Never run on load: two devices editing dates
    /// and times separately can merge into an order that must not make the library unreadable.
    func validate() throws {
        guard !campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CampError.missingCampground }
        guard arrival.timeIntervalSince1970.isFinite, departure.timeIntervalSince1970.isFinite,
              departure >= arrival else { throw CampError.invalidDates }
        guard (latitude == nil) == (longitude == nil) else { throw CampError.invalidCoordinates }
        if let latitude, let longitude {
            guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else { throw CampError.invalidCoordinates }
        }
        if let bookingURL, !bookingURL.isEmpty, bookingLink == nil { throw CampError.invalidBookingLink }
        for minutes in [checkInMinutes, checkOutMinutes].compactMap({ $0 }) {
            guard (0..<minutesPerDay).contains(minutes) else { throw CampError.invalidCheckTimes }
        }
        if let checkIn = checkInDate, let checkOut = checkOutDate, checkOut <= checkIn { throw CampError.invalidCheckTimes }
        for amount in [totalCost, amountPaid].compactMap({ $0 }) {
            guard amount.isFinite, amount >= 0 else { throw CampError.invalidBookingAmount }
        }
        try site?.validate()
    }

    /// The chosen civil day (as planned) at a local time in the campground's time zone. A time that
    /// doesn't exist on a daylight-saving change day resolves forward, as the calendar does.
    private func campgroundInstant(onDayOf day: Date, minutes: Int) -> Date? {
        guard (0..<minutesPerDay).contains(minutes) else { return nil }
        var planning = Calendar(identifier: .gregorian)
        planning.timeZone = planningTimeZone
        var components = planning.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60; components.minute = minutes % 60
        return campgroundCalendar.date(from: components)
    }
}

/// The trip form's editable copy. Saving applies it to the stored trip.
public struct TripDraft: TripDetails, Equatable, Codable, Sendable {
    public var campgroundName: String
    public var campgroundID: String?
    public var latitude: Double?
    public var longitude: Double?
    public var arrival: Date
    public var departure: Date
    public var planningTimeZoneIdentifier: String?
    public var campgroundTimeZoneIdentifier: String?
    public var siteNumber = ""
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
    /// First site notes, taken when the trip is added. Later notes are edited on the trip itself.
    public var notes = ""

    public init(campgroundName: String = "", arrival: Date, departure: Date, campgroundID: String? = nil,
                latitude: Double? = nil, longitude: Double? = nil,
                planningTimeZoneIdentifier: String? = TimeZone.current.identifier, campgroundTimeZoneIdentifier: String? = nil) {
        self.campgroundName = campgroundName; self.arrival = arrival; self.departure = departure
        self.campgroundID = campgroundID; self.latitude = latitude; self.longitude = longitude
        self.planningTimeZoneIdentifier = planningTimeZoneIdentifier
        self.campgroundTimeZoneIdentifier = campgroundTimeZoneIdentifier
    }

    /// A copy of any trip's details, for editing.
    public init(_ trip: some TripDetails) {
        self.init(campgroundName: trip.campgroundName, arrival: trip.arrival, departure: trip.departure,
                  campgroundID: trip.campgroundID, latitude: trip.latitude, longitude: trip.longitude,
                  planningTimeZoneIdentifier: trip.planningTimeZoneIdentifier,
                  campgroundTimeZoneIdentifier: trip.campgroundTimeZoneIdentifier)
        siteNumber = trip.siteNumber; loop = trip.loop; site = trip.site; confirmationNumber = trip.confirmationNumber
        bookingProvider = trip.bookingProvider; bookingURL = trip.bookingURL
        checkInMinutes = trip.checkInMinutes; checkOutMinutes = trip.checkOutMinutes
        totalCost = trip.totalCost; amountPaid = trip.amountPaid
        cancellationDeadline = trip.cancellationDeadline; completedAt = trip.completedAt
    }

    /// Starting dates for a new trip: today and two nights later.
    public static func new(now: Date = Date(), calendar: Calendar = .current) -> TripDraft {
        let arrival = calendar.startOfDay(for: now)
        return TripDraft(arrival: arrival, departure: calendar.date(byAdding: .day, value: 2, to: arrival) ?? arrival)
    }

    /// Trims text and stores empty text as "not entered", ready to save.
    public var cleaned: TripDraft {
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        var copy = self
        copy.campgroundName = campgroundName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.siteNumber = siteNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.site = site.flatMap { $0.isEmpty ? nil : $0 }
        copy.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.loop = clean(loop); copy.confirmationNumber = clean(confirmationNumber)
        copy.bookingProvider = clean(bookingProvider); copy.bookingURL = clean(bookingURL)
        return copy
    }

    /// Sets the campground from a Camp Finder listing, or clears its location when `nil`.
    public mutating func setCampground(id: String?, name: String?, latitude: Double?, longitude: Double?, timeZoneIdentifier: String?) {
        if let name { campgroundName = name }
        campgroundID = id; self.latitude = latitude; self.longitude = longitude
        campgroundTimeZoneIdentifier = timeZoneIdentifier
    }
}
