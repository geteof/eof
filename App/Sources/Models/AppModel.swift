import Combine
import SwiftUI
import EOFCore

struct RecentItem: Codable, Identifiable, Equatable {
    var id: String { path }
    var name: String
    var path: String
    var location: String
    var bookmark: Data
    var isFolder: Bool
}

/// One entry of the folder tree. Children load when the node is first expanded.
final class FileNode: ObservableObject, Identifiable {
    let url: URL
    let isDirectory: Bool
    @Published var children: [FileNode]?
    @Published var isExpanded = false {
        didSet { if isExpanded, children == nil { reload() } }
    }

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    func reload() {
        guard isDirectory else { return }
        let showHidden = AppSettings.shared.showHiddenFiles
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        let previous = Dictionary(uniqueKeysWithValues: (children ?? []).map { ($0.url, $0) })
        children = contents
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { item -> FileNode in
                if let existing = previous[item] { return existing }
                let values = try? item.resourceValues(forKeys: Set(keys))
                return FileNode(url: item, isDirectory: (values?.isDirectory ?? false) && !(values?.isPackage ?? false))
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    static func symbol(for name: String) -> String {
        let language = Languages.detect(filename: name)
        switch language.id {
        case "plain":
            let ext = (name as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "ico", "bmp", "tiff", "tif", "avif"].contains(ext) { return "photo" }
            if ["zip", "gz", "tar", "7z", "rar", "xz", "bz2"].contains(ext) { return "doc.zipper" }
            if ["pdf"].contains(ext) { return "doc.richtext" }
            if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) { return "film" }
            if ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"].contains(ext) { return "waveform" }
            if ["doc", "docx", "pages", "rtf", "odt"].contains(ext) { return "doc.richtext" }
            if ["xls", "xlsx", "numbers", "ods"].contains(ext) { return "tablecells" }
            if ["ppt", "pptx", "key", "odp"].contains(ext) { return "rectangle.on.rectangle" }
            if ["svg"].contains(ext) { return "photo" }
            return "doc.text"
        case "markdown": return "doc.plaintext"
        case "json", "yaml", "toml", "ini", "xml": return "list.bullet.rectangle"
        case "html", "css", "scss": return "globe"
        case "shell", "dockerfile", "makefile", "batch", "powershell": return "terminal"
        case "swift": return "swift"
        case "diff": return "plusminus"
        case "csv": return "tablecells"
        case "gitignore": return "eye.slash"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var documents: [EditorDocument] = []
    @Published var folder: FileNode?
    @Published var recents: [RecentItem] = []
    @Published var alert: AppAlert?
    @Published var loadingName: String?
    /// A document whose closing needs the user's confirmation because text would be lost.
    @Published var pendingClose: EditorDocument?
    /// The window the user last worked in. Opening a file, a folder or a new document lands here.
    weak var focusedWindow: WindowState?
    private var windowRefs: [WeakWindow] = []

    private struct WeakWindow {
        weak var value: WindowState?
    }

    var windows: [WindowState] { windowRefs.compactMap(\.value) }

    private let settings = AppSettings.shared
    private let defaults = UserDefaults.standard
    private var folderIsScoped = false
    private var untitledCounter = 0
    private var loadingPaths = Set<String>()
    /// Files load one at a time, so several opened together appear in the order they were asked for.
    private let loadQueue = DispatchQueue(label: "moe.luoling.eof.load", qos: .userInitiated)

    func document(_ id: EditorDocument.ID?) -> EditorDocument? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    func register(_ window: WindowState) {
        windowRefs.removeAll { $0.value == nil || $0.value === window }
        windowRefs.append(WeakWindow(value: window))
        if focusedWindow == nil { focusedWindow = window }
    }

    func isVisible(_ id: EditorDocument.ID) -> Bool {
        windows.contains { $0.pane(showing: id) != nil }
    }

    private init() {
        if let data = defaults.data(forKey: "recents"), let items = try? JSONDecoder().decode([RecentItem].self, from: data) {
            recents = items
        }
    }

    // MARK: - Documents

    /// Shows the document in a window's pane: the given ones, or where the user last worked. A
    /// document already shown in that window is focused there, or swapped when another pane is
    /// asked for; one shown in another window moves here.
    func activate(_ document: EditorDocument, in window: WindowState? = nil, pane: EditorPane? = nil) {
        guard let window = window ?? focusedWindow ?? windows.first else { return }
        focusedWindow = window
        let id = document.id
        var target = pane ?? window.focusedPane
        if target == .secondary, window.primaryID == nil || (!window.isSplit && pane == nil) { target = .primary }
        if let current = window.pane(showing: id) {
            if current != target, pane != nil {
                let other = window.documentID(in: target)
                if current == .primary, other == nil {
                    // Moving the first pane's document aside needs something to take its place.
                    guard let replacement = splitCandidate(for: window, excluding: id) else { return }
                    window.primaryID = replacement.id
                } else {
                    window.set(other, in: current)
                }
                window.set(id, in: target)
            } else {
                target = current
            }
        } else {
            for other in windows where other !== window { other.release(id) }
            window.set(id, in: target)
        }
        window.focusedPane = target
        window.compactColumn = .detail
        document.checkForExternalChange()
    }

    /// A document to put in a second pane: the next one in tab order that no window shows.
    func splitCandidate(for window: WindowState, excluding excluded: EditorDocument.ID? = nil) -> EditorDocument? {
        let start = documents.firstIndex { $0.id == window.primaryID } ?? -1
        let ordered = documents.indices.map { documents[($0 + start + 1) % documents.count] }
        return ordered.first { $0.id != excluded && !isVisible($0.id) }
    }

    func closeSplit(in window: WindowState) {
        window.secondaryID = nil
        window.focusedPane = .primary
    }

    @discardableResult
    func newDocument(text: String = "", name: String? = nil) -> EditorDocument {
        untitledCounter += 1
        let title = name ?? (untitledCounter == 1 ? String(localized: "Untitled") : String(localized: "Untitled \(untitledCounter)"))
        let document = EditorDocument(untitled: title, text: text)
        documents.append(document)
        activate(document)
        if !text.isEmpty { document.markEdited() }
        saveSession()
        return document
    }

    /// Opens a file, or switches to it when it is already open. `selecting` moves the caret afterwards.
    func open(_ url: URL, selecting range: NSRange? = nil, activate shouldActivate: Bool = true, in window: WindowState? = nil, pane: EditorPane? = nil) {
        let target = url.standardizedFileURL
        // Remember where the request came from: loading finishes later.
        let destination = window ?? focusedWindow
        if let existing = documents.first(where: { $0.url?.standardizedFileURL == target }) {
            if shouldActivate { activate(existing, in: destination, pane: pane) }
            if let range { DispatchQueue.main.async { existing.controller.select(range, focus: false) } }
            return
        }
        guard loadingPaths.insert(target.path).inserted else { return }
        loadingName = url.lastPathComponent
        let fallbacks = (settings.defaultEncoding, settings.defaultLineEnding)
        let theme = EditorController.currentTheme()
        loadQueue.async {
            let result = Result { try LoadedFile.load(url, defaults: fallbacks) }
            // Parse for the editor here as well: for a large file this is most of the work.
            var prepared: PreparedEditorState?
            if case .success(let loaded) = result, let text = loaded.text {
                prepared = PreparedEditorState.prepare(
                    text: text, language: loaded.language, filename: url.lastPathComponent,
                    highlighting: (text as NSString).length <= LoadedFile.highlightLimit, theme: theme
                )
            }
            DispatchQueue.main.async {
                self.loadingPaths.remove(target.path)
                if self.loadingPaths.isEmpty { self.loadingName = nil }
                switch result {
                case .success(let loaded):
                    let document = EditorDocument(url: url, loaded: loaded)
                    document.preparedState = prepared
                    self.documents.append(document)
                    if shouldActivate { self.activate(document, in: destination, pane: pane) }
                    self.remember(url, isFolder: false)
                    if let range { DispatchQueue.main.async { document.controller.select(range, focus: false) } }
                    self.saveSession()
                case .failure(let error):
                    self.alert = AppAlert(title: String(localized: "Could Not Open “\(url.lastPathComponent)”"), message: error.localizedDescription)
                }
            }
        }
    }

    /// Opens whatever the system hands over: a file, or a folder as the project.
    func openAny(_ url: URL) {
        let isDirectory = FileAccess.withAccess(url) { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        if isDirectory { openFolder(url) } else { open(url) }
    }

    func close(_ document: EditorDocument) {
        document.autosave()
        if document.isUntitled { document.discardDraft() }
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        for window in windows where window.pane(showing: document.id) != nil {
            let wasPrimary = window.primaryID == document.id
            window.release(document.id)
            if wasPrimary, window.primaryID == nil {
                // Show the neighbouring tab, if no other pane shows it already.
                let candidates = Array(documents[min(index, documents.count)...]) + documents[..<min(index, documents.count)].reversed()
                window.primaryID = candidates.first { !isVisible($0.id) }?.id
            }
            if window.primaryID == nil { window.compactColumn = .sidebar }
        }
        saveSession()
    }

    /// Closes the document, asking first when that would discard unsaved text.
    func requestClose(_ document: EditorDocument) {
        document.autosave()
        if closingLosesWork(document) {
            pendingClose = document
        } else {
            close(document)
        }
    }

    func closeOthers(keeping document: EditorDocument) {
        for other in documents where other.id != document.id && !(other.isUntitled && other.isDirty) {
            close(other)
        }
    }

    /// True when closing would throw away text that exists nowhere else.
    func closingLosesWork(_ document: EditorDocument) -> Bool {
        if document.isBinary { return false }
        if document.isUntitled { return document.isDirty && !document.text.isEmpty }
        return document.isDirty && (document.saveError != nil || document.hasConflict || !settings.autosave)
    }

    func saveAll() {
        for document in documents { document.autosave() }
        saveSession()
    }

    func checkExternalChanges() {
        for document in documents where isVisible(document.id) { document.checkForExternalChange() }
    }

    // MARK: - Folder

    /// Makes `url` the project folder. `browse` also brings up the file browser on it.
    func openFolder(_ url: URL, browse: Bool = true) {
        closeFolder()
        folderIsScoped = url.startAccessingSecurityScopedResource()
        folder = FileNode(url: url, isDirectory: true)
        if browse { focusedWindow?.showBrowser = true }
        remember(url, isFolder: true)
        saveSession()
    }

    func closeFolder() {
        guard let current = folder else { return }
        // Keep access while documents inside the folder are still open.
        let prefix = current.url.standardizedFileURL.path + "/"
        let inUse = documents.contains { $0.url?.standardizedFileURL.path.hasPrefix(prefix) ?? false }
        if folderIsScoped, !inUse { current.url.stopAccessingSecurityScopedResource() }
        folderIsScoped = false
        windows.forEach { $0.showBrowser = false }
        folder = nil
        saveSession()
    }

    // MARK: - Recents

    private func remember(_ url: URL, isFolder: Bool) {
        guard let bookmark = FileAccess.bookmark(for: url) else { return }
        let item = RecentItem(name: url.lastPathComponent, path: url.standardizedFileURL.path, location: FileAccess.displayLocation(url), bookmark: bookmark, isFolder: isFolder)
        recents.removeAll { $0.path == item.path }
        recents.insert(item, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        persistRecents()
    }

    func openRecent(_ item: RecentItem) {
        guard let url = FileAccess.resolve(item.bookmark), FileAccess.exists(url) else {
            recents.removeAll { $0.id == item.id }
            persistRecents()
            alert = AppAlert(title: String(localized: "File Not Found"), message: String(localized: "“\(item.name)” was moved or deleted."))
            return
        }
        if item.isFolder { openFolder(url) } else { open(url) }
    }

    func removeRecent(_ item: RecentItem) {
        recents.removeAll { $0.id == item.id }
        persistRecents()
    }

    func clearRecents() {
        recents = []
        persistRecents()
    }

    private func persistRecents() {
        defaults.set(try? JSONEncoder().encode(recents), forKey: "recents")
    }

    // MARK: - Session

    private struct Session: Codable {
        struct Entry: Codable {
            var bookmark: Data?
            var draftID: String?
            var name: String
        }

        var entries: [Entry]
        var active: Int?
        var folder: Data?
    }

    func saveSession() {
        var entries: [Session.Entry] = []
        var active: Int?
        for document in documents {
            if let url = document.url {
                guard let bookmark = FileAccess.bookmark(for: url) else { continue }
                entries.append(Session.Entry(bookmark: bookmark, draftID: nil, name: document.name))
            } else if let draftID = document.draftID {
                entries.append(Session.Entry(bookmark: nil, draftID: draftID, name: document.name))
            } else {
                continue
            }
            if document.id == focusedWindow?.primaryID { active = entries.count - 1 }
        }
        let session = Session(entries: entries, active: active, folder: folder.flatMap { FileAccess.bookmark(for: $0.url) })
        defaults.set(try? JSONEncoder().encode(session), forKey: "session")
    }

    private var didRestore = false

    /// Reopens what was open last time. Documents come back in order; the active one is selected.
    func restoreSession() {
        guard !didRestore else { return }
        didRestore = true
        guard let data = defaults.data(forKey: "session"), let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        if let bookmark = session.folder, let url = FileAccess.resolve(bookmark), FileAccess.exists(url) {
            openFolder(url, browse: false)
        }
        let fallbacks = (settings.defaultEncoding, settings.defaultLineEnding)
        var restored: [EditorDocument] = []
        var activeDocument: EditorDocument?
        for (index, entry) in session.entries.enumerated() {
            var document: EditorDocument?
            if let bookmark = entry.bookmark, let url = FileAccess.resolve(bookmark), let loaded = try? LoadedFile.load(url, defaults: fallbacks) {
                document = EditorDocument(url: url, loaded: loaded)
            } else if let draftID = entry.draftID {
                let file = FileAccess.draftsDirectory.appendingPathComponent(draftID)
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let draft = EditorDocument(untitled: entry.name, draftID: draftID, text: text)
                draft.isDirty = !text.isEmpty
                untitledCounter += 1
                document = draft
            }
            guard let document else { continue }
            restored.append(document)
            if index == session.active { activeDocument = document }
        }
        documents = restored + documents
        if let window = focusedWindow, window.primaryID == nil, let target = activeDocument ?? restored.last {
            window.primaryID = target.id
            window.compactColumn = .detail
        }
    }
}

/// Actions that menus and keyboard shortcuts send to the visible editor.
enum EditorCommand {
    case find, replace, findInFolder, goToLine, togglePreview, save, saveAs, outline
    case openFile, openFolder, closeDocument, browseFiles, toggleSplit
}
