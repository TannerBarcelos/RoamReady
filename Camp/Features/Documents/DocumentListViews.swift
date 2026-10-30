import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import CampPersistence
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

/// The rig or trip a document belongs to.
enum DocumentOwner {
    case rig(Rig), trip(Trip)
    var documents: [StoredDocument] {
        switch self {
        case .rig(let rig): rig.attachedDocuments
        case .trip(let trip): trip.attachedDocuments
        }
    }
    var emptyTitle: String {
        switch self {
        case .rig: "No manuals or paperwork"
        case .trip: "No booking documents"
        }
    }
    var emptySymbol: String {
        switch self {
        case .rig: "folder"
        case .trip: "ticket"
        }
    }
    var emptyMessage: String {
        switch self {
        case .rig: "Keep your manuals, registration, insurance, and warranty together."
        case .trip: "Keep your reservation confirmation and campground map with this trip."
        }
    }
}

/// A selected file awaiting details, already inspected.
struct PendingDocumentFile: Identifiable, Sendable {
    let id = UUID()
    let imported: ImportFile
    let file: DocumentFile
}

/// Reusable list + add controls for any owner. Embed in a Form or List (onboarding, rig, trip).
struct DocumentVaultSection: View {
    let owner: DocumentOwner
    var header = "Documents"
    var footer = "Add PDFs, images, or links."
    @State private var importingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var addingLink = false
    @State private var pendingFile: PendingDocumentFile?
    @State private var reading = false
    @State private var failure: String?

    var body: some View {
        Section {
            ForEach(owner.documents) { document in
                NavigationLink { DocumentDetailView(document: document) } label: { DocumentRow(document: document) }
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
            case .success(let url): read { try await DocumentImport.read(pickedURL: url) }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        // `.current` keeps the photo's stored encoding instead of transcoding it.
        .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            photoSelection = nil
            read {
                guard let picked = try await selection.loadTransferable(type: PickedImage.self) else { throw DocumentError.unsupportedFileType }
                return picked.file
            }
        }
        .sheet(item: $pendingFile) { pending in DocumentEditorView(mode: .newFile(owner, pending)) }
        .sheet(isPresented: $addingLink) { DocumentEditorView(mode: .newLink(owner)) }
    }

    private func read(_ load: @escaping @MainActor () async throws -> ImportFile) {
        Task {
            reading = true; failure = nil
            defer { reading = false }
            do {
                let imported = try await load()
                // Validate before asking for details so unsupported files fail immediately.
                let file = try await Task.detached(priority: .userInitiated) { try imported.inspectDocument() }.value
                try Task.checkCancellation()
                pendingFile = PendingDocumentFile(imported: imported, file: file)
            } catch { failure = error.localizedDescription }
        }
    }
}

/// Full-screen list for an owner, reachable offline from Profile and trip details.
struct DocumentsView: View {
    let owner: DocumentOwner
    let title: String
    var body: some View {
        List {
            if owner.documents.isEmpty {
                ContentUnavailableView {
                    Label { Text(owner.emptyTitle) } icon: { Image(systemName: owner.emptySymbol).foregroundStyle(.tint) }
                } description: { Text(owner.emptyMessage) }
            }
            DocumentVaultSection(owner: owner)
        }.navigationTitle(title)
    }
}

struct UnattachedDocumentsView: View {
    @Query(sort: \StoredDocument.createdAt, order: .reverse) private var documents: [StoredDocument]
    var body: some View {
        List {
            Section {
                ForEach(documents.filter { $0.rig == nil && $0.trip == nil }) { document in
                    NavigationLink { DocumentDetailView(document: document) } label: { DocumentRow(document: document) }
                }
            } footer: {
                Text("Documents from deleted trips or a previous rig stay here until you delete them.")
            }
        }
        .navigationTitle("Unattached documents")
    }
}

struct DocumentRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let document: StoredDocument
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.category.systemImage).foregroundStyle(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        verticalMetadata
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                Text(document.category.title)
                                if document.expiresOn != nil { Text("·").accessibilityHidden(true) }
                                expiry
                            }
                            verticalMetadata
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if document.protection == .endToEnd {
                Image(systemName: "lock.fill").foregroundStyle(.green).accessibilityLabel("End-to-end encrypted")
            }
            DocumentAvailabilityIcon(availability: document.availability)
        }
        .accessibilityElement(children: .combine)
    }

    private var verticalMetadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(document.category.title)
            expiry
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var expiry: some View {
        if let expires = document.expiresOn {
            Text(expires < .now ? "Expired" : "Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
                .foregroundStyle(expires < .now ? Color.orange : .secondary)
        }
    }
}

struct DocumentAvailabilityIcon: View {
    let availability: DocumentAvailability
    var body: some View {
        switch availability {
        case .offline: Image(systemName: "iphone").foregroundStyle(.secondary).accessibilityLabel("File ready to open")
        case .awaitingDownload: Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).accessibilityLabel("Waiting to download")
        case .onlineOnly: Image(systemName: "link").foregroundStyle(.secondary).accessibilityLabel("Link, needs a connection")
        }
    }
}
