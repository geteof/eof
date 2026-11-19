import EOFCore
import Runestone
import SwiftUI
import UIKit

protocol EditorKeyCommands: AnyObject {
    func indentSelection()
    func outdentSelection()
    func toggleComment()
}

/// Runestone's text view plus the hardware-keyboard shortcuts the editor adds.
final class EditorTextView: TextView {
    weak var commands: EditorKeyCommands?

    override var keyCommands: [UIKeyCommand]? {
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdentCommand))
        outdent.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [
            outdent,
            UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(indentCommand)),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(outdentCommand)),
            UIKeyCommand(input: "/", modifierFlags: .command, action: #selector(commentCommand)),
        ]
    }

    @objc private func indentCommand() { commands?.indentSelection() }
    @objc private func outdentCommand() { commands?.outdentSelection() }
    @objc private func commentCommand() { commands?.toggleComment() }
}

/// Parsed editor contents, prepared ahead of the view. Wrapped so that model code can hold one
/// without importing Runestone.
struct PreparedEditorState {
    fileprivate let state: TextViewState

    /// Safe to call off the main thread.
    static func prepare(text: String, language: Language, filename: String, highlighting: Bool, theme: RunestoneTheme) -> PreparedEditorState {
        PreparedEditorState(state: EditorController.makeState(text: text, language: language, filename: filename, highlighting: highlighting, theme: theme))
    }
}

private struct BracketPair: CharacterPair {
    let leading: String
    let trailing: String
}

/// Owns the text view of one document. The document keeps the controller alive, so the caret,
/// scroll position and undo history survive tab switches and layout changes (fold, rotate, split).
///
/// Editing, line numbers, indentation and syntax colouring are Runestone's; this class connects
/// them to the document, the settings and the app's own commands.
final class EditorController: NSObject, TextViewDelegate, UIScrollViewDelegate, EditorKeyCommands {
    let textView = EditorTextView(frame: .zero)
    var view: UIView { textView }

    private weak var document: EditorDocument?
    private let settings = AppSettings.shared
    /// Called when the text view starts editing, so a split window knows which pane has focus.
    var onFocus: (() -> Void)?
    /// Called on every scroll with the offset, the top of the content and whether the user is
    /// dragging or flinging (rather than the view scrolling to follow the caret).
    var onScroll: ((_ offset: CGFloat, _ top: CGFloat, _ userDriven: Bool) -> Void)?
    private var theme: RunestoneTheme
    private var appliedStamp: Int?
    private var isReplacingProgrammatically = false
    private var isLoadingState = false

    // Decorations drawn over the text.
    private var findHighlights: [HighlightedRange] = []
    private var bracketHighlights: [HighlightedRange] = []
    private var hasFindMatches = false
    private lazy var accessory = KeyboardAccessory(controller: self)

    /// The appearance the editors were last drawn in; used to prepare state before a view exists.
    private(set) static var isDark = false
    private static let maximumFindHighlights = 3000
    private static let pairs: [CharacterPair] = [
        BracketPair(leading: "(", trailing: ")"), BracketPair(leading: "[", trailing: "]"), BracketPair(leading: "{", trailing: "}"),
        BracketPair(leading: "\"", trailing: "\""), BracketPair(leading: "'", trailing: "'"), BracketPair(leading: "`", trailing: "`"),
    ]

    // MARK: - State

    static func currentTheme() -> RunestoneTheme {
        let settings = AppSettings.shared
        return RunestoneTheme(base: settings.theme(dark: isDark), font: settings.font())
    }

    /// Parses `text` into the structure Runestone displays. This is the expensive part of opening a
    /// file and is safe to run off the main thread.
    static func makeState(text: String, language: Language, filename: String, highlighting: Bool, theme: RunestoneTheme) -> TextViewState {
        if highlighting, let grammar = Grammars.grammar(for: language, filename: filename) {
            return TextViewState(text: text, theme: theme, language: grammar, languageProvider: GrammarProvider.shared)
        }
        return TextViewState(text: text, theme: theme)
    }

    init(document: EditorDocument, text: String, prepared: PreparedEditorState?) {
        let state = prepared?.state
        self.document = document
        theme = EditorController.currentTheme()
        super.init()
        textView.editorDelegate = self
        // Runestone leaves the scroll view's own delegate unused.
        textView.delegate = self
        textView.commands = self
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 8)
        textView.gutterLeadingPadding = 10
        textView.gutterTrailingPadding = 6
        textView.verticalOverscrollFactor = 0.4
        textView.lineEndings = .lf
        textView.showMenuAfterNavigatingToHighlightedRange = false
        textView.isFindInteractionEnabled = false
        textView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        load(state ?? EditorController.makeState(
            text: text, language: document.language, filename: document.name,
            highlighting: document.highlightingEnabled, theme: theme
        ))
        // Start with the caret on the first line; without a selection Runestone reports the end of the text.
        textView.selectedRange = NSRange(location: 0, length: 0)
        selectionDidChange()
    }

    private func load(_ state: TextViewState) {
        isLoadingState = true
        textView.setState(state)
        isLoadingState = false
        findHighlights = []
        bracketHighlights = []
        hasFindMatches = false
        textView.highlightedRanges = []
        applyAppearance(dark: EditorController.isDark, force: true)
        selectionDidChange()
    }

    // MARK: - Text access

    /// The whole buffer. This copies the text, so callers hold on to the result instead of asking twice.
    var text: String { textView.text }

    var length: Int { textView.offset(from: textView.beginningOfDocument, to: textView.endOfDocument) }
    var selectedRange: NSRange { textView.selectedRange }
    var selectedText: String { textView.text(in: textView.selectedRange) ?? "" }

    var lineCount: Int { (textView.textLocation(at: length)?.lineNumber ?? 0) + 1 }

    /// Replaces the whole buffer without registering undo: used when reloading a file from disk.
    func setText(_ newText: String) {
        guard let document else { return }
        load(EditorController.makeState(
            text: newText, language: document.language, filename: document.name,
            highlighting: document.highlightingEnabled, theme: theme
        ))
    }

    /// Replaces `range` as one undoable step and places the selection.
    func replace(_ range: NSRange, with string: String, selecting selection: NSRange? = nil) {
        guard textView.isEditable, NSMaxRange(range) <= length else { return }
        isReplacingProgrammatically = true
        textView.replace(range, withText: string)
        isReplacingProgrammatically = false
        let inserted = NSRange(location: range.location, length: (string as NSString).length)
        let target = selection ?? NSRange(location: NSMaxRange(inserted), length: 0)
        if NSMaxRange(target) <= length { textView.selectedRange = target }
        textDidChange()
    }

    func replaceAll(with string: String) {
        let caret = min(textView.selectedRange.location, (string as NSString).length)
        replace(NSRange(location: 0, length: length), with: string, selecting: NSRange(location: caret, length: 0))
    }

    /// Types `string` at the caret, as the keyboard would: Tab follows the indent setting and
    /// brackets get their partner.
    func insert(_ string: String) {
        guard textView.isEditable else { return }
        textView.insertText(string)
    }

    func moveCaret(by delta: Int) {
        let range = textView.selectedRange
        let total = length
        var location = max(0, min(delta < 0 ? range.location + delta : NSMaxRange(range) + delta, total))
        // Never land inside a surrogate pair or a combined character.
        let windowStart = max(0, location - 8)
        let window = NSRange(location: windowStart, length: min(total, location + 8) - windowStart)
        if location > 0, location < total, let nearby = textView.text(in: window) as NSString? {
            let sequence = nearby.rangeOfComposedCharacterSequence(at: location - windowStart)
            if sequence.location + windowStart != location {
                location = delta < 0 ? sequence.location + windowStart : NSMaxRange(sequence) + windowStart
            }
        }
        textView.selectedRange = NSRange(location: location, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
        selectionDidChange()
    }

    func select(_ range: NSRange, focus: Bool = false) {
        guard NSMaxRange(range) <= length else { return }
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
        if focus { textView.becomeFirstResponder() }
        selectionDidChange()
    }

    func scroll(to range: NSRange) {
        guard NSMaxRange(range) <= length else { return }
        textView.scrollRangeToVisible(range)
    }

    /// Moves the caret to a 1-based line and column.
    func goToLine(_ line: Int, column: Int = 1) {
        let index = max(0, min(line, lineCount) - 1)
        textView.goToLine(index)
        defer { selectionDidChange() }
        guard column > 1, let start = textView.location(at: TextLocation(lineNumber: index, column: 0)) else { return }
        let nextLine = textView.location(at: TextLocation(lineNumber: index + 1, column: 0))
        let end = nextLine.map { $0 - 1 } ?? length
        textView.selectedRange = NSRange(location: min(start + column - 1, max(start, end)), length: 0)
    }

    func focus() { textView.becomeFirstResponder() }
    func resignFocus() { textView.resignFirstResponder() }

    func undo() { textView.undoManager?.undo() }
    func redo() { textView.undoManager?.redo() }
    var canUndo: Bool { textView.undoManager?.canUndo ?? false }
    var canRedo: Bool { textView.undoManager?.canRedo ?? false }

    func selectAll() {
        textView.selectedRange = NSRange(location: 0, length: length)
        selectionDidChange()
    }

    // MARK: - Appearance

    func applyAppearance(dark: Bool, force: Bool = false) {
        EditorController.isDark = dark
        let indent = document?.indent ?? settings.defaultIndent
        var hasher = Hasher()
        hasher.combine(settings.editorStamp)
        hasher.combine(dark)
        hasher.combine(indent.usesTabs)
        hasher.combine(indent.width)
        hasher.combine(textView.isEditable)
        let stamp = hasher.finalize()
        guard force || stamp != appliedStamp else { return }
        appliedStamp = stamp

        let base = settings.theme(dark: dark)
        let font = settings.font()
        if force || theme.base != base || theme.font != font {
            theme = RunestoneTheme(base: base, font: font)
            textView.theme = theme
        }
        let tint = base.isDark ? UIColor(red: 0.5, green: 0.72, blue: 1, alpha: 1) : UIColor.tintColor
        textView.backgroundColor = base.background
        textView.insertionPointColor = tint
        textView.selectionBarColor = tint
        textView.selectionHighlightColor = base.selection
        textView.overrideUserInterfaceStyle = base.isDark ? .dark : .light
        textView.keyboardAppearance = base.isDark ? .dark : .light
        textView.showLineNumbers = settings.showLineNumbers
        textView.lineSelectionDisplayType = settings.highlightCurrentLine ? .line : .disabled
        textView.showTabs = settings.showInvisibles
        textView.showSpaces = settings.showInvisibles
        textView.showLineBreaks = settings.showInvisibles
        textView.isLineWrappingEnabled = settings.wrapLines
        textView.lineHeightMultiplier = CGFloat(settings.lineHeight)
        textView.indentStrategy = indent.usesTabs ? .tab(length: indent.width) : .space(length: indent.width)
        textView.characterPairs = settings.autoClosePairs ? EditorController.pairs : []
        textView.inputAccessoryView = settings.showAccessoryBar && textView.isEditable ? accessory.view : nil
        accessory.update(dark: base.isDark)
        if hasFindMatches || !bracketHighlights.isEmpty {
            // Highlight colours come from the theme; rebuild them when it changes.
            bracketHighlights = bracketHighlights.map { HighlightedRange(id: $0.id, range: $0.range, color: base.bracketMatch, cornerRadius: 2) }
            textView.highlightedRanges = findHighlights + bracketHighlights
        }
    }

    func setEditable(_ editable: Bool) {
        guard textView.isEditable != editable else { return }
        textView.isEditable = editable
        textView.inputAccessoryView = settings.showAccessoryBar && editable ? accessory.view : nil
        textView.reloadInputViews()
    }

    func languageDidChange() {
        guard let document else { return }
        if document.highlightingEnabled, let grammar = Grammars.grammar(for: document.language, filename: document.name) {
            textView.setLanguageMode(TreeSitterLanguageMode(language: grammar, languageProvider: GrammarProvider.shared))
        } else {
            textView.setLanguageMode(PlainTextLanguageMode())
        }
    }

    /// Called by the host when its bounds change.
    func layout(in bounds: CGRect) {
        textView.frame = bounds
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        // Step in whole points so the layout is not rebuilt for every tiny movement.
        if gesture.scale > 1.12 {
            settings.adjustFontSize(by: 1)
            gesture.scale = 1
        } else if gesture.scale < 0.89 {
            settings.adjustFontSize(by: -1)
            gesture.scale = 1
        }
    }

    // MARK: - Find

    func setFindMatches(_ ranges: [NSRange], current: NSRange?) {
        hasFindMatches = !ranges.isEmpty
        let color = theme.base.findMatch
        var highlights: [HighlightedRange] = []
        highlights.reserveCapacity(min(ranges.count, EditorController.maximumFindHighlights) + 1)
        // Very common matches are capped; show the ones around the current match.
        var window = ranges[...]
        if ranges.count > EditorController.maximumFindHighlights {
            let center = current.flatMap { target in ranges.firstIndex { NSEqualRanges($0, target) } } ?? 0
            let start = max(0, min(center - EditorController.maximumFindHighlights / 2, ranges.count - EditorController.maximumFindHighlights))
            window = ranges[start..<(start + EditorController.maximumFindHighlights)]
        }
        for range in window {
            let isCurrent = current.map { NSEqualRanges($0, range) } ?? false
            highlights.append(HighlightedRange(id: "find-\(range.location)", range: range, color: isCurrent ? color.withAlphaComponent(0.85) : color, cornerRadius: 2))
        }
        findHighlights = highlights
        textView.highlightedRanges = findHighlights + bracketHighlights
    }

    // MARK: - TextViewDelegate

    func textViewDidChange(_ textView: TextView) {
        textDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?(scrollView.contentOffset.y, -scrollView.adjustedContentInset.top, scrollView.isTracking || scrollView.isDecelerating)
    }

    func textViewDidBeginEditing(_ textView: TextView) {
        onFocus?()
    }

    func textViewDidChangeSelection(_ textView: TextView) {
        selectionDidChange()
    }

    func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isReplacingProgrammatically else { return true }
        // Runestone indents a new line to match its surroundings. With the setting off, insert a bare
        // line break instead. An input method that is still composing is left alone.
        if !settings.autoIndent, text == "\n", textView.markedTextRange == nil {
            replace(range, with: "\n")
            return false
        }
        return true
    }

    private func textDidChange() {
        guard !isLoadingState else { return }
        // Match positions moved; the find bar recomputes them after a short pause.
        if hasFindMatches {
            hasFindMatches = false
            findHighlights = []
            textView.highlightedRanges = bracketHighlights
        }
        selectionDidChange()
        document?.textDidChange()
    }

    private func selectionDidChange() {
        guard !isLoadingState, let document else { return }
        let range = textView.selectedRange
        let total = length
        updateBracketMatch(caret: range, total: total)
        let location = textView.textLocation(at: min(range.location, total))
        let lines = (textView.textLocation(at: total)?.lineNumber ?? 0) + 1
        document.status.update(
            line: (location?.lineNumber ?? 0) + 1, column: (location?.column ?? 0) + 1,
            selection: range.length, lines: lines, length: total
        )
    }

    /// Marks the bracket next to the caret and its partner. Only a window around the caret is read,
    /// so the cost does not depend on the size of the file.
    private func updateBracketMatch(caret: NSRange, total: Int) {
        var ranges: [NSRange] = []
        if caret.length == 0, total > 0 {
            let reach = 6000
            let start = max(0, caret.location - reach)
            let window = NSRange(location: start, length: min(total, caret.location + reach) - start)
            if let nearby = textView.text(in: window) as NSString? {
                for candidate in [caret.location - 1, caret.location] where candidate >= start && candidate < NSMaxRange(window) {
                    if let match = TextNavigation.matchingBracket(in: nearby, at: candidate - start, limit: reach * 2) {
                        ranges = [NSRange(location: candidate, length: 1), NSRange(location: match + start, length: 1)]
                        break
                    }
                }
            }
        }
        guard ranges != bracketHighlights.map(\.range) else { return }
        let color = theme.base.bracketMatch
        bracketHighlights = ranges.map { HighlightedRange(id: "bracket-\($0.location)", range: $0, color: color, cornerRadius: 2) }
        textView.highlightedRanges = findHighlights + bracketHighlights
    }

    // MARK: - Line commands

    /// The full lines covered by the selection, without the final line break.
    private func selectedLinesRange() -> NSRange {
        let selection = textView.selectedRange
        let total = length
        guard let first = textView.textLocation(at: selection.location),
              let start = textView.location(at: TextLocation(lineNumber: first.lineNumber, column: 0)) else { return selection }
        var lastLine = textView.textLocation(at: NSMaxRange(selection))?.lineNumber ?? first.lineNumber
        // A selection that ends at the start of a line does not include that line.
        if selection.length > 0, lastLine > first.lineNumber, textView.textLocation(at: NSMaxRange(selection))?.column == 0 { lastLine -= 1 }
        let nextLine = textView.location(at: TextLocation(lineNumber: lastLine + 1, column: 0))
        let end = nextLine.map { $0 - 1 } ?? total
        return NSRange(location: start, length: max(0, end - start))
    }

    private func transformSelectedLines(_ body: (String) -> String) {
        let range = selectedLinesRange()
        guard let original = textView.text(in: range) else { return }
        let result = body(original)
        guard result != original else { return }
        replace(range, with: result, selecting: NSRange(location: range.location, length: (result as NSString).length))
    }

    func indentSelection() {
        guard textView.isEditable else { return }
        textView.shiftRight()
    }

    func outdentSelection() {
        guard textView.isEditable else { return }
        textView.shiftLeft()
    }

    func moveLinesUp() {
        guard textView.isEditable else { return }
        textView.moveSelectedLinesUp()
    }

    func moveLinesDown() {
        guard textView.isEditable else { return }
        textView.moveSelectedLinesDown()
    }

    func toggleComment() {
        guard let language = document?.language else { return }
        if let prefix = language.commentPrefix {
            transformSelectedLines { LineEdit.toggleComment($0, prefix: prefix.trimmingCharacters(in: .whitespaces)) }
        } else if let block = language.blockComment, block.count == 2 {
            transformSelectedLines { original in
                let trimmed = original.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(block[0]), trimmed.hasSuffix(block[1]), trimmed.count >= block[0].count + block[1].count {
                    return String(trimmed.dropFirst(block[0].count).dropLast(block[1].count)).trimmingCharacters(in: .whitespaces)
                }
                return block[0] + " " + original + " " + block[1]
            }
        }
    }

    /// Applies a transform to the selection, or to the whole document when nothing is selected.
    func apply(_ transform: TextTransform) throws {
        let selection = textView.selectedRange
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: length)
        guard let original = textView.text(in: range) else { return }
        let width = (document?.indent ?? settings.defaultIndent).width
        let result = try transform.apply(to: original, indentWidth: width)
        guard result != original else { return }
        let resultLength = (result as NSString).length
        replace(range, with: result, selecting: selection.length > 0 ? NSRange(location: range.location, length: resultLength) : NSRange(location: min(selection.location, resultLength), length: 0))
    }

    func duplicateLine() {
        let lines = selectedLinesRange()
        guard let content = textView.text(in: lines) else { return }
        let caret = textView.selectedRange
        let addition = "\n" + content
        replace(NSRange(location: NSMaxRange(lines), length: 0), with: addition, selecting: NSRange(location: caret.location + (addition as NSString).length, length: caret.length))
    }

    func deleteLine() {
        var lines = selectedLinesRange()
        let total = length
        // Take the line break with it: the one after, or the one before for the last line.
        if NSMaxRange(lines) < total {
            lines.length += 1
        } else if lines.location > 0 {
            lines.location -= 1
            lines.length += 1
        }
        replace(lines, with: "", selecting: NSRange(location: min(lines.location, total - lines.length), length: 0))
    }
}

/// Embeds a document's long-lived editor view in SwiftUI.
struct EditorHost: UIViewRepresentable {
    let document: EditorDocument
    let isDark: Bool
    /// Changes whenever a setting that affects the editor changes.
    let settingsStamp: Int

    final class Container: UIView {
        weak var controller: EditorController?

        override func layoutSubviews() {
            super.layoutSubviews()
            // A container the view has moved out of (pane swap, another window) must not resize it.
            guard let controller, controller.view.superview === self else { return }
            controller.layout(in: bounds)
        }
    }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        if container.controller !== document.controller { attach(to: container) }
        document.controller.setEditable(!document.isReadOnly)
        document.controller.applyAppearance(dark: isDark)
        container.setNeedsLayout()
    }

    private func attach(to container: Container) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let controller = document.controller
        controller.view.removeFromSuperview()
        container.controller = controller
        container.addSubview(controller.view)
        container.setNeedsLayout()
    }
}
