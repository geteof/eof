import Combine
import SwiftUI
import TesseraCore

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
            if ["png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "bmp", "tiff"].contains(ext) { return "photo" }
            if ["zip", "gz", "tar", "7z", "rar", "xz", "bz2"].contains(ext) { return "doc.zipper" }
            if ["pdf"].contains(ext) { return "doc.richtext" }
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
    @Published var activeID: EditorDocument.ID?
    @Published var folder: FileNode?
    @Published var recents: [RecentItem] = []
    @Published var compactColumn: NavigationSplitViewColumn = .sidebar
    @Published var alert: AppAlert?
    @Published var loadingName: String?
    /// A document whose closing needs the user's confirmation because text would be lost.
    @Published var pendingClose: EditorDocument?
    /// A request for the editor screen to act on the active document (from menus and shortcuts).
    let commands = PassthroughSubject<EditorCommand, Never>()

    private let settings = AppSettings.shared
    private let defaults = UserDefaults.standard
    private var folderIsScoped = false
    private var untitledCounter = 0

    var activeDocument: EditorDocument? { documents.first { $0.id == activeID } }

    private init() {
        if let data = defaults.data(forKey: "recents"), let items = try? JSONDecoder().decode([RecentItem].self, from: data) {
            recents = items
        }
    }

    // MARK: - Documents

    func activate(_ document: EditorDocument) {
        activeID = document.id
        compactColumn = .detail
        document.checkForExternalChange()
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
    func open(_ url: URL, selecting range: NSRange? = nil, activate shouldActivate: Bool = true) {
        let target = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url?.standardizedFileURL == target }) {
            if shouldActivate { activate(existing) }
            if let range { DispatchQueue.main.async { existing.controller.select(range, focus: false) } }
            return
        }
        loadingName = url.lastPathComponent
        let fallbacks = (settings.defaultEncoding, settings.defaultLineEnding)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LoadedFile.load(url, defaults: fallbacks) }
            DispatchQueue.main.async {
                self.loadingName = nil
                switch result {
                case .success(let loaded):
                    let document = EditorDocument(url: url, loaded: loaded)
                    self.documents.append(document)
                    if shouldActivate { self.activate(document) }
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
        if activeID == document.id {
            let next = documents.indices.contains(index) ? documents[index] : documents.last
            activeID = next?.id
            if next == nil { compactColumn = .sidebar }
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
        activeDocument?.checkForExternalChange()
    }

    // MARK: - Folder

    func openFolder(_ url: URL) {
        closeFolder()
        folderIsScoped = url.startAccessingSecurityScopedResource()
        let node = FileNode(url: url, isDirectory: true)
        node.isExpanded = true
        folder = node
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
            if document.id == activeID { active = entries.count - 1 }
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
            openFolder(url)
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
        if activeID == nil, let target = activeDocument ?? restored.last {
            activeID = target.id
            compactColumn = .detail
        }
    }
}

/// Actions that menus and keyboard shortcuts send to the visible editor.
enum EditorCommand {
    case find, replace, findInFolder, goToLine, togglePreview, save, saveAs, outline
    case openFile, openFolder, closeDocument
}
