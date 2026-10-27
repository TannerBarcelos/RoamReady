import SwiftUI
import SwiftData
import CampCore
import Campgrounds
import CampPersistence

struct NewTripView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @Query private var trips: [Trip]
    var initialListing: CampgroundListing? = nil
    @State private var draft = TripDraft.new()
    @State private var rig: Rig?
    @State private var selected: CampgroundListing?
    @State private var choosing = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Campground name", text: $draft.campgroundName)
                        .onChange(of: draft.campgroundName) { _, value in if selected?.name != value { select(nil) } }
                    Button("Choose from Camp Finder", systemImage: "map") { choosing = true }
                        .disabled(!connectivity.isOnline)
                } header: { Text("Campground") } footer: {
                    Text(connectivity.isOnline
                         ? "Reserve with the campground or its provider first, then enter the booking here. RoamReady never books."
                         : "You’re offline, so enter the campground by name. Camp Finder needs a connection.")
                }
                RigPickerSection(rig: $rig, rigs: rigs.active)
                TripDatesSection(draft: $draft)
                BookingFormSections(trip: $draft, rig: rig, includesSiteNotes: true)
                Section {
                    Label("Setup & teardown included", systemImage: "checklist")
                    Text("The trip gets its own copy of your rig’s default checklists. Changing it never changes your defaults.").foregroundStyle(.secondary)
                }
                if selected != nil { WeatherSection(trip: draft) }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("Add trip").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            guard let rig else { throw CampUIError.missingRig }
                            var trip = draft
                            // Entered by name: a local identity, shared with earlier trips to the same place.
                            if trip.campgroundID == nil {
                                trip.campgroundID = CampgroundIdentity.local(named: trip.campgroundName,
                                                                             among: trips.map { ($0.campgroundID, $0.campgroundName) })
                            }
                            try Trip.create(trip, rig: rig, in: context)
                            library.save()
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.disabled(draft.campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rig == nil)
                }
            }
            .sheet(isPresented: $choosing) {
                NavigationStack { CampgroundPicker { place in select(place); choosing = false } }
            }
            .environment(\.timeZone, draft.planningTimeZone)
            .onAppear {
                if rig == nil { rig = rigs.active.first }
                if let initialListing, selected == nil { select(initialListing) }
            }
        }
    }
    /// Prefills the Apple Maps identity, name, location, and time zone. The name becomes the
    /// owner's own record and stays readable even if Apple Maps stops listing the place.
    private func select(_ place: CampgroundListing?) {
        selected = place
        draft.setCampground(id: place?.id, name: place?.name, latitude: place?.latitude, longitude: place?.longitude,
                            timeZoneIdentifier: place?.timeZoneIdentifier)
    }
}

/// The rig picker. v1 allows one active rig, so it lists that rig, pre-selected. Editing a trip
/// also lists the trip's own rig when it's archived.
struct RigPickerSection: View {
    @Binding var rig: Rig?
    let rigs: [Rig]
    var body: some View {
        Section {
            if rigs.isEmpty {
                Text("Add a rig in Profile before adding a trip.").foregroundStyle(.secondary)
            } else {
                Picker("Rig", selection: $rig) {
                    ForEach(rigs) { choice in
                        Text(choice.isArchived ? "\(choice.displayName) (archived)" : choice.displayName).tag(Optional(choice))
                    }
                    if rig == nil { Text("Rig unavailable").tag(Rig?.none) }
                }
            }
        } header: { Text("Rig") }
    }
}

struct TripDatesSection: View {
    @Binding var draft: TripDraft
    var body: some View {
        Section("Dates") {
            DatePicker("Arrival", selection: $draft.arrival, displayedComponents: .date)
                .onChange(of: draft.arrival) { _, value in if draft.departure < value { draft.departure = value } }
            DatePicker("Departure", selection: $draft.departure, in: draft.arrival..., displayedComponents: .date)
        }
    }
}

/// Site and booking fields, all optional so walk-up and first-come sites work. Editable at any time.
struct BookingFormSections: View {
    @Binding var trip: TripDraft
    /// The trip's rig, to warn when it's longer than the site.
    let rig: Rig?
    /// Adding a trip also takes first site notes; after that, notes and photos live in Photos & site notes.
    var includesSiteNotes = false
    var body: some View {
        Section {
            TextField("Site number", text: $trip.siteNumber)
            TextField("Loop", text: text(\.loop))
            Picker("Parking", selection: site(\.parking)) {
                Text("Not entered").tag(SiteParking?.none)
                ForEach(SiteParking.allCases) { Text($0.title).tag(Optional($0)) }
            }
            TextField("Site length limit (ft)", value: site(\.maxLengthFeet), format: .number).keyboardType(.decimalPad)
            Picker("Electric", selection: site(\.electric)) {
                Text("Not entered").tag(SiteElectric?.none)
                ForEach(SiteElectric.allCases) { Text($0.title).tag(Optional($0)) }
            }
            Picker("Water at site", selection: site(\.water)) { yesNoOptions }
            Picker("Sewer at site", selection: site(\.sewer)) { yesNoOptions }
            if includesSiteNotes {
                TextField("Site notes (shade, slope, neighbors…)", text: $trip.notes, axis: .vertical).lineLimit(2...6)
            }
        } header: { Text("Site (optional)") } footer: {
            if let details = trip.site, (try? details.validate()) == nil {
                Text(CampError.invalidSiteLength.localizedDescription).foregroundStyle(.red)
            } else if let rig, let details = trip.site, details.isTooShort(for: rig), let limit = details.maxLengthFeet {
                Text("\(rig.displayName) is longer than this site’s \(limit.formatted()) ft limit.").foregroundStyle(.orange)
            } else {
                Text("Campground listings don’t include site details. Copy them from your reservation or add them when you arrive. Add photos and more notes any time from Photos & site notes.")
            }
        }
        Section {
            TextField("Confirmation number", text: text(\.confirmationNumber))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            TextField("Booked through (e.g. Recreation.gov)", text: text(\.bookingProvider))
            TextField("Manage-booking link (https://…)", text: text(\.bookingURL))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("Booking (optional)") } footer: {
            if let url = trip.bookingURL, !url.isEmpty, trip.bookingLink == nil {
                Text(CampError.invalidBookingLink.localizedDescription).foregroundStyle(.red)
            } else {
                Text("Add or change these any time. Attach your confirmation file from the trip’s Booking section.")
            }
        }
        Section {
            Picker("Campground time zone", selection: Binding(
                get: { trip.campgroundCalendar.timeZone.identifier },
                set: { trip.campgroundTimeZoneIdentifier = $0 })) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                    Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                }
            }
            .pickerStyle(.navigationLink)
            TimeOfDayRow(title: "Check-in time", minutes: $trip.checkInMinutes)
            TimeOfDayRow(title: "Check-out time", minutes: $trip.checkOutMinutes)
        } header: { Text("Check-in & check-out") } footer: {
            if let checkIn = trip.checkInDate, let checkOut = trip.checkOutDate, checkOut <= checkIn {
                Text(CampError.invalidCheckTimes.localizedDescription).foregroundStyle(.red)
            } else {
                Text("Times use \(trip.campgroundCalendar.timeZone.identifier.replacingOccurrences(of: "_", with: " ")). Check the time zone against your reservation, especially when entering a campground by name.")
            }
        }
        Section("Cost") {
            TextField("Total cost", value: $trip.totalCost, format: .currency(code: currencyCode)).keyboardType(.decimalPad)
            TextField("Amount paid", value: $trip.amountPaid, format: .currency(code: currencyCode)).keyboardType(.decimalPad)
            Toggle("Cancellation deadline", isOn: Binding(
                get: { trip.cancellationDeadline != nil },
                set: { trip.cancellationDeadline = $0 ? (trip.cancellationDeadline ?? trip.arrival) : nil }))
            if let deadline = trip.cancellationDeadline {
                DatePicker("Deadline", selection: Binding(get: { deadline }, set: { trip.cancellationDeadline = $0 }))
            }
        }
    }
    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }
    private func text(_ keyPath: WritableKeyPath<TripDraft, String?>) -> Binding<String> {
        Binding(get: { trip[keyPath: keyPath] ?? "" }, set: { trip[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
    /// Edits one site field; the trip stores no site details until one is entered.
    private func site<Value>(_ keyPath: WritableKeyPath<SiteDetails, Value>) -> Binding<Value> {
        Binding(get: { (trip.site ?? SiteDetails())[keyPath: keyPath] },
                set: { value in
                    var details = trip.site ?? SiteDetails()
                    details[keyPath: keyPath] = value
                    trip.site = details.isEmpty ? nil : details
                })
    }
    @ViewBuilder private var yesNoOptions: some View {
        Text("Not entered").tag(Bool?.none)
        Text("Yes").tag(Bool?.some(true))
        Text("No").tag(Bool?.some(false))
    }
}

/// A local time of day stored as minutes after midnight, independent of the phone's time zone.
struct TimeOfDayRow: View {
    let title: String
    @Binding var minutes: Int?
    private static let utc = TimeZone(identifier: "UTC")!
    var body: some View {
        Toggle(title, isOn: Binding(get: { minutes != nil }, set: { minutes = $0 ? (minutes ?? 15 * 60) : nil }))
        if let value = minutes {
            DatePicker(title, selection: Binding(
                get: { Date(timeIntervalSinceReferenceDate: Double(value * 60)) },
                set: { date in
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = Self.utc
                    let parts = calendar.dateComponents([.hour, .minute], from: date)
                    minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.timeZone, Self.utc)
                .accessibilityLabel(title)
        }
    }
}
