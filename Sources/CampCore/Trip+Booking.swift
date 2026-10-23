import Foundation

/// A trip is one booking at one campground. These helpers keep the booking fields together.
public extension Trip {
    /// Copies the user-entered booking fields (not the campground, dates, rig, or checklists).
    mutating func copyBookingDetails(from other: Trip) {
        siteNumber = other.siteNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        loop = Self.cleaned(other.loop)
        site = other.site.flatMap { $0.isEmpty ? nil : $0 }
        confirmationNumber = Self.cleaned(other.confirmationNumber)
        bookingProvider = Self.cleaned(other.bookingProvider)
        bookingURL = Self.cleaned(other.bookingURL)
        checkInMinutes = other.checkInMinutes; checkOutMinutes = other.checkOutMinutes
        totalCost = other.totalCost; amountPaid = other.amountPaid
        cancellationDeadline = other.cancellationDeadline
    }

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

    /// Empty or whitespace-only text is stored as "not entered".
    static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
