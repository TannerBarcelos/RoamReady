import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import CampCore
import DocumentVault

extension DocumentCategory {
    var systemImage: String {
        switch self {
        case .manual: "book.closed"
        case .registration: "doc.text"
        case .insurance: "checkmark.shield"
        case .warranty: "checkmark.seal"
        case .maintenance: "wrench.and.screwdriver"
        case .reservation: "ticket"
        default: "doc"
        }
    }
}

/// A selected file awaiting details: a temporary byte-for-byte copy, already inspected.
struct PendingDocumentFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let file: DocumentFile
}

/// Reusable list + add controls for any owner. Embed in a Form or List (onboarding, rig, trip).
struct DocumentVaultSection: View {
    @Environment(CampStore.self) private var store
    let owner: DocumentOwner
    var header = "Documents"
    var footer = "PDFs and images are saved on this iPhone and open offline. Links need a connection unless you save a copy."
    @State private var importingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var addingLink = false
    @State private var pendingFile: PendingDocumentFile?
    @State private var reading = false
    @State private var failure: String?

    var body: some View {
        Section {
            ForEach(store.documents(for: owner)) { document in
                NavigationLink { DocumentDetailView(documentID: document.id) } label: { DocumentRow(document: document) }
            }
            Menu {
                Button("Import PDF or image file", systemImage: "doc.badge.plus") { importingFile = true }
                Button("Choose from Photos", systemImage: "photo.badge.plus") { choosingPhoto = true }
                Button("Add a link", systemImage: "link.badge.plus") { addingLink = true }
            } label: { Label("Add document", systemImage: "plus") }
            .disabled(reading)
            if reading { ProgressView("Reading file…") }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        } header: { Text(header) } footer: { Text(footer) }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url): read { try await DocumentImport.copy(pickedURL: url) }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        // `.current` keeps the photo's stored encoding instead of transcoding it.
        .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            photoSelection = nil
            read {
                guard let photo = try await selection.loadTransferable(type: ImportedPhotoFile.self) else { throw DocumentError.unsupportedFileType }
                return photo.url
            }
        }
        .sheet(item: $pendingFile) { pending in DocumentEditorView(mode: .newFile(owner, pending)) }
        .sheet(isPresented: $addingLink) { DocumentEditorView(mode: .newLink(owner)) }
    }

    private func read(_ load: @escaping @MainActor () async throws -> URL) {
        Task {
            reading = true; failure = nil
            defer { reading = false }
            var copied: URL?
            do {
                let url = try await load(); copied = url
                // Validate before asking for details so unsupported files fail immediately.
                let file = try await Task.detached(priority: .userInitiated) { try DocumentPolicy.inspect(.file(url), filename: url.lastPathComponent) }.value
                pendingFile = PendingDocumentFile(url: url, file: file)
            } catch {
                if let copied { DocumentImport.discard(copied) }
                failure = error.localizedDescription
            }
        }
    }
}

/// Full-screen list for an owner, reachable offline from Profile and trip details.
struct DocumentsView: View {
    let owner: DocumentOwner
    let title: String
    var body: some View {
        List { DocumentVaultSection(owner: owner) }
            .navigationTitle(title)
    }
}

struct UnattachedDocumentsView: View {
    @Environment(CampStore.self) private var store
    var body: some View {
        List {
            Section {
                ForEach(store.unattachedDocuments) { document in
                    NavigationLink { DocumentDetailView(documentID: document.id) } label: { DocumentRow(document: document) }
                }
            } footer: {
                Text("Documents from deleted trips or a previous rig stay here until you delete them.")
            }
        }
        .navigationTitle("Unattached documents")
    }
}

struct DocumentRow: View {
    let document: ManagedDocument
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.metadata.category.systemImage).foregroundStyle(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.metadata.title).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(document.metadata.category.title)
                    if let expires = document.metadata.expiresOn {
                        Text("·")
                        Text(expires < .now ? "Expired" : "Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(expires < .now ? Color.orange : .secondary)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if document.metadata.protection == .endToEnd {
                Image(systemName: "lock.fill").foregroundStyle(.green).accessibilityLabel("End-to-end encrypted")
            }
            DocumentAvailabilityIcon(availability: document.availability)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DocumentAvailabilityIcon: View {
    let availability: DocumentAvailability
    var body: some View {
        switch availability {
        case .offline: Image(systemName: "iphone").foregroundStyle(.secondary).accessibilityLabel("Available offline")
        case .awaitingDownload: Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).accessibilityLabel("Waiting to download")
        case .onlineOnly: Image(systemName: "link").foregroundStyle(.secondary).accessibilityLabel("Link, needs a connection")
        }
    }
}
