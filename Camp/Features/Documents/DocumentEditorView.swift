import SwiftUI
import SwiftData
import CampPersistence
import DocumentVault

struct DocumentEditorView: View {
    enum Mode {
        case newFile(DocumentOwner, PendingDocumentFile)
        case newLink(DocumentOwner)
        case edit(StoredDocument)
    }
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var title = ""
    @State private var category: DocumentCategory?
    @State private var notes = ""
    @State private var linkText = ""
    @State private var hasIssued = false
    @State private var issuedOn = Date.now
    @State private var hasExpiration = false
    @State private var expiresOn = Date.now
    @State private var failure: String?
    @State private var saving = false
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
                            Label(type.title, systemImage: type.systemImage).tag(Optional(type))
                        }
                    }
                } header: { Text("Document type") } footer: {
                    Text("Documents are encrypted automatically when synced with your private iCloud. Files saved on this device open offline.")
                }
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
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .navigationTitle(isNew ? "New document" : "Edit document").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(category == nil || saving) }
            }
            .onAppear(perform: prepare)
        }
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
            title = m.title; category = m.category; notes = m.notes
            if let date = m.issuedOn { hasIssued = true; issuedOn = date }
            if let date = m.expiresOn { hasExpiration = true; expiresOn = date }
        }
    }

    private func save() async {
        guard let category, !saving else { return }
        saving = true; failure = nil
        defer { saving = false }
        let metadata = DocumentMetadata(title: title, category: category, notes: notes,
                                        issuedOn: hasIssued ? issuedOn : nil, expiresOn: hasExpiration ? expiresOn : nil)
        do {
            switch mode {
            case .newFile(let owner, let pending):
                let payload = try await Task.detached(priority: .userInitiated) { try pending.imported.documentPayload() }.value
                try Task.checkCancellation()
                guard payload.file == pending.file else { throw DocumentError.contentIntegrity }
                try add(metadata, contents: payload, link: nil, to: owner)
            case .newLink(let owner):
                let url = try DocumentPolicy.link(from: linkText)
                var withTitle = metadata
                if withTitle.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { withTitle.title = url.host() ?? "Link" }
                try add(withTitle, contents: nil, link: url, to: owner)
            case .edit(let document):
                try document.update(metadata)
            }
            library.save()
            dismiss()
        } catch { failure = error.localizedDescription }
    }

    private func add(_ metadata: DocumentMetadata, contents: DocumentPayload?, link: URL?, to owner: DocumentOwner) throws {
        switch owner {
        case .rig(let rig): try StoredDocument.add(metadata, contents: contents, link: link, rig: rig, in: context)
        case .trip(let trip): try StoredDocument.add(metadata, contents: contents, link: link, trip: trip, in: context)
        }
    }
}
