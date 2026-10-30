import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import CampCore
import CampPersistence

struct MemoriesView: View {
    @Environment(LibraryController.self) private var library
    @Environment(AppPermissions.self) private var permissions
    @Bindable var trip: Trip
    @State private var selections: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var failure: String?
    @State private var selectedPhoto: TripPhoto?
    @State private var showingCamera = false
    @State private var requestingCamera = false
    @State private var needsCameraPermission = false
    var body: some View {
        List {
            Section("Remember this site") {
                TextField("Site number", text: $trip.siteNumber)
                Picker("Stay again?", selection: $trip.rating) {
                    ForEach(SiteRating.allCases) { Text($0.title).tag($0) }
                }
                TextField("Shade, slope, noise, favorite spots…", text: $trip.notes, axis: .vertical).lineLimit(5...15)
                SaveStatus()
                NavigationLink("Earlier note versions") { NoteHistoryView(trip: trip) }
            }
            Section {
                if CameraAccess.isAvailable {
                    Button {
                        Task {
                            requestingCamera = true; failure = nil; needsCameraPermission = false
                            defer { requestingCamera = false }
                            do {
                                try await CameraAccess.request()
                                showingCamera = true
                            } catch CameraCaptureError.permissionDenied {
                                needsCameraPermission = true
                                failure = CameraCaptureError.permissionDenied.localizedDescription
                            } catch { failure = error.localizedDescription }
                        }
                    } label: {
                        Label("Take a photo", systemImage: permissions.cameraDenied ? "camera.slash" : "camera")
                    }
                    .disabled(importing || requestingCamera || permissions.cameraDenied)
                }
                PhotosPicker(selection: $selections, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current) {
                    Label("Add trip photos", systemImage: "photo.badge.plus")
                }.disabled(importing || requestingCamera)
                if importing { ProgressView("Saving on this device") }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                if CameraAccess.isAvailable && (needsCameraPermission || permissions.cameraDenied) {
                    Text("Camera access is off. You can still add photos from your library.")
                        .font(.footnote).foregroundStyle(.secondary)
                    OpenPermissionSettingsButton()
                }
                let photos = trip.sortedPhotos
                if photos.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No photos yet") } icon: {
                            Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.tint)
                        }
                    } description: {
                        Text("Photograph your site, the view, and the hookups so you can decide whether to book this spot again.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                        ForEach(photos) { photo in
                            Button { selectedPhoto = photo } label: {
                                VStack(alignment: .leading) {
                                    LocalPhoto(data: photo.imageData).frame(maxWidth: .infinity).frame(height: 135).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                    if !photo.caption.isEmpty { Text(photo.caption).font(.caption).lineLimit(2).foregroundStyle(.primary) }
                                }
                            }.buttonStyle(.plain).accessibilityLabel(photo.caption.isEmpty ? "Trip photo" : photo.caption)
                        }
                    }.padding(.vertical, 6)
                }
            } header: { Text("Photos · \(trip.sortedPhotos.count)") } footer: {
                Text("Photos are saved in RoamReady, resized for storage, and sync with the trip. Use Share to save a copy elsewhere. iCloud-only library photos need a connection before importing.")
            }
        }
        .navigationTitle("Photos & site notes")
        // Each visit's notes become a version that can be restored later.
        .onDisappear { trip.saveNoteRevision(); library.save() }
        .onChange(of: selections) { _, selected in
            guard !selected.isEmpty, !importing else { return }
            Task {
                importing = true; failure = nil
                defer { importing = false; selections = [] }
                for selection in selected {
                    do {
                        trip.addPhoto(try await PhotoImport.jpeg(from: selection))
                    } catch { failure = "Some photos couldn’t be saved. \(error.localizedDescription)" }
                }
                library.save()
            }
        }
        .sheet(item: $selectedPhoto) { photo in PhotoDetailView(photo: photo) }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { result in
                showingCamera = false
                guard let result else { return }
                Task {
                    importing = true; failure = nil
                    defer { importing = false }
                    do { trip.addPhoto(try await PhotoImport.jpeg(from: result.get())); library.save() }
                    catch { failure = "The photo couldn’t be saved. \(error.localizedDescription)" }
                }
            }.ignoresSafeArea()
        }
    }
}

struct PhotoDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let photo: TripPhoto
    @State private var caption: String
    @State private var deleting = false
    @State private var shareURL: URL?
    init(photo: TripPhoto) {
        self.photo = photo
        _caption = State(initialValue: photo.caption)
    }
    var body: some View {
        NavigationStack {
            Form {
                LocalPhoto(data: photo.imageData, maximumDimension: 2048).frame(maxWidth: .infinity).frame(height: 300).clipped()
                TextField("Caption", text: $caption, axis: .vertical)
                if let shareURL { ShareLink("Share photo", item: shareURL) }
                Button("Remove from trip", role: .destructive) { deleting = true }
            }
            .task { shareURL = photo.imageData.flatMap { try? PhotoImport.shareableFile($0) } }
            .navigationTitle("Trip photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { photo.caption = caption; library.save(); dismiss() }
                }
            }
            .confirmationDialog("Remove this photo from the trip?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Remove photo", role: .destructive) { dismiss(); context.delete(photo); library.save() }
            }
        }
    }
}

struct NoteHistoryView: View {
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    var body: some View {
        List {
            let revisions = trip.revisions
            if revisions.isEmpty { Text("Earlier versions of saved notes will appear here.").foregroundStyle(.secondary) }
            ForEach(revisions) { revision in
                Section {
                    Text(revision.body)
                    Button("Use this version") { trip.notes = revision.body; library.save(); dismiss() }
                } header: { Text(revision.createdAt, style: .date) }
            }
        }
        .navigationTitle("Note history")
    }
}
