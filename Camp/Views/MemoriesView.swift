import SwiftUI
import PhotosUI
import CampCore
import CampPersistence
import UIKit
import ImageIO

struct MemoriesView: View {
    @Environment(CampStore.self) private var store
    let tripID: UUID
    @State private var selections: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var failure: String?
    @State private var selectedPhoto: TripPhoto?
    @State private var importTask: Task<Void, Never>?
    var body: some View {
        Group {
            if let trip = store.trip(tripID) {
                List {
                    Section("Remember this site") {
                        TextField("Site number", text: Binding(get: { store.trip(tripID)?.siteNumber ?? "" }, set: { value in store.editTrip(tripID) { $0.siteNumber = value } }))
                        Picker("Stay again?", selection: Binding(get: { store.trip(tripID)?.rating ?? .unrated }, set: { value in store.editTrip(tripID) { $0.rating = value } })) {
                            ForEach(SiteRating.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("Shade, slope, noise, favorite spots…", text: Binding(get: { store.trip(tripID)?.notes ?? "" }, set: { value in store.editTrip(tripID) { $0.notes = value } }), axis: .vertical)
                            .lineLimit(5...15)
                        SaveStatus()
                        NavigationLink("Earlier note versions") { NoteHistoryView(tripID: tripID) }
                    }
                    Section {
                        PhotosPicker(selection: $selections, maxSelectionCount: 20, matching: .images) {
                            Label(importing ? "Saving photos…" : "Add trip photos", systemImage: "photo.badge.plus")
                        }.disabled(importing)
                        if importing { ProgressView("Saving on this iPhone") }
                        if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                        if trip.photos.isEmpty {
                            Text("Keep the moments you’ll want to come back to.").foregroundStyle(.secondary).padding(.vertical)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                                ForEach(trip.photos) { photo in
                                    Button { selectedPhoto = photo } label: {
                                        VStack(alignment: .leading) {
                                            LocalPhoto(filename: photo.filename).frame(height: 135).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                            if !photo.caption.isEmpty { Text(photo.caption).font(.caption).lineLimit(2).foregroundStyle(.primary) }
                                        }
                                    }.buttonStyle(.plain).accessibilityLabel(photo.caption.isEmpty ? "Trip photo" : photo.caption)
                                }
                            }.padding(.vertical, 6)
                        }
                    } header: { Text("Photos · \(trip.photos.count)") } footer: {
                        Text("Photos are copied into RoamReady and resized for storage. Keep originals in your photo library. iCloud-only photos need a connection before importing.")
                    }
                }
            } else { ContentUnavailableView("Trip unavailable", systemImage: "photo") }
        }
        .navigationTitle("Photos & site notes")
        .onChange(of: selections) { _, selected in
            guard !selected.isEmpty, !importing else { return }
            importTask = Task {
                importing = true; failure = nil
                defer { importing = false; selections = [] }
                for selection in selected {
                    do {
                        guard let data = try await selection.loadTransferable(type: Data.self) else { throw CampUIError.unreadablePhoto }
                        let filename = try await store.media.importPhoto(data)
                        store.editTrip(tripID) { $0.photos.append(TripPhoto(filename: filename)) }
                    } catch { failure = "Some photos couldn’t be saved. \(error.localizedDescription)" }
                }
            }
        }
        .sheet(item: $selectedPhoto) { photo in PhotoDetailView(tripID: tripID, photo: photo) }
    }
}

struct LocalPhoto: View {
    @Environment(CampStore.self) private var store
    let filename: String
    var maximumDimension = 512
    @State private var thumbnail: UIImage?
    @State private var photoFailure: String?
    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill).overlay {
                    VStack {
                        Image(systemName: photoFailure == nil ? "photo" : "icloud.and.arrow.down")
                        if photoFailure != nil { Text("Not on this iPhone yet").font(.caption2) }
                    }.foregroundStyle(.secondary)
                }.accessibilityLabel(photoFailure ?? "Loading photo")
            }
        }
        .task(id: "\(filename)-\(maximumDimension)-\(store.mediaRevision)") {
            let url: URL
            do { url = try await store.photoURL(filename: filename); photoFailure = nil }
            catch { photoFailure = error.localizedDescription; return }
            let bound = maximumDimension
            // Only Sendable JPEG bytes cross the task boundary; UIKit images stay on the UI actor.
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: bound,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap { UIImage(data: $0) }
        }
    }
}

struct PhotoDetailView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: UUID
    @State var photo: TripPhoto
    @State private var deleting = false
    @State private var shareURL: URL?
    var body: some View {
        NavigationStack {
            Form {
                LocalPhoto(filename: photo.filename, maximumDimension: 2048).frame(height: 300).clipped()
                TextField("Caption", text: $photo.caption, axis: .vertical)
                if let shareURL { ShareLink("Share photo", item: shareURL) }
                Button("Remove from trip", role: .destructive) { deleting = true }
            }
            .task(id: store.mediaRevision) { shareURL = try? await store.photoURL(filename: photo.filename) }
            .navigationTitle("Trip photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.editTrip(tripID) { trip in if let index = trip.photos.firstIndex(where: { $0.id == photo.id }) { trip.photos[index].caption = photo.caption } }
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Remove this photo from the trip?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Remove photo", role: .destructive) { store.editTrip(tripID) { $0.photos.removeAll { $0.id == photo.id } }; dismiss() }
            }
        }
    }
}


struct NoteHistoryView: View {
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tripID: UUID
    @State private var revisions: [NoteRevision] = []
    @State private var failure: String?
    var body: some View {
        List {
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if revisions.isEmpty { Text("Earlier versions of saved notes will appear here.").foregroundStyle(.secondary) }
            ForEach(revisions) { revision in
                Section {
                    Text(revision.text)
                    Button("Use this version") {
                        store.editTrip(tripID) { $0.notes = revision.text }
                        dismiss()
                    }
                } header: { Text(revision.date, style: .date) }
            }
        }
        .navigationTitle("Note history")
        .task {
            do { revisions = try await store.revisions(for: tripID) }
            catch { failure = error.localizedDescription }
        }
    }
}
