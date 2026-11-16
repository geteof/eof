import Runestone
import UIKit

/// Presents an `EditorTheme` and the chosen font to Runestone.
final class RunestoneTheme: Theme {
    let base: EditorTheme
    let font: UIFont
    let lineNumberFont: UIFont
    // Runestone may ask for colours while it prepares lines off the main thread.
    private let lock = NSLock()
    private var kinds: [String: HighlightKind?] = [:]

    init(base: EditorTheme, font: UIFont) {
        self.base = base
        self.font = font
        lineNumberFont = UIFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
    }

    var textColor: UIColor { base.foreground }
    var gutterBackgroundColor: UIColor { base.background }
    var gutterHairlineColor: UIColor { .clear }
    var gutterHairlineWidth: CGFloat { 0 }
    var lineNumberColor: UIColor { base.gutterForeground }
    var selectedLineBackgroundColor: UIColor { base.currentLine }
    var selectedLinesLineNumberColor: UIColor { base.foreground }
    var selectedLinesGutterBackgroundColor: UIColor { base.currentLine }
    var invisibleCharactersColor: UIColor { base.invisibles }
    var pageGuideHairlineColor: UIColor { base.gutterForeground.withAlphaComponent(0.3) }
    var pageGuideBackgroundColor: UIColor { base.currentLine }
    var markedTextBackgroundColor: UIColor { base.selection.withAlphaComponent(0.6) }
    var markedTextBackgroundCornerRadius: CGFloat { 3 }

    private func kind(_ highlightName: String) -> HighlightKind? {
        lock.lock()
        defer { lock.unlock() }
        if let known = kinds[highlightName] { return known }
        let resolved = HighlightKind.named(highlightName)
        kinds[highlightName] = resolved
        return resolved
    }

    func textColor(for highlightName: String) -> UIColor? {
        kind(highlightName).map(base.color(for:))
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        if highlightName.hasPrefix("text.title") || highlightName.hasPrefix("text.strong") { return .bold }
        if highlightName.hasPrefix("text.emphasis") { return .italic }
        return []
    }

    @available(iOS 16, *)
    func highlightedRange(forFoundTextRange foundTextRange: NSRange, ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
        switch style {
        case .found: return HighlightedRange(range: foundTextRange, color: base.findMatch, cornerRadius: 2)
        case .highlighted: return HighlightedRange(range: foundTextRange, color: base.findMatch.withAlphaComponent(0.85), cornerRadius: 2)
        default: return nil
        }
    }
}
