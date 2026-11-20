import PDFKit
import SwiftUI

/// PDFs are drawn here, in the app, rather than by Quick Look: Quick Look renders in another
/// process, so its scrolling cannot be seen, and the bars could not hide while reading.
struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    /// Same contract as the editor's: offset, top of the content, and whether the user scrolled.
    let onScroll: (_ offset: CGFloat, _ top: CGFloat, _ userDriven: Bool) -> Void

    /// Nil when the file cannot be read or needs a password; Quick Look handles those.
    static func load(_ url: URL) -> PDFDocument? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        return document
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        context.coordinator.onScroll = onScroll
        // PDFView builds its scroll view when it gets a document; watch it once it is there.
        DispatchQueue.main.async { context.coordinator.watch(view) }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onScroll = onScroll
        if view.document !== document { view.document = document }
    }

    final class Coordinator {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        func watch(_ view: PDFView) {
            guard let scrollView = Self.scrollView(in: view) else { return }
            // The screen decides the edges: with the bars shown the view already sits inside the
            // safe area, and with them hidden the pages should reach the top of the screen. Left
            // to adjust itself, the scroll view kept a strip the height of the status bar empty.
            scrollView.contentInsetAdjustmentBehavior = .never
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                let top = -scrollView.adjustedContentInset.top
                let userDriven = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
                MainActor.assumeIsolated {
                    self?.onScroll?(scrollView.contentOffset.y, top, userDriven)
                }
            }
        }

        private static func scrollView(in view: UIView) -> UIScrollView? {
            for subview in view.subviews {
                if let scrollView = subview as? UIScrollView { return scrollView }
                if let found = scrollView(in: subview) { return found }
            }
            return nil
        }
    }
}

/// A PDF in the app's own viewer, or in Quick Look when PDFKit cannot open it (a password, a
/// damaged file).
struct PDFPreview: View {
    let url: URL
    let onScroll: (_ offset: CGFloat, _ top: CGFloat, _ userDriven: Bool) -> Void
    @State private var document: PDFDocument?
    @State private var failed = false

    var body: some View {
        if let document {
            PDFDocumentView(document: document, onScroll: onScroll)
        } else if failed {
            QuickLookView(url: url)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    if let loaded = PDFDocumentView.load(url) { document = loaded } else { failed = true }
                }
        }
    }
}
