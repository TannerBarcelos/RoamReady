import SwiftUI
import SwiftData
import MapKit
import CampCore
import CampPersistence

struct TripDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    @State private var showDelete = false
    @State private var showEdit = false
    @State private var showAssistant = false
    var body: some View {
        List {
            Section {
                Text(trip.dateSummary)
                if let rig = trip.rig {
                    Label(rig.isArchived ? "\(rig.displayName) (archived)" : rig.displayName, systemImage: "car.side")
                } else {
                    Label("Rig unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                SaveStatus()
            }
            BookingCard(trip: trip)
            Section("Checklists") {
                ForEach(ChecklistPhase.allCases) { phase in
                    NavigationLink { ChecklistView(trip: trip, initialPhase: phase) } label: {
                        VStack(alignment: .leading, spacing: 8) { Text(phase.title).font(.headline); ProgressSummary(steps: trip.steps(phase)) }
                    }
                }
            }
            WeatherSection(trip: TripDraft(trip))
            Section("Make it memorable") {
                NavigationLink { MemoriesView(trip: trip) } label: { Label("Photos & site notes", systemImage: "photo.on.rectangle") }
                if trip.rating != .unrated { Label(trip.rating.title, systemImage: trip.rating == .wouldReturn ? "heart" : "hand.thumbsdown") }
            }
            if CampingAssistant.showsChat {
                Section { Button("Ask for camping help", systemImage: "sparkles") { showAssistant = true } }
            }
            Section {
                if trip.endedByDate() {
                    Label("Completed: this trip’s dates have passed", systemImage: "checkmark.seal")
                } else if trip.completedAt != nil {
                    Label("Marked complete", systemImage: "checkmark.seal")
                    Button("Reopen trip", systemImage: "arrow.uturn.backward") { trip.setCompleted(false); library.save() }
                } else {
                    Button("Mark trip complete", systemImage: "checkmark.seal") { trip.setCompleted(true); library.save() }
                }
                Button("Cancel & delete trip", systemImage: "trash", role: .destructive) { showDelete = true }
            } footer: {
                Text("Trips complete on their own the day after departure. Completed trips add their campground to Have been.")
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
        .sheet(isPresented: $showAssistant) { TripAssistantSheet(trip: trip, step: nil) }
        .alert("Delete “\(trip.campgroundName)”, \(trip.dateSummary)?", isPresented: $showDelete) {
            Button("Delete Trip", role: .destructive) {
                dismiss()
                context.delete(trip)
                library.save()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(TripDeletion.message(hasDocuments: !trip.attachedDocuments.isEmpty))
        }
    }
}

/// The copy for deleting (cancelling) a trip. There is no undo, so it names everything that goes and stays.
enum TripDeletion {
    static func message(hasDocuments: Bool) -> String {
        [
            "This permanently deletes the trip’s whole history on every device signed in to your iCloud account: its checklists and their progress, notes and all saved note versions, photos and captions, and site notes and rating. This can’t be undone.",
            hasDocuments
                ? "Kept: its confirmation and paperwork files move to Profile › Unattached documents."
                : "Kept: any confirmation files would move to Profile › Unattached documents.",
            "Your rig and its default checklists aren’t changed, and original photos stay in your photo library."
        ].joined(separator: "\n\n")
    }
}

/// The booking at a glance, with actions that are hidden when their data is missing.
struct BookingCard: View {
    let trip: Trip
    var body: some View {
        Section {
            let site = [trip.siteNumber.isEmpty ? nil : "Site \(trip.siteNumber)", trip.loop.map { "Loop \($0)" }].compactMap { $0 }
            if !site.isEmpty { Label(site.joined(separator: " · "), systemImage: "mappin") }
            if let details = trip.site, !details.summary.isEmpty {
                LabeledContent("Site details", value: details.summary)
                if let rig = trip.rig, details.isTooShort(for: rig), let limit = details.maxLengthFeet {
                    Label("\(rig.displayName) is longer than this site’s \(limit.formatted()) ft limit", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
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
            NavigationLink { DocumentsView(owner: .trip(trip), title: "Confirmation & documents") } label: {
                LabeledContent { Text(String(trip.attachedDocuments.count)) } label: {
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
