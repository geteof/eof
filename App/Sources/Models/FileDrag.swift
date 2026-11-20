import SwiftUI
import UniformTypeIdentifiers

/// What a file or an open document carries when it is dragged: the file itself, for other apps,
/// and a request for an EOF window showing it, so dropping it at the side of the screen opens
/// it in a new window beside this one.
enum FileDrag {
    static let activityType = "moe.luoling.eof.open"
    /// A tab moving along the tab strip. Only this app sees it.
    static let tabType = UTType(exportedAs: "moe.luoling.eof.tab")

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
        if let document {
            provider.registerDataRepresentation(forTypeIdentifier: tabType.identifier, visibility: .ownProcess) { completion in
                completion(Data(document.uuidString.utf8), nil)
                return nil
            }
        }
        return provider
    }
}
