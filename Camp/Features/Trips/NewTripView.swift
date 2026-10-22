import SwiftUI
import MapKit
import CampCore
import Campgrounds

struct NewTripView: View {
    @Environment(CampStore.self) private var store
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    var initialCampground: Campground? = nil
    @State private var draft = Trip(campgroundName: "", arrival: Calendar.current.startOfDay(for: .now),
                                    departure: Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now)) ?? .now,
                                    planningTimeZoneIdentifier: TimeZone.current.identifier)
    @State private var rigID: UUID?
    @State private var selected: Campground?
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
                RigPickerSection(rigID: $rigID, includeArchived: nil)
                Section("Dates") {
                    DatePicker("Arrival", selection: $draft.arrival, displayedComponents: .date)
                        .onChange(of: draft.arrival) { _, value in if draft.departure < value { draft.departure = value } }
                    DatePicker("Departure", selection: $draft.departure, in: draft.arrival..., displayedComponents: .date)
                }
                BookingFormSections(trip: $draft)
                Section {
                    Label("Setup & teardown included", systemImage: "checklist")
                    Text("The trip gets its own copy of your rig’s default checklists. Changing it never changes your defaults.").foregroundStyle(.secondary)
                }
                if let selected {
                    WeatherSection(trip: Trip(campgroundName: draft.campgroundName, latitude: selected.latitude, longitude: selected.longitude,
                        arrival: draft.arrival, departure: draft.departure, planningTimeZoneIdentifier: TimeZone.current.identifier,
                        campgroundTimeZoneIdentifier: selected.timeZoneIdentifier))
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("Add trip").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            guard let rigID else { throw CampUIError.missingRig }
                            try store.createTrip(from: draft, rigID: rigID)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.disabled(draft.campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rigID == nil)
                }
            }
            .sheet(isPresented: $choosing) {
                NavigationStack { CampgroundPicker { place in select(place); choosing = false } }
            }
            .onAppear {
                if rigID == nil { rigID = store.activeRig?.id }
                if let initialCampground, selected == nil { select(initialCampground) }
            }
        }
    }
    private func select(_ place: Campground?) {
        selected = place
        if let place { draft.campgroundName = place.name }
        draft.campgroundID = place?.id; draft.latitude = place?.latitude; draft.longitude = place?.longitude
        draft.campgroundTimeZoneIdentifier = place?.timeZoneIdentifier
    }
}

/// The rig picker. v1 allows one active rig, so it lists that rig, pre-selected.
/// `includeArchived` keeps a trip's current archived rig selectable when editing.
struct RigPickerSection: View {
    @Environment(CampStore.self) private var store
    @Binding var rigID: UUID?
    let includeArchived: UUID?
    var choices: [Rig] {
        store.state.activeRigs + store.state.archivedRigs.filter { $0.id == includeArchived }
    }
    var body: some View {
        Section {
            if choices.isEmpty {
                Text("Add a rig in Profile before adding a trip.").foregroundStyle(.secondary)
            } else {
                Picker("Rig", selection: $rigID) {
                    ForEach(choices) { rig in
                        Text(rig.isArchived ? "\(rig.displayName) (archived)" : rig.displayName).tag(Optional(rig.id))
                    }
                    if rigID != nil && store.state.rig(rigID) == nil { Text("Rig unavailable").tag(rigID) }
                }
            }
        } header: { Text("Rig") }
    }
}

/// Booking fields, all optional so walk-up and first-come sites work. Editable at any time.
struct BookingFormSections: View {
    @Binding var trip: Trip
    var body: some View {
        Section {
            TextField("Site number", text: $trip.siteNumber)
            TextField("Loop", text: text(\.loop))
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
            TimeOfDayRow(title: "Check-in time", minutes: $trip.checkInMinutes)
            TimeOfDayRow(title: "Check-out time", minutes: $trip.checkOutMinutes)
        } header: { Text("Check-in & check-out") } footer: {
            if (try? trip.validateBooking()) == nil, trip.checkInMinutes != nil, trip.checkOutMinutes != nil {
                Text(CampError.invalidCheckTimes.localizedDescription).foregroundStyle(.red)
            } else {
                Text("Times are in the campground’s local time zone.")
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
    private func text(_ keyPath: WritableKeyPath<Trip, String?>) -> Binding<String> {
        Binding(get: { trip[keyPath: keyPath] ?? "" }, set: { trip[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
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
