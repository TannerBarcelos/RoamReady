import SwiftUI
import MapKit
import CampCore
import Campgrounds

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
