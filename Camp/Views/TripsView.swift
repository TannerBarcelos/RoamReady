import SwiftUI
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
                        RigImage(rig: profile.rig)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name.isEmpty ? "Welcome back" : "Hello, \(profile.name)").font(.title3.bold())
                            Text(profile.rig.displayName).font(.subheadline).foregroundStyle(.secondary)
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
                    Text("Plan a trip and your setup and teardown checklists will be ready automatically.")
                } actions: { Button("Plan a trip") { planning = true }.buttonStyle(.borderedProminent) }
            }
            Section("Next trip") { Button("Plan a trip", systemImage: "plus") { planning = true } }
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
                ContentUnavailableView("No trips yet", systemImage: "calendar.badge.plus", description: Text("Choose a destination, set your dates, and we’ll prepare your checklists."))
            }
            if !upcoming.isEmpty { Section("Upcoming & current") { ForEach(upcoming) { TripRow(trip: $0) } } }
            if !past.isEmpty { Section("Past trips") { ForEach(past) { TripRow(trip: $0) } } }
            Button("Plan a trip", systemImage: "plus") { planning = true }
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
    @Environment(\.dismiss) private var dismiss
    var initialCampground: Campground? = nil
    @State private var name = ""
    @State private var site = ""
    @State private var arrival = Calendar.current.startOfDay(for: .now)
    @State private var departure = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var selected: Campground?
    @State private var choosing = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("Campground or destination", text: $name)
                        .onChange(of: name) { _, value in if selected?.name != value { selected = nil } }
                    Button("Choose a campground", systemImage: "map") { choosing = true }
                    TextField("Site number (optional)", text: $site)
                }
                Section("Dates") {
                    DatePicker("Arrival", selection: $arrival, displayedComponents: .date)
                        .onChange(of: arrival) { _, value in if departure < value { departure = value } }
                    DatePicker("Departure", selection: $departure, in: arrival..., displayedComponents: .date)
                }
                Section {
                    Label("Setup & teardown included", systemImage: "checklist")
                    Text("Each trip gets a fresh copy of your rig’s checklists. Change any step to suit this trip.").foregroundStyle(.secondary)
                }
                if let selected {
                    WeatherSection(trip: Trip(campgroundName: name, latitude: selected.latitude, longitude: selected.longitude,
                        arrival: arrival, departure: departure, planningTimeZoneIdentifier: TimeZone.current.identifier,
                        campgroundTimeZoneIdentifier: selected.timeZoneIdentifier))
                } else {
                    Section("Weather") {
                        Text("Choose a campground with a location to check the forecast. You can also plan any destination offline.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("New trip").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create trip") {
                        do {
                            try store.createTrip(name: name, arrival: arrival, departure: departure, site: site, campground: selected)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $choosing) {
                NavigationStack { CampgroundPicker { place in name = place.name; selected = place; choosing = false } }
            }
            .onAppear { if let initialCampground { name = initialCampground.name; selected = initialCampground } }
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
                        if !trip.siteNumber.isEmpty { Label("Site \(trip.siteNumber)", systemImage: "mappin") }
                        SaveStatus()
                    }
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
                }
                .navigationTitle(trip.campgroundName)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Edit trip", systemImage: "pencil") { showEdit = true }
                            Button("Delete trip", systemImage: "trash", role: .destructive) { showDelete = true }
                        } label: { Label("Trip options", systemImage: "ellipsis.circle") }
                    }
                }
                .sheet(isPresented: $showEdit) { EditTripView(trip: trip) }
                .sheet(isPresented: $showAssistant) { AssistantView(trip: trip, step: nil) }
            } else { ContentUnavailableView("Trip no longer available", systemImage: "calendar") }
        }
        .confirmationDialog("Delete this trip and its checklist history?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete trip", role: .destructive) { store.deleteTrip(tripID); dismiss() }
        }
    }
}

struct EditTripView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var trip: Trip
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Campground", text: $trip.campgroundName)
                DatePicker("Arrival", selection: $trip.arrival, displayedComponents: .date)
                    .onChange(of: trip.arrival) { _, value in if trip.departure < value { trip.departure = value } }
                DatePicker("Departure", selection: $trip.departure, in: trip.arrival..., displayedComponents: .date)
                TextField("Site number", text: $trip.siteNumber)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit trip").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try trip.validate()
                            store.editTrip(trip.id) { current in
                                if current.campgroundName != trip.campgroundName {
                                    current.latitude = nil; current.longitude = nil
                                    current.campgroundID = nil; current.campgroundTimeZoneIdentifier = nil
                                }
                                current.campgroundName = trip.campgroundName
                                current.arrival = trip.arrival; current.departure = trip.departure; current.siteNumber = trip.siteNumber
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .environment(\.timeZone, trip.planningTimeZone)
        }
    }
}
