import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import CampCore
import DocumentVault

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
    @State private var cloudStatus: DocumentCloudStatus?

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
                        if let cloudStatus { cloudStatusLabel(cloudStatus) }
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
                // Sync events bump `mediaRevision`, so the status follows uploads as they finish.
                .task(id: "\(document.updatedAt.timeIntervalSinceReferenceDate)-\(store.mediaRevision)") {
                    cloudStatus = await store.cloudStatus(ofDocument: documentID)
                }
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

    @ViewBuilder private func cloudStatusLabel(_ status: DocumentCloudStatus) -> some View {
        switch status {
        case .localOnly: Label("On this iPhone only · iCloud sync is off", systemImage: "iphone")
        case .waitingToUpload: Label("Waiting to upload to iCloud", systemImage: "icloud.and.arrow.up")
        case .inICloud: Label("Saved in iCloud", systemImage: "checkmark.icloud")
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
