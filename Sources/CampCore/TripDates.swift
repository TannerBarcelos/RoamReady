import Foundation

public extension Trip {
    var campgroundCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = campgroundTimeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? planningTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        return calendar
    }

    /// A trip's chosen dates remain the same civil days when the phone travels.
    /// Forecast dates represent the campground's time zone, not the planner's.
    var forecastDayWindow: ClosedRange<Date>? {
        var planning = Calendar(identifier: .gregorian)
        planning.timeZone = planningTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        let destination = campgroundCalendar
        guard let start = destination.date(from: planning.dateComponents([.year, .month, .day], from: arrival)),
              let end = destination.date(from: planning.dateComponents([.year, .month, .day], from: departure)),
              start <= end else { return nil }
        return start...end
    }

    /// Complete when the owner marked it so, or once the day after departure has begun at the
    /// campground (#31). Derived from the dates, so it needs no background work and syncs as is.
    func isCompleted(asOf now: Date = Date()) -> Bool {
        if completedAt != nil { return true }
        guard let lastDay = forecastDayWindow?.upperBound,
              let dayAfter = campgroundCalendar.date(byAdding: .day, value: 1, to: lastDay) else { return false }
        return now >= dayAfter
    }
    /// Ended by its dates, as opposed to marked complete early.
    func endedByDate(asOf now: Date = Date()) -> Bool {
        var copy = self; copy.completedAt = nil
        return copy.isCompleted(asOf: now)
    }

    /// Check-in on the arrival day, at the campground's local time.
    var checkInDate: Date? { checkInMinutes.flatMap { campgroundInstant(onDayOf: arrival, minutes: $0) } }
    /// Check-out on the departure day, at the campground's local time.
    var checkOutDate: Date? { checkOutMinutes.flatMap { campgroundInstant(onDayOf: departure, minutes: $0) } }

    /// The chosen civil day (as planned) at a local time in the campground's time zone. A time that
    /// doesn't exist on a daylight-saving change day resolves forward, as the calendar does.
    private func campgroundInstant(onDayOf day: Date, minutes: Int) -> Date? {
        guard (0..<Trip.minutesPerDay).contains(minutes) else { return nil }
        var planning = Calendar(identifier: .gregorian)
        planning.timeZone = planningTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        var components = planning.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60; components.minute = minutes % 60
        return campgroundCalendar.date(from: components)
    }
}
