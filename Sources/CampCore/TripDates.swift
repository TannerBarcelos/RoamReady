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
}
