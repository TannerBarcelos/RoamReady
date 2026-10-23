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

public struct TripPhoto: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var filename: String
    public var caption: String
    public var createdAt: Date
    public init(id: UUID = UUID(), filename: String, caption: String = "", createdAt: Date = Date()) {
        self.id = id; self.filename = filename; self.caption = caption; self.createdAt = createdAt
    }
}

public struct Trip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var campgroundName: String
    public var latitude: Double?
    public var longitude: Double?
    public var arrival: Date
    public var departure: Date
    public var siteNumber: String
    public var notes: String
    public var rating: SiteRating
    public var setup: [ChecklistItem]
    public var teardown: [ChecklistItem]
    public var photos: [TripPhoto]
    /// A reference to the rig in `AppState.rigs`. The UI reads the rig's current details through it;
    /// a missing rig shows as "Rig unavailable". Nil only for trips saved without a rig.
    public var rigID: UUID?
    public var campgroundID: String?
    public var planningTimeZoneIdentifier: String?
    public var campgroundTimeZoneIdentifier: String?

    // Booking details, all optional and entered by the user. A trip is one booking at one campground.
    public var loop: String?
    /// The booked site's parking, length limit, and hookups. Nil until the owner enters any.
    public var site: SiteDetails?
    public var confirmationNumber: String?
    /// Who it was booked through, e.g. Recreation.gov or the campground directly.
    public var bookingProvider: String?
    /// The manage-booking page. `https` only.
    public var bookingURL: String?
    /// Minutes after midnight in the campground's time zone, on the arrival and departure days.
    public var checkInMinutes: Int?
    public var checkOutMinutes: Int?
    public var totalCost: Double?
    public var amountPaid: Double?
    /// Display only; the app never sends reminders.
    public var cancellationDeadline: Date?
    /// Set when the owner marks the trip complete before it ends. A trip also counts as complete,
    /// with nothing stored, once its departure day is over (`isCompleted(asOf:)`).
    public var completedAt: Date?

    public init(id: UUID = UUID(), campgroundName: String, latitude: Double? = nil, longitude: Double? = nil,
                arrival: Date, departure: Date, siteNumber: String = "", notes: String = "",
                rating: SiteRating = .unrated, setup: [ChecklistItem] = [],
                teardown: [ChecklistItem] = [], photos: [TripPhoto] = [], rigID: UUID? = nil,
                campgroundID: String? = nil, planningTimeZoneIdentifier: String? = nil,
                campgroundTimeZoneIdentifier: String? = nil) {
        self.id = id; self.campgroundName = campgroundName; self.latitude = latitude; self.longitude = longitude
        self.arrival = arrival; self.departure = departure; self.siteNumber = siteNumber; self.notes = notes
        self.rating = rating; self.setup = setup; self.teardown = teardown; self.photos = photos
        self.rigID = rigID; self.campgroundID = campgroundID
        self.planningTimeZoneIdentifier = planningTimeZoneIdentifier
        self.campgroundTimeZoneIdentifier = campgroundTimeZoneIdentifier
    }
    /// Creating a trip is the only way it gets checklists: fresh copies of the rig's defaults
    /// (or, when the rig has none yet, the lists generated from its type). After this the trip's
    /// lists are independent of the rig's defaults.
    public static func create(campgroundName: String, arrival: Date, departure: Date, rig: Rig,
                              defaults: ChecklistTemplates? = nil, latitude: Double? = nil,
                              longitude: Double? = nil, campgroundID: String? = nil,
                              campgroundTimeZoneIdentifier: String? = nil) throws -> Trip {
        let source = defaults ?? ChecklistFactory.templates(for: rig)
        let trip = Trip(campgroundName: campgroundName.trimmingCharacters(in: .whitespacesAndNewlines),
                        latitude: latitude, longitude: longitude, arrival: arrival, departure: departure,
                        setup: source.setup.map { $0.freshCopy() }, teardown: source.teardown.map { $0.freshCopy() },
                        rigID: rig.id, campgroundID: campgroundID, planningTimeZoneIdentifier: TimeZone.current.identifier,
                        campgroundTimeZoneIdentifier: campgroundTimeZoneIdentifier)
        try trip.validate()
        return trip
    }
    public var setupProgress: Double { Self.progress(setup) }
    public var teardownProgress: Double { Self.progress(teardown) }
    private static func progress(_ items: [ChecklistItem]) -> Double {
        items.isEmpty ? 0 : Double(items.filter(\.isFinished).count) / Double(items.count)
    }
    public func validate() throws {
        guard !campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CampError.missingCampground
        }
        guard arrival.timeIntervalSince1970.isFinite, departure.timeIntervalSince1970.isFinite,
              departure >= arrival else { throw CampError.invalidDates }
        guard (latitude == nil) == (longitude == nil) else { throw CampError.invalidCoordinates }
        if let latitude, let longitude {
            guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else { throw CampError.invalidCoordinates }
        }
        try validateChecklist(setup + teardown)
        guard Set(photos.map(\.id)).count == photos.count else { throw CampError.duplicateIdentifiers }
        for photo in photos { try validateFilename(photo.filename) }
        try validateBookingValues()
    }

    public static let minutesPerDay = 24 * 60

    /// Everything the booking form checks, including that check-out comes after check-in. Called when
    /// the owner creates or edits a trip, not on load: two devices editing dates and times separately
    /// could merge into an order that must not make the library unreadable.
    public func validateBooking() throws {
        try validateBookingValues()
        if let checkIn = checkInDate, let checkOut = checkOutDate, checkOut <= checkIn { throw CampError.invalidCheckTimes }
    }

    /// Per-field checks that a sync merge can't violate.
    func validateBookingValues() throws {
        if let bookingURL, !bookingURL.isEmpty {
            guard let url = URL(string: bookingURL), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
                throw CampError.invalidBookingLink
            }
        }
        for minutes in [checkInMinutes, checkOutMinutes].compactMap({ $0 }) {
            guard (0..<Self.minutesPerDay).contains(minutes) else { throw CampError.invalidCheckTimes }
        }
        for amount in [totalCost, amountPaid].compactMap({ $0 }) {
            guard amount.isFinite, amount >= 0 else { throw CampError.invalidBookingAmount }
        }
        for date in [cancellationDeadline, completedAt].compactMap({ $0 }) {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw CampError.invalidDates }
        }
        try site?.validate()
    }
}

func validateFilename(_ filename: String) throws {
    guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
          !filename.contains("\\"), !filename.contains("\0") else { throw CampError.invalidPhotoFilename }
}
