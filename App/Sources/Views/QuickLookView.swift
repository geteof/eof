import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Which files are shown by the system previewer instead of being read as text.
enum FileKind {
    /// Types Quick Look draws real content for.
    private static let viewable: [UTType] = [.image, .audiovisualContent, .pdf, .spreadsheet, .presentation, .threeDContent, .rtfd, .epub]
    /// Types that are binary but have nothing to look at: these go to the hex view.
    private static let opaque: [UTType] = [.archive, .font, .diskImage, .executable]
    /// Word-processing documents have no common parent type.
    private static let documentExtensions: Set<String> = ["doc", "docx", "pages", "numbers", "key", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf"]

    private static func type(_ url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension.lowercased())
    }

    /// Types that are never text. They are not read into memory just to find that out.
    static func isMedia(_ url: URL) -> Bool {
        if documentExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = type(url) else { return false }
        if type.conforms(to: .svg) { return false } // SVG is XML: it opens in the editor, with a preview
        return (viewable + opaque).contains { type.conforms(to: $0) }
    }

    /// True when the system previewer shows the file's content. Quick Look accepts nearly every
    /// file, but for an archive or an unknown binary it only draws an icon and a name, so the
    /// decision is made from the type first.
    static func canPreview(_ url: URL) -> Bool {
        let known = documentExtensions.contains(url.pathExtension.lowercased())
            || (type(url).map { type in !type.conforms(to: .svg) && viewable.contains { type.conforms(to: $0) } } ?? false)
        return known && QLPreviewController.canPreview(url as NSURL)
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
