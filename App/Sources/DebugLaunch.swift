#if DEBUG
import SwiftUI

/// Launch arguments for checking screens in the simulator without tapping through the UI.
///
///     -open <path>      open a file (repeatable; paths are relative to the app's Documents folder)
///     -folder <path>    open a folder as the project
///     -find <text>      show the find bar with this query (-replace also shows the replace row)
///     -preview          show the Markdown / HTML preview
///     -sheet <name>     outline | statistics | compare | language
///     -line <n>         put the caret on this line
///     -readonly         open in read-only mode
enum DebugLaunch {
    private static let arguments = ProcessInfo.processInfo.arguments
    private static var consumed = false

    static var isActive: Bool { arguments.contains("-open") || arguments.contains("-folder") }

    private static func values(_ flag: String) -> [String] {
        arguments.indices.compactMap { index in
            arguments[index] == flag && index + 1 < arguments.count ? arguments[index + 1] : nil
        }
    }

    private static func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
    }

    static func open(in model: AppModel) {
        if let folder = values("-folder").first { model.openFolder(resolve(folder)) }
        for path in values("-open") { model.open(resolve(path)) }
    }

    static func apply(to document: EditorDocument, showFind: inout Bool, findWithReplace: inout Bool, showPreview: inout Bool, sheet: inout EditorSheet?) {
        guard isActive, !consumed else { return }
        // Only the last file given is decorated; earlier ones just fill the tab strip.
        guard let last = values("-open").last, document.url?.lastPathComponent == resolve(last).lastPathComponent else { return }
        consumed = true
        if arguments.contains("-readonly") { document.userReadOnly = true }
        if arguments.contains("-preview") { showPreview = true }
        if let name = values("-sheet").first { sheet = EditorSheet(rawValue: name) }
        if let line = values("-line").first.flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { document.controller.goToLine(line) }
        }
        if let query = values("-find").first {
            findWithReplace = arguments.contains("-replace")
            showFind = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NotificationCenter.default.post(name: .debugFindQuery, object: query)
            }
        }
    }
}

extension Notification.Name {
    static let debugFindQuery = Notification.Name("TesseraDebugFindQuery")
}
#endif
