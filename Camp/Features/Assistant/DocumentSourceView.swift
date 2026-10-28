import SwiftUI
import SwiftData
import PDFKit
import CampCore
import CampPersistence

/// Opens a cited document at the cited page. If the file has since been replaced or deleted it says so
/// instead of showing a different file at an old citation.
struct DocumentSourceView: View {
    enum Phase { case loading, ready(URL), changed, gone, failed }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(LibraryController.self) private var library
    let source: DocumentSource
    @State private var phase = Phase.loading

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Opening…")
                case .ready(let url):
                    PDFPageView(url: url, page: source.page)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("citedPageViewer")
                        .accessibilityLabel(source.pageDescription.map { "\(source.title), \($0)" } ?? source.title)
                case .changed:
                    unavailable("This document has changed", "It was replaced after this answer, so the cited page may not match. Ask again to get an answer from the current file.")
                case .gone:
                    unavailable("This document is gone", "It was deleted after this answer.")
                case .failed:
                    unavailable("Couldn’t open this document", "Try again in a moment.")
                }
            }
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if case .ready = phase, let description = source.pageDescription {
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

    private func load() async {
        guard let document = context.document(withID: source.documentID) else { phase = .gone; return }
        guard document.checksum == source.checksum else { phase = .changed; return }
        do { phase = .ready(try await library.documentFiles.url(for: document)) }
        catch is CancellationError { }
        catch { phase = .failed }
    }
}

/// PDFKit's viewer, scrolled to a one-based page ordinal.
struct PDFPageView: UIViewRepresentable {
    let url: URL
    let page: Int?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        goToPage(in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        goToPage(in: view)
    }

    private func goToPage(in view: PDFView) {
        guard let page, let document = view.document, (1...max(document.pageCount, 1)).contains(page),
              let target = document.page(at: page - 1) else { return }
        // The view has no size yet on first layout; go again once it has.
        view.go(to: target)
        DispatchQueue.main.async { view.go(to: PDFDestination(page: target, at: CGPoint(x: 0, y: target.bounds(for: .mediaBox).height))) }
    }
}
