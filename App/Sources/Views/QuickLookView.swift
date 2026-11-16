import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Which files are shown by the system previewer instead of being read as text.
enum FileKind {
    /// Types that are never text. They are not read into memory just to find that out.
    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        if type.conforms(to: .svg) { return false } // SVG is XML: it opens in the editor, with a preview
        let families: [UTType] = [.image, .audiovisualContent, .pdf, .archive, .spreadsheet, .presentation, .font, .threeDContent, .rtfd, .epub, .diskImage, .executable]
        if families.contains(where: { type.conforms(to: $0) }) { return true }
        // Word-processing documents have no common parent type.
        let documents = ["doc", "docx", "pages", "numbers", "key", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf"]
        return documents.contains(url.pathExtension.lowercased())
    }

    static func canPreview(_ url: URL) -> Bool {
        QLPreviewController.canPreview(url as NSURL)
    }

    /// "PNG image", "PDF document"… for the status bar.
    static func describe(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension.lowercased())?.localizedDescription ?? String(localized: "Binary")
    }
}

/// The system's Quick Look viewer, embedded as the document's content: images, PDF, audio, video,
/// Office and iWork documents, 3D models and whatever else iOS can show.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.source != url else { return }
        context.coordinator.prepare(url)
        controller.reloadData()
    }

    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) {
        coordinator.cleanUp()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private(set) var source: URL
        private var item: URL
        private var isScoped = false
        private var temporaryFolder: URL?

        init(url: URL) {
            source = url
            item = url
            super.init()
            prepare(url)
        }

        /// Quick Look renders in another process, which cannot use this app's access to a file picked
        /// from Files or another app. A private copy always works; very large files are shown in
        /// place instead, with access held open for as long as the preview lives.
        func prepare(_ url: URL) {
            cleanUp()
            source = url
            item = url
            isScoped = url.startAccessingSecurityScopedResource()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard size <= 80_000_000 else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-" + UUID().uuidString, isDirectory: true)
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
                temporaryFolder = folder
                item = copy
                if isScoped {
                    url.stopAccessingSecurityScopedResource()
                    isScoped = false
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
            }
        }

        func cleanUp() {
            if isScoped {
                source.stopAccessingSecurityScopedResource()
                isScoped = false
            }
            if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
            temporaryFolder = nil
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            item as NSURL
        }
    }
}
