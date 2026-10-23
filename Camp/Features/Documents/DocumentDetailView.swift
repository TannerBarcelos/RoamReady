import SwiftUI
import SwiftData
import QuickLook
import CampPersistence
import DocumentVault

struct DocumentDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    @Environment(Connectivity.self) private var connectivity
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let document: StoredDocument
    @State private var previewURL: URL?
    @State private var fileURL: URL?
    @State private var fileProblem: String?
    @State private var failure: String?
    @State private var downloading = false
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                Label(document.category.title, systemImage: document.category.systemImage)
                availability
                if document.protection == .endToEnd {
                    Label("End-to-end encrypted in iCloud", systemImage: "lock.fill").foregroundStyle(.green)
                } else {
                    Label("Encrypted at rest in iCloud", systemImage: "lock.icloud")
                }
                if library.sync.syncing {
                    Label(library.sync.status, systemImage: library.sync.busy ? "arrow.triangle.2.circlepath.icloud" : "icloud").font(.caption)
                } else {
                    Label("On this iPhone only · iCloud sync is off", systemImage: "iphone").font(.caption)
                }
            }
            if document.issuedOn != nil || document.expiresOn != nil {
                Section("Dates") {
                    if let date = document.issuedOn { LabeledContent("Issued", value: date.formatted(date: .long, time: .omitted)) }
                    if let date = document.expiresOn {
                        LabeledContent(date < .now ? "Expired" : "Expires", value: date.formatted(date: .long, time: .omitted))
                    }
                }
            }
            if !document.notes.isEmpty { Section("Notes") { Text(document.notes).textSelection(.enabled) } }
            Section { actions } footer: { if let fileProblem { Text(fileProblem) } }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            Section {
                Button("Delete document", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
        .sheet(isPresented: $editing) { DocumentEditorView(mode: .edit(document)) }
        .task(id: "\(document.checksum ?? "")-\(document.availability == .offline)") { prepareFile() }
        .confirmationDialog("Delete “\(document.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete document", role: .destructive) { dismiss(); context.delete(document); library.save() }
        } message: {
            Text("The saved file and details are removed from RoamReady, including on devices that sync with iCloud. Copies you shared elsewhere aren’t affected.")
        }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder private var availability: some View {
        switch document.availability {
        case .offline: Label("Saved on this iPhone · opens offline", systemImage: "iphone")
        case .awaitingDownload: Label("Waiting to download from iCloud", systemImage: "icloud.and.arrow.down")
        case .onlineOnly: Label("Link · needs a connection to open", systemImage: "link")
        }
    }

    @ViewBuilder private var actions: some View {
        if let file = document.file {
            Button("Preview", systemImage: file.contentType.isImage ? "photo" : "doc.richtext") { previewURL = fileURL }
                .disabled(fileURL == nil)
            if let fileURL { ShareLink("Share file", item: fileURL) }
            LabeledContent("File", value: "\(file.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))")
        }
        if let link = document.linkURL {
            Button("Open link", systemImage: "safari") { openURL(link) }.disabled(!connectivity.isOnline)
            if document.file == nil {
                Button(downloading ? "Saving a copy…" : "Save a copy for offline use", systemImage: "arrow.down.doc") { saveOffline(link) }
                    .disabled(!connectivity.isOnline || downloading)
                ShareLink("Share link", item: link)
            }
            if !connectivity.isOnline { Text("Links need a connection.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func prepareFile() {
        guard document.file != nil else { fileURL = nil; fileProblem = nil; return }
        do { fileURL = try library.documentFiles.url(for: document); fileProblem = nil }
        catch { fileURL = nil; fileProblem = error.localizedDescription }
    }

    /// Explicit user action: download a link's contents so it opens offline.
    private func saveOffline(_ link: URL) {
        Task {
            downloading = true; failure = nil
            defer { downloading = false }
            do {
                let (bytes, filename) = try await DocumentImport.download(link)
                try document.attach(bytes, file: DocumentPolicy.inspect(bytes, filename: filename))
                library.save()
            } catch { failure = error.localizedDescription }
        }
    }
}
