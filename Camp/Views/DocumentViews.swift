import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import CampCore

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

struct DocumentEditorView: View {
    enum Mode {
        case newFile(DocumentOwner, PendingDocumentFile)
        case newLink(DocumentOwner)
        case edit(ManagedDocument)
    }
    @Environment(CampStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var title = ""
    /// No default: the user must say what kind of document this is, because it decides protection.
    @State private var category: DocumentCategory?
    @State private var encryptFile = false
    @State private var notes = ""
    @State private var linkText = ""
    @State private var hasIssued = false
    @State private var issuedOn = Date.now
    @State private var hasExpiration = false
    @State private var expiresOn = Date.now
    @State private var saving = false
    @State private var failure: String?
    @State private var prepared = false

    var body: some View {
        NavigationStack {
            Form {
                if case .newFile(_, let pending) = mode {
                    Section("File") {
                        LabeledContent("Name", value: pending.file.filename)
                        LabeledContent("Format", value: pending.file.contentType.isImage ? "Image (\(pending.file.contentType.rawValue.uppercased()))" : "PDF")
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(pending.file.byteCount), countStyle: .file))
                    }
                }
                if case .newLink = mode {
                    Section {
                        TextField("https://", text: $linkText).keyboardType(.URL).textContentType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Link") } footer: { Text("Links open online. You can save a copy of a PDF or image link for offline use later.") }
                }
                Section {
                    Picker("Document type", selection: $category) {
                        Text("Choose a type").tag(DocumentCategory?.none)
                        ForEach(categories) { type in
                            Label(type.title, systemImage: type.isSensitive ? "lock.fill" : type.systemImage).tag(Optional(type))
                        }
                    }
                } header: { Text("Document type") } footer: {
                    Text("Registration, insurance, and reservation documents are always end-to-end encrypted.")
                }
                if let category { protectionSection(category) }
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Notes (policy number, page references…)", text: $notes, axis: .vertical).lineLimit(3...10)
                }
                Section("Dates") {
                    Toggle("Issue or effective date", isOn: $hasIssued.animation())
                    if hasIssued { DatePicker("Issued", selection: $issuedOn, displayedComponents: .date) }
                    Toggle("Expiration or renewal", isOn: $hasExpiration.animation())
                    if hasExpiration { DatePicker("Expires", selection: $expiresOn, displayedComponents: .date) }
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle(isNew ? "New document" : "Edit document").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving || category == nil) }
            }
            .interactiveDismissDisabled(saving)
            .onAppear(perform: prepare)
            .onDisappear {
                // The temporary copy is only needed until the document is saved or abandoned.
                if case .newFile(_, let pending) = mode { DocumentImport.discard(pending.url) }
            }
        }
    }

    /// Explains, before saving, exactly how this document will be protected.
    @ViewBuilder private func protectionSection(_ category: DocumentCategory) -> some View {
        Section {
            if category.isSensitive || alreadyEncrypted {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("End-to-end encrypted").font(.headline)
                        Text(category.isSensitive ? "\(category.title) documents often include policy, plate, VIN, or personal details." : "This document is already encrypted and stays that way.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "lock.fill").foregroundStyle(.green) }
            } else {
                Toggle(isOn: $encryptFile) { Label("End-to-end encrypt this file", systemImage: encryptFile ? "lock.fill" : "lock.open") }
            }
        } header: { Text("Protection") } footer: {
            Text(category.isSensitive || alreadyEncrypted || encryptFile
                 ? "The file is encrypted on this iPhone before it syncs. Only your devices signed in to your Apple Account can read it, not Apple or RoamReady. If your iCloud Keychain is reset, encrypted copies in iCloud can’t be recovered; copies on your devices are unaffected. Encryption can’t be turned off later."
                 : "The file is encrypted at rest by Apple in iCloud. Titles, notes, and links are always end-to-end encrypted.")
        }
    }

    private var alreadyEncrypted: Bool {
        if case .edit(let document) = mode { return document.metadata.protection == .endToEnd }
        return false
    }
    private var isNew: Bool {
        if case .edit = mode { return false }
        return true
    }
    private var categories: [DocumentCategory] {
        guard let category, !DocumentCategory.standard.contains(category) else { return DocumentCategory.standard }
        return DocumentCategory.standard + [category]
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        switch mode {
        case .newFile(_, let pending): title = DocumentPolicy.suggestedTitle(filename: pending.file.filename)
        case .newLink: break
        case .edit(let document):
            let m = document.metadata
            title = m.title; category = m.category; notes = m.notes; encryptFile = m.protection == .endToEnd
            if let date = m.issuedOn { hasIssued = true; issuedOn = date }
            if let date = m.expiresOn { hasExpiration = true; expiresOn = date }
        }
    }

    private func save() {
        guard let category else { return }
        let metadata = DocumentMetadata(title: title, category: category, notes: notes,
                                        issuedOn: hasIssued ? issuedOn : nil, expiresOn: hasExpiration ? expiresOn : nil,
                                        protection: encryptFile || alreadyEncrypted ? .endToEnd : .standard)
        Task {
            saving = true; failure = nil
            defer { saving = false }
            do {
                switch mode {
                case .newFile(let owner, let pending):
                    try await store.addDocument(DocumentDraft(owner: owner, metadata: metadata, source: .fileAt(pending.url, filename: pending.file.filename)))
                case .newLink(let owner):
                    let url = try DocumentPolicy.link(from: linkText)
                    var withTitle = metadata
                    if withTitle.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { withTitle.title = url.host() ?? "Link" }
                    try await store.addDocument(DocumentDraft(owner: owner, metadata: withTitle, source: .link(url)))
                case .edit(let document):
                    try await store.updateDocument(document.id, metadata: metadata)
                }
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

struct DocumentDetailView: View {
    @Environment(CampStore.self) private var store
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID
    @State private var previewURL: URL?
    @State private var fileURL: URL?
    @State private var fileProblem: String?
    @State private var failure: String?
    @State private var working = false
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let document = store.document(documentID) {
                List {
                    Section {
                        Label(document.metadata.category.title, systemImage: document.metadata.category.systemImage)
                        availability(document)
                        if document.metadata.protection == .endToEnd {
                            Label("End-to-end encrypted in iCloud", systemImage: "lock.fill").foregroundStyle(.green)
                        } else {
                            Label("Encrypted at rest in iCloud", systemImage: "lock.icloud")
                        }
                    }
                    if document.metadata.issuedOn != nil || document.metadata.expiresOn != nil {
                        Section("Dates") {
                            if let date = document.metadata.issuedOn { LabeledContent("Issued", value: date.formatted(date: .long, time: .omitted)) }
                            if let date = document.metadata.expiresOn {
                                LabeledContent(date < .now ? "Expired" : "Expires", value: date.formatted(date: .long, time: .omitted))
                            }
                        }
                    }
                    if !document.metadata.notes.isEmpty { Section("Notes") { Text(document.metadata.notes).textSelection(.enabled) } }
                    Section { actions(document) } footer: { if let fileProblem { Text(fileProblem) } }
                    if let failure { Section { Text(failure).foregroundStyle(.red) } }
                    Section {
                        Button("Delete document", systemImage: "trash", role: .destructive) { confirmingDelete = true }.disabled(working)
                    }
                }
                .navigationTitle(document.metadata.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
                .sheet(isPresented: $editing) { DocumentEditorView(mode: .edit(document)) }
                .task(id: "\(document.file?.checksum ?? "")-\(document.isContentAvailable)") { await prepareFile(document) }
                .confirmationDialog("Delete “\(document.metadata.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete document", role: .destructive) { delete() }
                } message: {
                    Text("The saved file and details are removed from RoamReady, including on devices that sync with iCloud. Copies you shared elsewhere aren’t affected.")
                }
            } else {
                ContentUnavailableView("Document unavailable", systemImage: "doc")
            }
        }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder private func availability(_ document: ManagedDocument) -> some View {
        switch document.availability {
        case .offline: Label("Saved on this iPhone · opens offline", systemImage: "iphone")
        case .awaitingDownload: Label("Waiting to download from iCloud", systemImage: "icloud.and.arrow.down")
        case .onlineOnly: Label("Link · needs a connection to open", systemImage: "link")
        }
    }

    @ViewBuilder private func actions(_ document: ManagedDocument) -> some View {
        if let file = document.file {
            Button("Preview", systemImage: file.contentType.isImage ? "photo" : "doc.richtext") { previewURL = fileURL }
                .disabled(fileURL == nil)
            if let fileURL { ShareLink("Share file", item: fileURL) }
            LabeledContent("File", value: "\(file.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))")
        }
        if let link = document.link {
            Button("Open link", systemImage: "safari") { openURL(link) }.disabled(!connectivity.isOnline)
            if document.file == nil {
                Button(working ? "Saving a copy…" : "Save a copy for offline use", systemImage: "arrow.down.doc") { saveOffline() }
                    .disabled(!connectivity.isOnline || working)
                ShareLink("Share link", item: link)
            }
            if !connectivity.isOnline { Text("Links need a connection.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func prepareFile(_ document: ManagedDocument) async {
        guard document.file != nil else { fileURL = nil; fileProblem = nil; return }
        do { fileURL = try await store.documentFileURL(document.id); fileProblem = nil }
        catch { fileURL = nil; fileProblem = error.localizedDescription }
    }

    private func saveOffline() {
        Task {
            working = true; failure = nil
            defer { working = false }
            do { try await store.saveLinkedContentsOffline(documentID) } catch { failure = error.localizedDescription }
        }
    }

    private func delete() {
        Task {
            working = true; failure = nil
            defer { working = false }
            do { try await store.deleteDocument(documentID); dismiss() } catch { failure = error.localizedDescription }
        }
    }
}
