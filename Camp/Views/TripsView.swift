import SwiftUI
import MapKit
import CampCore

struct HomeView: View {
    @Environment(CampStore.self) private var store
    @State private var planning = false
    var featured: Trip? {
        let today = Calendar.current.startOfDay(for: .now)
        return store.state.trips.filter { $0.departure >= today }.sorted { $0.arrival < $1.arrival }.first
            ?? store.state.trips.sorted { $0.arrival > $1.arrival }.first
    }
    var body: some View {
        List {
            if let profile = store.state.profile {
                Section {
                    HStack(spacing: 16) {
                        if let rig = store.activeRig { RigImage(rig: rig) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name.isEmpty ? "Welcome back" : "Hello, \(profile.name)").font(.title3.bold())
                            if let rig = store.activeRig { Text(rig.displayName).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let trip = featured {
                Section {
                    NavigationLink { TripDetailView(tripID: trip.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(trip.campgroundName).font(.title2.bold())
                            Text(trip.dateSummary).font(.subheadline).foregroundStyle(.secondary)
                            if !trip.siteNumber.isEmpty { Label("Site \(trip.siteNumber)", systemImage: "mappin") .font(.subheadline) }
                            SaveStatus()
                        }.padding(.vertical, 6)
                    }
                    NavigationLink { ChecklistView(tripID: trip.id) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Continue setup").font(.headline)
                            ProgressSummary(items: trip.setup)
                        }.padding(.vertical, 4)
                    }
                } header: { Text(trip.departure < Calendar.current.startOfDay(for: .now) ? "Latest trip" : "Your next adventure") }
                Section("Your trip") {
                    NavigationLink { ChecklistView(tripID: trip.id) } label: {
                        Label("Setup checklist", systemImage: "checklist")
                        Spacer(); Text("\(trip.setupFinished) / \(trip.setup.count)").foregroundStyle(.secondary)
                    }
                    NavigationLink { ChecklistView(tripID: trip.id, initialPhase: .teardown) } label: {
                        Label("Teardown checklist", systemImage: "checklist")
                        Spacer(); Text("\(trip.teardownFinished) / \(trip.teardown.count)").foregroundStyle(.secondary)
                    }
                    NavigationLink { MemoriesView(tripID: trip.id) } label: { Label("Photos & site notes", systemImage: "photo.on.rectangle") }
                }
            } else {
                ContentUnavailableView {
                    Label("Your next adventure starts here", systemImage: "tent.2")
                } description: {
                    Text("Booked a campsite? Add the trip and your setup and teardown checklists will be ready automatically.")
                } actions: { Button("Add a trip") { planning = true }.buttonStyle(.borderedProminent) }
            }
            Section("Next trip") { Button("Add a trip", systemImage: "plus") { planning = true } }
        }
        .navigationTitle("Home")
        .sheet(isPresented: $planning) { NewTripView() }
    }
}

struct PlanView: View {
    @Environment(CampStore.self) private var store
    @State private var planning = false
    var upcoming: [Trip] { store.state.trips.filter { $0.departure >= Calendar.current.startOfDay(for: .now) }.sorted { $0.arrival < $1.arrival } }
    var past: [Trip] { store.state.trips.filter { $0.departure < Calendar.current.startOfDay(for: .now) }.sorted { $0.arrival > $1.arrival } }
    var body: some View {
        List {
            if store.state.trips.isEmpty {
                ContentUnavailableView("No trips yet", systemImage: "calendar.badge.plus", description: Text("After you reserve a campsite, add the booking here and we’ll prepare your checklists."))
            }
            if !upcoming.isEmpty { Section("Upcoming & current") { ForEach(upcoming) { TripRow(trip: $0) } } }
            if !past.isEmpty { Section("Past trips") { ForEach(past) { TripRow(trip: $0) } } }
            Button("Add a trip", systemImage: "plus") { planning = true }
        }
        .navigationTitle("Plan")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New trip", systemImage: "plus") { planning = true } } }
        .sheet(isPresented: $planning) { NewTripView() }
    }
}

struct TripRow: View {
    let trip: Trip
    var body: some View {
        NavigationLink { TripDetailView(tripID: trip.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.campgroundName).font(.headline)
                Text(trip.dateSummary).font(.subheadline).foregroundStyle(.secondary)
                if !trip.siteNumber.isEmpty { Text("Site \(trip.siteNumber)").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }
    }
}

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

struct TripDetailView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: UUID
    @State private var showDelete = false
    @State private var showEdit = false
    @State private var showAssistant = false
    var body: some View {
        Group {
            if let trip = store.trip(tripID) {
                List {
                    Section {
                        Text(trip.dateSummary)
                        if let rig = store.rig(for: trip) {
                            Label(rig.isArchived ? "\(rig.displayName) (archived)" : rig.displayName, systemImage: "car.side")
                        } else {
                            Label("Rig unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        }
                        SaveStatus()
                    }
                    BookingCard(trip: trip)
                    Section("Checklists") {
                        NavigationLink { ChecklistView(tripID: tripID) } label: {
                            VStack(alignment: .leading, spacing: 8) { Text("Setup").font(.headline); ProgressSummary(items: trip.setup) }
                        }
                        NavigationLink { ChecklistView(tripID: tripID, initialPhase: .teardown) } label: {
                            VStack(alignment: .leading, spacing: 8) { Text("Teardown").font(.headline); ProgressSummary(items: trip.teardown) }
                        }
                    }
                    WeatherSection(trip: trip)
                    Section("Make it memorable") {
                        NavigationLink { MemoriesView(tripID: tripID) } label: { Label("Photos & site notes", systemImage: "photo.on.rectangle") }
                        if trip.rating != .unrated { Label(trip.rating.title, systemImage: trip.rating == .wouldReturn ? "heart" : "hand.thumbsdown") }
                    }
                    Section { Button("Ask for camping help", systemImage: "sparkles") { showAssistant = true } }
                    Section {
                        Button("Cancel & delete trip", systemImage: "trash", role: .destructive) { showDelete = true }
                    }
                }
                .navigationTitle(trip.campgroundName)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Edit trip", systemImage: "pencil") { showEdit = true }
                            Button("Cancel & delete trip", systemImage: "trash", role: .destructive) { showDelete = true }
                        } label: { Label("Trip options", systemImage: "ellipsis.circle") }
                    }
                }
                .sheet(isPresented: $showEdit) { EditTripView(trip: trip) }
                .sheet(isPresented: $showAssistant) { AssistantView(trip: trip, step: nil) }
                .alert("Delete “\(trip.campgroundName)”, \(trip.dateSummary)?", isPresented: $showDelete) {
                    Button("Delete Trip", role: .destructive) { store.deleteTrip(tripID); dismiss() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(TripDeletion.message(hasDocuments: !store.documents(for: .trip(tripID)).isEmpty))
                }
            } else { ContentUnavailableView("Trip no longer available", systemImage: "calendar") }
        }
    }
}

/// The copy for deleting (cancelling) a trip. There is no undo, so it names everything that goes and stays.
enum TripDeletion {
    static func message(hasDocuments: Bool) -> String {
        var lines = [
            "This permanently deletes the trip’s whole history on every device signed in to your iCloud account: its checklists and their progress, notes and all saved note versions, photos and captions, and site notes and rating. This can’t be undone."
        ]
        lines.append(hasDocuments
            ? "Kept: its confirmation and paperwork files move to Profile › Unattached documents."
            : "Kept: any confirmation files would move to Profile › Unattached documents.")
        lines.append("Your rig and its default checklists aren’t changed, and original photos stay in your photo library.")
        return lines.joined(separator: "\n\n")
    }
}

/// The booking at a glance, with actions that are hidden when their data is missing.
struct BookingCard: View {
    @Environment(CampStore.self) private var store
    let trip: Trip
    var body: some View {
        Section {
            let site = [trip.siteNumber.isEmpty ? nil : "Site \(trip.siteNumber)", trip.loop.map { "Loop \($0)" }].compactMap { $0 }
            if !site.isEmpty { Label(site.joined(separator: " · "), systemImage: "mappin") }
            if let number = trip.confirmationNumber {
                LabeledContent("Confirmation", value: number).textSelection(.enabled)
            }
            if let provider = trip.bookingProvider { LabeledContent("Booked through", value: provider) }
            if let checkIn = trip.checkInDate { LabeledContent("Check-in", value: campgroundTime(checkIn)) }
            if let checkOut = trip.checkOutDate { LabeledContent("Check-out", value: campgroundTime(checkOut)) }
            if let total = trip.totalCost { LabeledContent("Total cost", value: total.formatted(.currency(code: currencyCode))) }
            if let paid = trip.amountPaid { LabeledContent("Paid", value: paid.formatted(.currency(code: currencyCode))) }
            if let deadline = trip.cancellationDeadline {
                LabeledContent("Cancel by", value: deadline.formatted(date: .abbreviated, time: .shortened))
            }
            if let url = trip.bookingLink {
                Link(destination: url) { Label("Open booking link", systemImage: "safari") }
                    .accessibilityHint("Opens your booking in Safari")
            }
            NavigationLink { DocumentsView(owner: .trip(trip.id), title: "Confirmation & documents") } label: {
                LabeledContent { Text(String(store.documents(for: .trip(trip.id)).count)) } label: {
                    Label("View confirmation & documents", systemImage: "doc.text")
                }
            }
            if let latitude = trip.latitude, let longitude = trip.longitude {
                Button("Directions", systemImage: "car") {
                    let item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
                    item.name = trip.campgroundName
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                }.accessibilityHint("Opens Apple Maps with driving directions")
            }
        } header: { Text("Booking") } footer: {
            if !trip.hasBookingDetails { Text("No booking details yet. Edit the trip to add them.") }
        }
    }
    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }
    /// Shown in the campground's time zone, with its abbreviation so it reads correctly from anywhere.
    private func campgroundTime(_ date: Date) -> String {
        let zone = trip.campgroundCalendar.timeZone
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = zone
        return date.formatted(style) + (zone.abbreviation(for: date).map { " " + $0 } ?? "")
    }
}

struct EditTripView: View {
    @Environment(CampStore.self) private var store
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @State var trip: Trip
    @State private var rigID: UUID?
    @State private var choosing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Campground") {
                    TextField("Campground", text: $trip.campgroundName)
                    Button("Choose from Camp Finder", systemImage: "map") { choosing = true }.disabled(!connectivity.isOnline)
                }
                RigPickerSection(rigID: $rigID, includeArchived: trip.rigID)
                Section("Dates") {
                    DatePicker("Arrival", selection: $trip.arrival, displayedComponents: .date)
                        .onChange(of: trip.arrival) { _, value in if trip.departure < value { trip.departure = value } }
                    DatePicker("Departure", selection: $trip.departure, in: trip.arrival..., displayedComponents: .date)
                }
                BookingFormSections(trip: $trip)
                Section {
                    Text("Editing never resets checklists, progress, notes, photos, or memories. Changing the rig doesn’t replace this trip’s checklists.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit trip").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            var edited = trip
                            edited.copyBookingDetails(from: trip)
                            edited.rigID = rigID
                            try edited.validate()
                            try edited.validateBooking()
                            let original = store.trip(trip.id)
                            store.editTrip(trip.id) { current in
                                if current.campgroundName != edited.campgroundName && original?.campgroundID == edited.campgroundID {
                                    // Renamed by hand: the old listing's location no longer applies.
                                    edited.latitude = nil; edited.longitude = nil
                                    edited.campgroundID = nil; edited.campgroundTimeZoneIdentifier = nil
                                }
                                current.campgroundName = edited.campgroundName
                                current.latitude = edited.latitude; current.longitude = edited.longitude
                                current.campgroundID = edited.campgroundID; current.campgroundTimeZoneIdentifier = edited.campgroundTimeZoneIdentifier
                                current.arrival = edited.arrival; current.departure = edited.departure
                                current.rigID = edited.rigID
                                current.copyBookingDetails(from: edited)
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(trip.campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    CampgroundPicker { place in
                        trip.campgroundName = place.name; trip.campgroundID = place.id
                        trip.latitude = place.latitude; trip.longitude = place.longitude
                        trip.campgroundTimeZoneIdentifier = place.timeZoneIdentifier
                        choosing = false
                    }
                }
            }
            .onAppear { if rigID == nil { rigID = trip.rigID } }
            .environment(\.timeZone, trip.planningTimeZone)
        }
    }
}
