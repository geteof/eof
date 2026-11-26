import Combine
import SwiftUI
import EOFCore

/// Caret position and counts, published separately so that moving the caret only redraws the status bar.
final class CursorStatus: ObservableObject {
    @Published private(set) var line = 1
    @Published private(set) var column = 1
    @Published private(set) var selection = 0
    @Published private(set) var lines = 1
    @Published private(set) var length = 0

    func update(line: Int, column: Int, selection: Int, lines: Int, length: Int) {
        if self.line != line { self.line = line }
        if self.column != column { self.column = column }
        if self.selection != selection { self.selection = selection }
        if self.lines != lines { self.lines = lines }
        if self.length != length { self.length = length }
    }
}

/// What a file turned out to be once its bytes were read.
struct LoadedFile {
    enum Content {
        case text(String)
        case binary(Data)
        /// A picture, PDF, video or similar: shown by the system previewer, never read as text.
        case media
    }

    var content: Content
    var encoding: TextEncoding
    var lineEnding: LineEnding
    var mixedLineEndings: Bool
    var indent: IndentStyle?
    var language: Language
    var byteCount: Int
    var modified: Date?

    /// Above this many UTF-16 units a file opens without syntax colouring.
    static let highlightLimit = 4_000_000
    /// Above this it also opens read-only.
    static let editLimit = 24_000_000

    var text: String? {
        if case .text(let text) = content { return text }
        return nil
    }

    static func load(_ url: URL, encoding forced: TextEncoding? = nil, defaults: (encoding: TextEncoding, lineEnding: LineEnding)) throws -> LoadedFile {
        let modified = FileAccess.modificationDate(url)
        let name = url.lastPathComponent
        // An extension can name both source code and a media format: .ts is TypeScript and an MPEG-2
        // transport stream. When a language claims the extension, the first bytes decide.
        if forced == nil, FileKind.isMedia(url), !(Languages.claimsExtension(url.pathExtension) && !TextEncoding.looksBinary(FileAccess.head(url))) {
            let size = FileAccess.withAccess(url) { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            return LoadedFile(content: .media, encoding: defaults.encoding, lineEnding: defaults.lineEnding, mixedLineEndings: false, indent: nil, language: Languages.plain, byteCount: size, modified: modified)
        }
        let data = try FileAccess.read(url)
        var detection: TextEncoding.Detection?
        if let forced {
            detection = forced.decode(data).map { TextEncoding.Detection(text: $0, encoding: forced) }
            if detection == nil { throw FileAccess.Failure(message: String(localized: "This file is not valid \(forced.name) text.")) }
        } else {
            detection = TextEncoding.detect(data)
        }
        guard let detection else {
            return LoadedFile(content: .binary(data), encoding: defaults.encoding, lineEnding: defaults.lineEnding, mixedLineEndings: false, indent: nil, language: Languages.plain, byteCount: data.count, modified: modified)
        }
        let counts = LineEnding.count(in: detection.text)
        let ending = LineEnding.detect(in: detection.text, fallback: defaults.lineEnding)
        let normalized = LineEnding.normalize(detection.text)
        let firstLine = normalized.prefix(200).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        return LoadedFile(
            content: .text(normalized), encoding: detection.encoding, lineEnding: ending, mixedLineEndings: counts.isMixed,
            indent: IndentStyle.detect(in: normalized), language: Languages.detect(filename: name, firstLine: firstLine),
            byteCount: data.count, modified: modified
        )
    }
}

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    let status = CursorStatus()
    /// Fires after every edit; previews and outlines listen with a debounce.
    let edits = PassthroughSubject<Void, Never>()

    @Published var url: URL?
    @Published var name: String
    @Published var language: Language
    @Published var encoding: TextEncoding
    @Published var lineEnding: LineEnding
    @Published var indent: IndentStyle
    @Published var isDirty = false
    @Published var userReadOnly = false
    @Published private(set) var binary: Data?
    @Published private(set) var byteCount = 0
    @Published var notice: String?
    @Published var hasConflict = false
    @Published var saveError: String?
    @Published private(set) var isTooLargeToEdit = false
    @Published private(set) var highlightingEnabled = true

    /// Identifies the autosaved copy of a document that has no file yet.
    private(set) var draftID: String?
    private(set) var fileDate: Date?
    private var pendingText: String
    /// Editor contents parsed while the file was loading, so that showing it does not block the UI.
    var preparedState: PreparedEditorState?
    private var controllerStorage: EditorController?
    private var autosaveWork: DispatchWorkItem?
    private let settings = AppSettings.shared

    /// True for anything that is not text. `binary` holds the bytes once the hex view needs them.
    @Published private(set) var isBinary = false

    /// Reads the bytes for the hex view. Media files skip this until someone asks for hex.
    func loadBinaryData() {
        guard isBinary, binary == nil, let url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? FileAccess.read(url)) ?? Data()
            DispatchQueue.main.async { self.binary = data }
        }
    }
    var isReadOnly: Bool { userReadOnly || isTooLargeToEdit || isBinary }
    var isUntitled: Bool { url == nil }

    /// The editor view for this document, created the first time it is shown.
    var controller: EditorController {
        if let controllerStorage { return controllerStorage }
        let created = EditorController(document: self, text: pendingText, prepared: preparedState)
        pendingText = ""
        preparedState = nil
        controllerStorage = created
        return created
    }

    var text: String { controllerStorage?.text ?? pendingText }

    // MARK: - Creation

    init(untitled name: String, draftID: String = UUID().uuidString, text: String = "") {
        self.name = name
        self.draftID = draftID
        self.pendingText = text
        language = Languages.detect(filename: name)
        encoding = AppSettings.shared.defaultEncoding
        lineEnding = AppSettings.shared.defaultLineEnding
        indent = AppSettings.shared.defaultIndent
        byteCount = text.utf8.count
    }

    init(url: URL, loaded: LoadedFile) {
        self.url = url
        name = url.lastPathComponent
        pendingText = ""
        language = loaded.language
        encoding = loaded.encoding
        lineEnding = loaded.lineEnding
        indent = AppSettings.shared.defaultIndent
        apply(loaded, keepLanguage: false)
    }

    private func apply(_ loaded: LoadedFile, keepLanguage: Bool) {
        encoding = loaded.encoding
        lineEnding = loaded.lineEnding
        if !keepLanguage { language = loaded.language }
        byteCount = loaded.byteCount
        fileDate = loaded.modified
        if settings.detectIndentation, let detected = loaded.indent {
            indent = detected
        } else {
            indent = settings.defaultIndent
        }
        switch loaded.content {
        case .binary(let data):
            binary = data
            isBinary = true
            notice = nil
            pendingText = ""
        case .media:
            binary = nil
            isBinary = true
            notice = nil
            pendingText = ""
        case .text(let text):
            binary = nil
            isBinary = false
            let length = (text as NSString).length
            isTooLargeToEdit = length > LoadedFile.editLimit
            highlightingEnabled = length <= LoadedFile.highlightLimit
            if isTooLargeToEdit {
                notice = String(localized: "Large file: opened read-only without syntax colouring.")
            } else if !highlightingEnabled {
                notice = String(localized: "Large file: syntax colouring is off.")
            } else if loaded.mixedLineEndings {
                notice = String(localized: "Mixed line endings: saving will convert them all to \(loaded.lineEnding.name).")
            } else {
                notice = nil
            }
            if let controllerStorage {
                let caret = controllerStorage.selectedRange.location
                controllerStorage.setText(text)
                controllerStorage.select(NSRange(location: min(caret, controllerStorage.length), length: 0))
            } else {
                pendingText = text
            }
        }
        isDirty = false
        hasConflict = false
    }

    // MARK: - Editing

    func textDidChange() {
        if !isDirty { isDirty = true }
        edits.send()
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosave() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Writes pending edits: to the file when there is one and autosave is on, otherwise to a draft.
    func autosave() {
        autosaveWork?.cancel()
        guard isDirty, !isBinary else { return }
        if url != nil {
            guard settings.autosave, !hasConflict else { return }
            try? save()
        } else {
            saveDraft()
        }
    }

    private func saveDraft() {
        guard let draftID else { return }
        let file = FileAccess.draftsDirectory.appendingPathComponent(draftID)
        try? Data(text.utf8).write(to: file, options: .atomic)
    }

    func discardDraft() {
        guard let draftID else { return }
        try? FileManager.default.removeItem(at: FileAccess.draftsDirectory.appendingPathComponent(draftID))
    }

    /// The bytes that saving would write, after the save-time clean-ups.
    func encodedContents() throws -> Data {
        var output = text
        if settings.trimTrailingWhitespaceOnSave, let trimmed = try? TextTransform.trimTrailingWhitespace.apply(to: output) { output = trimmed }
        if settings.ensureFinalNewline, !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
        if output != text, let controllerStorage, !isReadOnly { controllerStorage.replaceAll(with: output) }
        guard let data = encoding.encode(lineEnding.apply(to: output)) else {
            throw FileAccess.Failure(message: String(localized: "Some characters cannot be saved as \(encoding.name). Choose another encoding, such as UTF-8."))
        }
        return data
    }

    func save() throws {
        guard let url, !isBinary else { return }
        do {
            let data = try encodedContents()
            try FileAccess.write(data, to: url)
            byteCount = data.count
            fileDate = FileAccess.modificationDate(url)
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            throw error
        }
    }

    /// Points an untitled document at the file it was just exported to.
    func adopt(url newURL: URL) {
        discardDraft()
        draftID = nil
        url = newURL
        name = newURL.lastPathComponent
        let detected = Languages.detect(filename: name)
        if language.id == Languages.plain.id || detected.id != Languages.plain.id { setLanguage(detected) }
        fileDate = FileAccess.modificationDate(newURL)
        isDirty = false
    }

    func setLanguage(_ newLanguage: Language) {
        guard newLanguage.id != language.id else { return }
        language = newLanguage
        controllerStorage?.languageDidChange()
    }

    func setIndent(_ style: IndentStyle) {
        indent = style
    }

    func markEdited() {
        textDidChange()
    }

    // MARK: - Disk state

    /// Re-reads the file, keeping the language. Used for "reopen with encoding" and for external changes.
    func reload(encoding forced: TextEncoding? = nil) throws {
        guard let url else { return }
        let loaded = try LoadedFile.load(url, encoding: forced, defaults: (settings.defaultEncoding, settings.defaultLineEnding))
        apply(loaded, keepLanguage: true)
    }

    /// Notices changes made by another app. Clean documents reload silently; edited ones ask.
    func checkForExternalChange() {
        guard let url, !hasConflict, let known = fileDate, let current = FileAccess.modificationDate(url) else { return }
        guard current.timeIntervalSince(known) > 0.5 else { return }
        if isDirty {
            hasConflict = true
        } else {
            try? reload()
        }
    }

    func resolveConflictKeepingMine() {
        hasConflict = false
        try? save()
    }

    func resolveConflictReloading() {
        hasConflict = false
        try? reload()
    }
}
