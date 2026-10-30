import SwiftUI
import SwiftData
import PDFKit
import CampCore
import CampPersistence
import DocumentVault
import ImageIO

/// Opens a cited document at the cited page. If the file has since been replaced or deleted it says so
/// instead of showing a different file at an old citation.
struct DocumentSourceView: View {
    enum Phase { case loading, ready(URL), readyImage(URL), changed, gone, notDownloaded, failed }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    let source: DocumentSource
    @State private var phase = Phase.loading
    /// Set only by the camper choosing "Open current version"; the cited page doesn't carry over.
    @State private var showsCurrentVersion = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Opening…")
                case .ready(let url):
                    PDFPageView(url: url, page: showsCurrentVersion ? nil : source.page)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("citedPageViewer")
                        .accessibilityLabel(viewerLabel)
                case .readyImage(let url):
                    ScannedImageView(url: url)
                        .accessibilityIdentifier("citedPageViewer")
                        .accessibilityLabel(source.title)
                case .changed:
                    VStack(spacing: 8) {
                        unavailable("Changed since this answer", "This document was replaced, so the cited page may not match the file now. Ask again for an answer from the current file, or open the current version to look yourself.")
                        Button("Open current version") { showsCurrentVersion = true; Task { await open() } }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("openCurrentVersion")
                            .padding(.bottom, 32)
                    }
                case .gone:
                    unavailable("No longer in your library", "This document was deleted after this answer.")
                        .accessibilityIdentifier("sourceUnavailable")
                case .notDownloaded:
                    unavailable("Waiting for download", "This document is in your library but hasn’t finished downloading to this device. Try again once it has.")
                case .failed:
                    unavailable("Couldn’t open this document", "Try again in a moment.")
                }
            }
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if case .ready = phase, !showsCurrentVersion, let description = source.pageDescription {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(source.title).font(.headline).lineLimit(1)
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func unavailable(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc.questionmark", description: Text(message))
    }

    private var viewerLabel: String {
        if showsCurrentVersion { return "\(source.title), current version" }
        return source.pageDescription.map { "\(source.title), \($0)" } ?? source.title
    }

    private func load() async {
        // Checked now, not when the answer was written: a replaced or deleted file is never opened as the citation.
        switch context.availability(of: source) {
        case .deleted: phase = .gone
        case .changed: phase = .changed
        case .notDownloaded: phase = .notDownloaded
        case .current: await open()
        }
    }

    private func open() async {
        guard let document = context.document(withID: source.documentID) else { phase = .gone; return }
        let isImage = document.file?.contentType.isImage == true
        do {
            let url = try await library.documentFiles.url(for: document)
            phase = isImage ? .readyImage(url) : .ready(url)
        }
        catch is CancellationError { }
        catch { phase = .failed }
    }
}

/// PDFKit's viewer, scrolled to a one-based page ordinal. The jump waits for the first real layout, so it lands
/// on the cited page at any width (iPhone, a regular-width iPad sheet, or a resizable Mac window), and it happens
/// once: later SwiftUI updates never pull a camper back from where they scrolled.
struct PDFPageView: UIViewRepresentable {
    let url: URL
    let page: Int?

    final class Viewer: PDFView {
        var pendingPage: PDFPage?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let target = pendingPage, bounds.width > 0, bounds.height > 0 else { return }
            pendingPage = nil
            // Fit-to-width settles during this layout pass; go to the page's top edge after it.
            DispatchQueue.main.async { [weak self] in
                self?.go(to: PDFDestination(page: target, at: CGPoint(x: 0, y: target.bounds(for: .mediaBox).height)))
            }
        }
    }

    func makeUIView(context: Context) -> Viewer {
        let view = Viewer()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        if let page, let document = view.document, (1...max(document.pageCount, 1)).contains(page) {
            view.pendingPage = document.page(at: page - 1)
        }
        return view
    }

    func updateUIView(_ view: Viewer, context: Context) {}
}

/// An image document at a size the screen can hold: decoded with ImageIO to a bounded thumbnail rather than
/// loading every pixel of a large photo.
struct ScannedImageView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .task {
            let url = url
            image = await Task.detached { () -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_400
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
            }.value
        }
    }
}
