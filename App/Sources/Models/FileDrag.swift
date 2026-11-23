import SwiftUI
import UniformTypeIdentifiers

/// What a file or an open document carries when it is dragged: the file itself, for other apps,
/// and a request for an EOF window showing it, so dropping it at the side of the screen opens
/// it in a new window beside this one.
enum FileDrag {
    static let activityType = "moe.luoling.eof.open"
    /// A tab moving along the tab strip. Only this app sees it.
    static let tabType = UTType(exportedAs: "moe.luoling.eof.tab")
    /// A file from this app's own lists, by path, so a drop on the editor opens the file itself
    /// rather than a copy. Only this app sees it.
    static let fileType = UTType(exportedAs: "moe.luoling.eof.file")
    /// Everything the editor area looks at; `canOpen` decides what it takes.
    static let droppableTypes: [UTType] = [tabType, fileType, .fileURL, .item]

    /// - Parameters:
    ///   - opensWindow: Off for folders: a window shows files, and the project folder is shared by all windows.
    static func provider(url: URL?, document: EditorDocument.ID? = nil, name: String, opensWindow: Bool = true) -> NSItemProvider {
        let provider = url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        provider.suggestedName = name
        if opensWindow {
            let activity = NSUserActivity(activityType: activityType)
            var info: [String: Any] = [:]
            if let url { info["path"] = url.path }
            if let document { info["document"] = document.uuidString }
            activity.userInfo = info
            activity.title = name
            provider.registerObject(activity, visibility: .all)
        }
        if let url, opensWindow {
            provider.registerDataRepresentation(forTypeIdentifier: fileType.identifier, visibility: .ownProcess) { completion in
                completion(Data(url.path.utf8), nil)
                return nil
            }
        }
        if let document {
            provider.registerDataRepresentation(forTypeIdentifier: tabType.identifier, visibility: .ownProcess) { completion in
                completion(Data(document.uuidString.utf8), nil)
                return nil
            }
        }
        return provider
    }

    /// True for a file the editor can open: a tab or file from this app, a file URL, or a file
    /// another app (Files) offers to open in place. Text and images dragged from elsewhere are left alone.
    static func canOpen(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(tabType.identifier)
                || provider.hasItemConformingToTypeIdentifier(fileType.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasRepresentationConforming(toTypeIdentifier: UTType.item.identifier, fileOptions: .openInPlace)
        }
    }

    /// Opens what was dropped: the first file in `pane`, any others as tabs.
    static func open(_ providers: [NSItemProvider], model: AppModel, window: WindowState, pane: EditorPane) {
        for (index, provider) in providers.enumerated() {
            let target: EditorPane? = index == 0 ? pane : nil
            let show = index == 0
            func openURL(_ url: URL) {
                DispatchQueue.main.async { model.open(url, activate: show, in: window, pane: target) }
            }
            if provider.hasItemConformingToTypeIdentifier(tabType.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: tabType.identifier) { data, _ in
                    guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
                    DispatchQueue.main.async {
                        if let document = model.document(id) { model.activate(document, in: window, pane: target) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(fileType.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: fileType.identifier) { data, _ in
                    guard let data else { return }
                    openURL(URL(fileURLWithPath: String(decoding: data, as: UTF8.self)))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { openURL(url) }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: {
                provider.hasRepresentationConforming(toTypeIdentifier: $0, fileOptions: .openInPlace)
            }) {
                // Another app's file, edited where it lives, like a file opened from Files.
                provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, _ in
                    guard let url else { return }
                    if inPlace {
                        openURL(url)
                    } else if let copy = keepCopy(of: url) {
                        openURL(copy)
                    }
                }
            }
        }
    }

    /// A file handed over only as a temporary copy is kept in Documents/Dropped, since the
    /// system removes the original when the load returns.
    private static func keepCopy(of url: URL) -> URL? {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Dropped", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        let base = url.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(url.pathExtension)
            counter += 1
        }
        return (try? FileManager.default.copyItem(at: url, to: destination)) != nil ? destination : nil
    }
}

