import SwiftUI
import SwiftData
import CampCore
import CampPersistence

struct EditTripView: View {
    @Environment(LibraryController.self) private var library
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Rig.createdAt) private var rigs: [Rig]
    @Query private var trips: [Trip]
    let trip: Trip
    @State private var draft: TripDraft
    @State private var rig: Rig?
    @State private var choosing = false
    @State private var failure: String?
    init(trip: Trip) {
        self.trip = trip
        _draft = State(initialValue: TripDraft(trip))
        _rig = State(initialValue: trip.rig)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Campground") {
                    TextField("Campground", text: $draft.campgroundName)
                        .onChange(of: draft.campgroundName) { _, name in
                            // Renamed by hand: the old place's location and time zone no longer apply, and
                            // the trip becomes a campground entered by name.
                            if draft.campgroundID != nil, name != trip.campgroundName, draft.campgroundID == trip.campgroundID {
                                let local = CampgroundIdentity.local(named: name, among: trips.filter { $0.persistentModelID != trip.persistentModelID }.map { ($0.campgroundID, $0.campgroundName) })
                                draft.setCampground(id: local, name: nil, latitude: nil, longitude: nil, timeZoneIdentifier: nil)
                            }
                        }
                    Button("Choose from Camp Finder", systemImage: "map") { choosing = true }.disabled(!connectivity.isOnline)
                }
                RigPickerSection(rig: $rig, rigs: rigs.filter { !$0.isArchived || $0 == trip.rig })
                TripDatesSection(draft: $draft)
                BookingFormSections(trip: $draft, rig: rig)
                Section {
                    Text("Editing never resets checklists, progress, notes, photos, or memories. Changing the rig doesn’t replace this trip’s checklists.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("Edit trip").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try trip.update(draft, rig: rig); library.save(); dismiss() }
                        catch { failure = error.localizedDescription }
                    }.disabled(draft.campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    CampgroundPicker { place in
                        draft.setCampground(id: place.id, name: place.name, latitude: place.latitude, longitude: place.longitude,
                                            timeZoneIdentifier: place.timeZoneIdentifier)
                        choosing = false
                    }
                }
            }
            .environment(\.timeZone, draft.planningTimeZone)
        }
    }
}
