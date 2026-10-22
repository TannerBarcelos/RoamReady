import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import CampCore
import DocumentVault

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
