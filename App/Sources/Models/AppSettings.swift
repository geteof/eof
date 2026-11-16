import Combine
import SwiftUI
import EOFCore
import UIKit

/// User preferences, stored in `UserDefaults`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let fonts: [(id: String, name: String)] = [
        ("system", "SF Mono"),
        ("Menlo-Regular", "Menlo"),
        ("Courier", "Courier"),
        ("CourierNewPSMT", "Courier New"),
    ]

    private let defaults = UserDefaults.standard

    @Published var lightThemeID: String { didSet { defaults.set(lightThemeID, forKey: "lightTheme") } }
    @Published var darkThemeID: String { didSet { defaults.set(darkThemeID, forKey: "darkTheme") } }
    @Published var fontID: String { didSet { defaults.set(fontID, forKey: "font") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: "lineHeight") } }
    @Published var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: "lineNumbers") } }
    @Published var wrapLines: Bool { didSet { defaults.set(wrapLines, forKey: "wrap") } }
    @Published var showInvisibles: Bool { didSet { defaults.set(showInvisibles, forKey: "invisibles") } }
    @Published var highlightCurrentLine: Bool { didSet { defaults.set(highlightCurrentLine, forKey: "currentLine") } }
    @Published var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: "tabWidth") } }
    @Published var insertSpaces: Bool { didSet { defaults.set(insertSpaces, forKey: "insertSpaces") } }
    @Published var detectIndentation: Bool { didSet { defaults.set(detectIndentation, forKey: "detectIndent") } }
    @Published var autoIndent: Bool { didSet { defaults.set(autoIndent, forKey: "autoIndent") } }
    @Published var autoClosePairs: Bool { didSet { defaults.set(autoClosePairs, forKey: "autoPairs") } }
    @Published var showAccessoryBar: Bool { didSet { defaults.set(showAccessoryBar, forKey: "accessoryBar") } }
    @Published var autosave: Bool { didSet { defaults.set(autosave, forKey: "autosave") } }
    @Published var trimTrailingWhitespaceOnSave: Bool { didSet { defaults.set(trimTrailingWhitespaceOnSave, forKey: "trimOnSave") } }
    @Published var ensureFinalNewline: Bool { didSet { defaults.set(ensureFinalNewline, forKey: "finalNewline") } }
    @Published var defaultEncodingID: String { didSet { defaults.set(defaultEncodingID, forKey: "defaultEncoding") } }
    @Published var defaultLineEnding: LineEnding { didSet { defaults.set(defaultLineEnding.rawValue, forKey: "defaultLineEnding") } }
    @Published var previewAllowsJavaScript: Bool { didSet { defaults.set(previewAllowsJavaScript, forKey: "previewJS") } }
    @Published var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: "hiddenFiles") } }

    static let fontSizeRange: ClosedRange<Double> = 8...40

    private init() {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
        }
        let d = UserDefaults.standard
        lightThemeID = d.string(forKey: "lightTheme") ?? EditorTheme.paper.id
        darkThemeID = d.string(forKey: "darkTheme") ?? EditorTheme.midnight.id
        fontID = d.string(forKey: "font") ?? "system"
        let size = d.double(forKey: "fontSize")
        fontSize = size == 0 ? 14 : min(max(size, AppSettings.fontSizeRange.lowerBound), AppSettings.fontSizeRange.upperBound)
        let height = d.double(forKey: "lineHeight")
        lineHeight = height == 0 ? 1.3 : height
        showLineNumbers = bool("lineNumbers", true)
        wrapLines = bool("wrap", true)
        showInvisibles = bool("invisibles", false)
        highlightCurrentLine = bool("currentLine", true)
        let width = d.integer(forKey: "tabWidth")
        tabWidth = width == 0 ? 4 : width
        insertSpaces = bool("insertSpaces", true)
        detectIndentation = bool("detectIndent", true)
        autoIndent = bool("autoIndent", true)
        autoClosePairs = bool("autoPairs", true)
        showAccessoryBar = bool("accessoryBar", true)
        autosave = bool("autosave", true)
        trimTrailingWhitespaceOnSave = bool("trimOnSave", false)
        ensureFinalNewline = bool("finalNewline", false)
        defaultEncodingID = d.string(forKey: "defaultEncoding") ?? TextEncoding.utf8.id
        defaultLineEnding = LineEnding(rawValue: d.string(forKey: "defaultLineEnding") ?? "") ?? .lf
        previewAllowsJavaScript = bool("previewJS", false)
        showHiddenFiles = bool("hiddenFiles", true)
    }

    /// Changes whenever a preference that the editor view draws from changes.
    var editorStamp: Int {
        var hasher = Hasher()
        hasher.combine(lightThemeID)
        hasher.combine(darkThemeID)
        hasher.combine(fontID)
        hasher.combine(fontSize)
        hasher.combine(lineHeight)
        hasher.combine(showLineNumbers)
        hasher.combine(wrapLines)
        hasher.combine(showInvisibles)
        hasher.combine(highlightCurrentLine)
        hasher.combine(tabWidth)
        hasher.combine(showAccessoryBar)
        return hasher.finalize()
    }

    var defaultEncoding: TextEncoding { TextEncoding.named(defaultEncodingID) ?? .utf8 }

    func theme(dark: Bool) -> EditorTheme {
        dark ? EditorTheme.named(darkThemeID, fallback: .midnight) : EditorTheme.named(lightThemeID, fallback: .paper)
    }

    func font(size: Double? = nil) -> UIFont {
        let pointSize = CGFloat(size ?? fontSize)
        if fontID != "system", let custom = UIFont(name: fontID, size: pointSize) { return custom }
        return UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    var defaultIndent: IndentStyle { IndentStyle(usesTabs: !insertSpaces, width: tabWidth) }

    func adjustFontSize(by delta: Double) {
        fontSize = min(max((fontSize + delta).rounded(), AppSettings.fontSizeRange.lowerBound), AppSettings.fontSizeRange.upperBound)
    }
}
