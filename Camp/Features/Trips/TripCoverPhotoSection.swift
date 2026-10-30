import SwiftUI
import PhotosUI

/// Holds an imported cover in the form draft until Save, so Cancel leaves the trip unchanged.
struct TripCoverPhotoSection: View {
    @Binding var data: Data?
    @Binding var importing: Bool
    @State private var selection: PhotosPickerItem?
    @State private var failure: String?

    var body: some View {
        Section {
            if let data {
                Color.clear
                    .frame(height: 160)
                    .overlay { LocalPhoto(data: data) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Trip cover photo")
            }
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label(data == nil ? "Add trip photo" : "Change trip photo", systemImage: "photo.badge.plus")
            }
            .disabled(importing)
            .accessibilityIdentifier("tripCoverPhotoPicker")
            if data != nil {
                Button("Remove trip photo", role: .destructive) { data = nil; selection = nil }
                    .disabled(importing)
            }
            if importing { ProgressView("Preparing photo…") }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Trip photo (optional)")
        } footer: {
            Text("Choose a cover for this trip’s Home card. Without a photo, the card shows only your trip details.")
        }
        .task(id: selection) {
            guard let selection else { return }
            importing = true
            failure = nil
            defer { importing = false }
            do {
                let jpeg = try await PhotoImport.jpeg(from: selection)
                try Task.checkCancellation()
                data = jpeg
            } catch is CancellationError {
                // Dismissing the form discards the pending import.
            } catch { failure = "The photo couldn’t be added. \(error.localizedDescription)" }
        }
    }
}
