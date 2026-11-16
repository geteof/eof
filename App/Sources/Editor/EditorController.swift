import SwiftUI
import TesseraCore
import UIKit

/// Owns the text view of one document. The document keeps the controller alive, so the caret,
/// scroll position and undo history survive tab switches and layout changes (fold, rotate, split).
final class EditorController: NSObject, UITextViewDelegate, CodeTextViewCommands {
    let view = UIView()
    let textView = CodeTextView()
    private let gutter = GutterView()
    private weak var document: EditorDocument?
    private let settings = AppSettings.shared

    private var theme = EditorTheme.paper
    private var isDark = false
    private var font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var characterWidth: CGFloat = 8
    private(set) var lineBottomPadding: CGFloat = 0

    // Line index: UTF-16 offset of the first character of every line.
    private var lineStarts: [Int] = [0]
    private var longestLineLength = 0

    // Highlighting
    private var tokens: [Token] = []
    private var styledRange: NSRange?
    private var generation = 0
    private var pendingTokenize: DispatchWorkItem?
    private let tokenizeQueue = DispatchQueue(label: "app.tessera.tokenize", qos: .userInitiated)

    // Find and bracket decorations
    private var findRanges: [NSRange] = []
    private var currentFindRange: NSRange?
    private var bracketRanges: [NSRange] = []

    private var isApplyingText = false
    private var gutterWidth: CGFloat = 0
    private var lastLayoutWidth: CGFloat = 0
    private lazy var accessory = KeyboardAccessory(controller: self)

    init(document: EditorDocument, text: String) {
        self.document = document
        super.init()
        view.addSubview(textView)
        view.addSubview(gutter)
        gutter.controller = self
        textView.delegate = self
        textView.commands = self
        textView.onLayout = { [weak self] in self?.textViewDidLayout() }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        textView.addGestureRecognizer(pinch)
        view.clipsToBounds = true
        applyAppearance(dark: isDark, force: true)
        setText(text)
    }

    // MARK: - Text access

    var text: String { textView.textStorage.string }
    var length: Int { textView.textStorage.length }
    var lineCount: Int { lineStarts.count }
    var selectedRange: NSRange { textView.selectedRange }

    var selectedText: String {
        (text as NSString).substring(with: textView.selectedRange)
    }

    /// Replaces the whole buffer without registering undo: used when loading or reloading a file.
    func setText(_ newText: String) {
        isApplyingText = true
        textView.undoManager?.removeAllActions()
        textView.textStorage.setAttributedString(NSAttributedString(string: newText, attributes: baseAttributes))
        textView.typingAttributes = baseAttributes
        isApplyingText = false
        tokens = []
        styledRange = nil
        findRanges = []
        currentFindRange = nil
        bracketRanges = []
        rebuildLineIndex()
        updateWrapping()
        scheduleTokenize(delay: 0)
        selectionDidChange()
    }

    /// Replaces `range` as one undoable step and places the selection.
    func replace(_ range: NSRange, with string: String, selecting selection: NSRange? = nil) {
        guard textView.isEditable,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return }
        textView.replace(textRange, withText: string)
        let inserted = NSRange(location: range.location, length: (string as NSString).length)
        if NSMaxRange(inserted) <= length, inserted.length > 0 {
            textView.textStorage.addAttributes(baseAttributes, range: inserted)
        }
        let target = selection ?? NSRange(location: NSMaxRange(inserted), length: 0)
        if NSMaxRange(target) <= length { textView.selectedRange = target }
        textDidChange()
    }

    func replaceAll(with string: String) {
        let caret = min(textView.selectedRange.location, (string as NSString).length)
        replace(NSRange(location: 0, length: length), with: string, selecting: NSRange(location: caret, length: 0))
    }

    func insert(_ string: String) {
        guard textView.isEditable else { return }
        if textView.markedTextRange != nil {
            textView.insertText(string)
            return
        }
        let range = textView.selectedRange
        if textView(textView, shouldChangeTextIn: range, replacementText: string) {
            replace(range, with: string)
        }
    }

    func moveCaret(by delta: Int) {
        let range = textView.selectedRange
        var location = delta < 0 ? range.location + delta : NSMaxRange(range) + delta
        location = max(0, min(location, length))
        // Never land inside a surrogate pair or a combined character.
        let safe = (text as NSString).rangeOfComposedCharacterSequence(at: min(location, max(0, length - 1)))
        if location < length, safe.location != location { location = delta < 0 ? safe.location : NSMaxRange(safe) }
        textView.selectedRange = NSRange(location: location, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    func select(_ range: NSRange, focus: Bool = false) {
        guard NSMaxRange(range) <= length else { return }
        textView.selectedRange = range
        scroll(to: range)
        if focus { textView.becomeFirstResponder() }
        selectionDidChange()
    }

    /// Scrolls so that `range` sits about a third of the way down, instead of at the very edge.
    func scroll(to range: NSRange) {
        let layout = textView.layoutManager
        layout.ensureLayout(forCharacterRange: NSRange(location: range.location, length: min(range.length, 2000)))
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        if glyphs.length == 0, range.location >= length { rect = layout.extraLineFragmentRect }
        rect.origin.y += textView.textContainerInset.top
        let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        let visible = CGRect(x: 0, y: textView.contentOffset.y + textView.adjustedContentInset.top, width: 1, height: visibleHeight)
        if rect.minY < visible.minY + 20 || rect.maxY > visible.maxY - 40 {
            let maxOffset = max(-textView.adjustedContentInset.top, textView.contentSize.height - visibleHeight)
            let target = min(max(rect.minY - visibleHeight / 3, -textView.adjustedContentInset.top), maxOffset)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: target), animated: false)
        }
        if !settings.wrapLines {
            textView.scrollRangeToVisible(range)
        }
    }

    func goToLine(_ line: Int, column: Int = 1) {
        let index = max(0, min(line, lineStarts.count) - 1)
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : length
        let location = min(start + max(0, column - 1), end)
        select(NSRange(location: location, length: 0), focus: true)
    }

    func focus() { textView.becomeFirstResponder() }
    func resignFocus() { textView.resignFirstResponder() }

    func undo() { textView.undoManager?.undo(); textDidChange() }
    func redo() { textView.undoManager?.redo(); textDidChange() }
    var canUndo: Bool { textView.undoManager?.canUndo ?? false }
    var canRedo: Bool { textView.undoManager?.canRedo ?? false }

    // MARK: - Appearance

    func applyAppearance(dark: Bool, force: Bool = false) {
        let newTheme = settings.theme(dark: dark)
        let newFont = settings.font()
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = (newFont.lineHeight * CGFloat(settings.lineHeight)).rounded()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let width = ("0" as NSString).size(withAttributes: [.font: newFont]).width
        let tabWidth = CGFloat(document?.indent.width ?? settings.tabWidth)
        paragraph.tabStops = []
        paragraph.defaultTabInterval = max(width * tabWidth, 1)
        paragraph.lineBreakMode = settings.wrapLines ? .byWordWrapping : .byClipping

        let changedLayout = force || newFont != font || paragraph.defaultTabInterval != (baseAttributes[.paragraphStyle] as? NSParagraphStyle)?.defaultTabInterval
            || lineHeight != (baseAttributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight
            || paragraph.lineBreakMode != (baseAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineBreakMode
        let changedTheme = force || newTheme != theme

        theme = newTheme
        isDark = dark
        font = newFont
        characterWidth = width
        lineBottomPadding = 0
        baseAttributes = [.font: newFont, .foregroundColor: newTheme.foreground, .paragraphStyle: paragraph]

        view.backgroundColor = newTheme.background
        textView.backgroundColor = newTheme.background
        textView.tintColor = newTheme.isDark ? UIColor(red: 0.5, green: 0.72, blue: 1, alpha: 1) : UIColor.tintColor
        textView.overrideUserInterfaceStyle = newTheme.isDark ? .dark : .light
        textView.keyboardAppearance = newTheme.isDark ? .dark : .light
        textView.currentLineView.backgroundColor = newTheme.currentLine
        textView.currentLineView.isHidden = !settings.highlightCurrentLine
        gutter.backgroundColor = newTheme.background
        gutter.textColor = newTheme.gutterForeground
        gutter.currentLineColor = newTheme.foreground
        gutter.font = UIFont.monospacedDigitSystemFont(ofSize: max(9, newFont.pointSize - 2), weight: .regular)
        textView.codeLayoutManager.showsInvisibles = settings.showInvisibles
        textView.codeLayoutManager.invisiblesColor = newTheme.invisibles
        textView.codeLayoutManager.invisiblesFont = newFont

        if changedLayout || changedTheme {
            let storage = textView.textStorage
            if storage.length > 0 {
                isApplyingText = true
                storage.beginEditing()
                storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
                storage.endEditing()
                isApplyingText = false
            }
            textView.typingAttributes = baseAttributes
            styledRange = nil
        }
        textView.inputAccessoryView = settings.showAccessoryBar && textView.isEditable ? accessory.view : nil
        accessory.update(dark: newTheme.isDark)
        updateGutterWidth()
        updateWrapping()
        restyle(force: true)
        updateCurrentLine()
        textView.setNeedsDisplay()
        gutter.setNeedsDisplay()
        view.setNeedsLayout()
    }

    func setEditable(_ editable: Bool) {
        guard textView.isEditable != editable else { return }
        textView.isEditable = editable
        textView.inputAccessoryView = settings.showAccessoryBar && editable ? accessory.view : nil
        textView.reloadInputViews()
    }

    func languageDidChange() {
        tokens = []
        scheduleTokenize(delay: 0)
    }

    /// Called by the host when its bounds change.
    func layout(in bounds: CGRect) {
        view.frame = bounds
        let width = settings.showLineNumbers ? gutterWidth : 0
        gutter.isHidden = !settings.showLineNumbers
        gutter.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        textView.frame = CGRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        if abs(lastLayoutWidth - bounds.width) > 0.5 {
            lastLayoutWidth = bounds.width
            updateWrapping()
        }
        gutter.setNeedsDisplay()
    }

    private func updateGutterWidth() {
        let digits = max(2, String(lineStarts.count).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: gutter.font]).width
        let width = (CGFloat(digits) * digitWidth + 18).rounded()
        if abs(width - gutterWidth) > 0.5 {
            gutterWidth = width
            if view.bounds.width > 0 { layout(in: view.bounds) }
        }
    }

    private func updateWrapping() {
        let container = textView.textContainer
        if settings.wrapLines {
            if !container.widthTracksTextView {
                container.widthTracksTextView = true
                container.size = CGSize(width: textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right, height: .greatestFiniteMagnitude)
            }
            textView.showsHorizontalScrollIndicator = false
            textView.alwaysBounceHorizontal = false
            return
        }
        container.widthTracksTextView = false
        // Wide enough for the longest line. Full-width characters take two cells, so leave room for them.
        let cells = CGFloat(longestLineLength) * 2 + 4
        let needed = min(cells * characterWidth + container.lineFragmentPadding * 2, 400_000)
        let available = textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right
        let measured = max(measuredLongestLineWidth() + container.lineFragmentPadding * 2 + characterWidth * 2, available)
        let width = longestLineLength > 5000 ? max(needed, available) : measured
        if abs(container.size.width - width) > 0.5 {
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        textView.showsHorizontalScrollIndicator = true
    }

    private var longestLineRange = NSRange(location: 0, length: 0)

    private func measuredLongestLineWidth() -> CGFloat {
        guard longestLineRange.length > 0, NSMaxRange(longestLineRange) <= length else { return 0 }
        let line = (text as NSString).substring(with: longestLineRange)
        let tabs = line.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) }
        let width = (line as NSString).size(withAttributes: [.font: font]).width
        return width + CGFloat(tabs) * characterWidth * CGFloat(settings.tabWidth)
    }

    private func textViewDidLayout() {
        if !settings.wrapLines {
            // UITextView sizes its content from the container; make sure horizontal scrolling reaches the end.
            let wanted = textView.textContainer.size.width + textView.textContainerInset.left + textView.textContainerInset.right
            if textView.contentSize.width < wanted - 0.5 {
                textView.contentSize = CGSize(width: wanted, height: textView.contentSize.height)
            }
        }
        updateCurrentLine()
        gutter.setNeedsDisplay()
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

    // MARK: - Line index

    private func rebuildLineIndex() {
        let ns = text as NSString
        let count = ns.length
        var starts: [Int] = [0]
        starts.reserveCapacity(max(16, count / 30))
        var longest = 0
        var longestStart = 0
        if count > 0 {
            var buffer = [unichar](repeating: 0, count: count)
            ns.getCharacters(&buffer, range: NSRange(location: 0, length: count))
            var lineStart = 0
            for i in 0..<count where buffer[i] == 10 {
                if i - lineStart > longest { longest = i - lineStart; longestStart = lineStart }
                lineStart = i + 1
                starts.append(lineStart)
            }
            if count - lineStart > longest { longest = count - lineStart; longestStart = lineStart }
        }
        lineStarts = starts
        longestLineLength = longest
        longestLineRange = NSRange(location: longestStart, length: longest)
        updateGutterWidth()
    }

    /// 1-based line holding the UTF-16 offset.
    func lineNumber(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    func lineNumberIfLineStart(_ offset: Int) -> Int? {
        let line = lineNumber(at: offset)
        return lineStarts[line - 1] == offset ? line : nil
    }

    // MARK: - Highlighting

    private var highlightingEnabled: Bool {
        guard let document else { return false }
        return document.highlightingEnabled && document.language.mode != .plain
    }

    private func scheduleTokenize(delay: TimeInterval) {
        generation += 1
        let current = generation
        pendingTokenize?.cancel()
        guard highlightingEnabled, let language = document?.language else {
            if !tokens.isEmpty {
                tokens = []
                restyle(force: true)
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, current == self.generation else { return }
            let ns = self.text as NSString
            var units = [UInt16](repeating: 0, count: ns.length)
            if ns.length > 0 { ns.getCharacters(&units, range: NSRange(location: 0, length: ns.length)) }
            self.tokenizeQueue.async { [weak self] in
                let result = Tokenizer.tokenize(units, language: language)
                DispatchQueue.main.async {
                    guard let self, current == self.generation else { return }
                    self.tokens = result
                    self.restyle(force: true)
                }
            }
        }
        pendingTokenize = work
        if delay == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func visibleCharacterRange() -> NSRange {
        let layout = textView.layoutManager
        let inset = textView.textContainerInset
        let rect = CGRect(x: textView.contentOffset.x - inset.left, y: textView.contentOffset.y - inset.top, width: textView.bounds.width, height: textView.bounds.height)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: textView.textContainer)
        return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Index of the first element whose end is past `location`.
    private func firstIndex(in ranges: [NSRange], endingAfter location: Int) -> Int {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func firstTokenIndex(endingAfter location: Int) -> Int {
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Colours the visible part of the text plus a margin. Only this window is ever touched, so the
    /// cost does not grow with the size of the file.
    private func restyle(force: Bool) {
        guard textView.markedTextRange == nil, textView.bounds.height > 0 else { return }
        let total = length
        guard total > 0 else { styledRange = nil; return }
        let visible = visibleCharacterRange()
        if !force, let styled = styledRange, styled.location <= visible.location, NSMaxRange(styled) >= NSMaxRange(visible) { return }
        let margin = max(visible.length, 3000)
        let start = max(0, visible.location - margin)
        let end = min(total, NSMaxRange(visible) + margin)
        guard end > start else { return }
        let range = NSRange(location: start, length: end - start)

        let storage = textView.textStorage
        isApplyingText = true
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: theme.foreground, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        if !tokens.isEmpty {
            var index = firstTokenIndex(endingAfter: start)
            while index < tokens.count {
                let token = tokens[index]
                if token.range.location >= end { break }
                let clipped = NSIntersectionRange(token.range, range)
                if clipped.length > 0 { storage.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: clipped) }
                index += 1
            }
        }
        if !findRanges.isEmpty {
            var index = firstIndex(in: findRanges, endingAfter: start)
            while index < findRanges.count, findRanges[index].location < end {
                let clipped = NSIntersectionRange(findRanges[index], range)
                if clipped.length > 0 {
                    let isCurrent = currentFindRange.map { NSEqualRanges($0, findRanges[index]) } ?? false
                    storage.addAttribute(.backgroundColor, value: isCurrent ? theme.findMatch.withAlphaComponent(0.85) : theme.findMatch, range: clipped)
                }
                index += 1
            }
        }
        for bracket in bracketRanges where NSMaxRange(bracket) <= total {
            storage.addAttribute(.backgroundColor, value: theme.bracketMatch, range: bracket)
        }
        storage.endEditing()
        isApplyingText = false
        styledRange = range
    }

    // MARK: - Find

    func setFindMatches(_ ranges: [NSRange], current: NSRange?) {
        findRanges = ranges
        currentFindRange = current
        restyle(force: true)
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        textDidChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        restyle(force: false)
        gutter.setNeedsDisplay()
    }

    private func textDidChange() {
        guard !isApplyingText else { return }
        rebuildLineIndex()
        if !settings.wrapLines { updateWrapping() }
        // Positions moved; decorations are recomputed by whoever owns them.
        if !findRanges.isEmpty { findRanges = []; currentFindRange = nil }
        scheduleTokenize(delay: length > 400_000 ? 0.35 : 0.12)
        selectionDidChange()
        gutter.setNeedsDisplay()
        document?.textDidChange()
    }

    private func selectionDidChange() {
        guard !isApplyingText else { return }
        updateCurrentLine()
        updateBracketMatch()
        guard let document else { return }
        let range = textView.selectedRange
        let line = lineNumber(at: range.location)
        let lineStart = lineStarts[line - 1]
        let ns = text as NSString
        let span = range.location - lineStart
        // Counting characters is exact; for a very long line fall back to UTF-16 units.
        let column = span > 20_000 ? span + 1 : ns.substring(with: NSRange(location: lineStart, length: span)).count + 1
        let selected = range.length == 0 ? 0 : (range.length > 100_000 ? range.length : ns.substring(with: range).count)
        gutter.currentLine = line
        document.status.update(line: line, column: column, selection: selected, lines: lineStarts.count, length: ns.length)
    }

    private func updateCurrentLine() {
        let highlight = textView.currentLineView
        guard settings.highlightCurrentLine, textView.selectedRange.length == 0 else {
            highlight.isHidden = true
            return
        }
        let layout = textView.layoutManager
        let location = textView.selectedRange.location
        let ns = text as NSString
        var rect: CGRect
        if location >= ns.length, ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
            rect = layout.extraLineFragmentRect
        } else {
            let paragraph = ns.paragraphRange(for: NSRange(location: min(location, max(0, ns.length - 1)), length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            rect = layout.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        }
        guard rect.height > 0 else {
            highlight.isHidden = true
            return
        }
        highlight.isHidden = false
        let width = max(textView.contentSize.width, textView.bounds.width)
        highlight.frame = CGRect(x: 0, y: rect.minY + textView.textContainerInset.top, width: width, height: rect.height)
        if textView.subviews.first !== highlight { textView.sendSubviewToBack(highlight) }
    }

    private func updateBracketMatch() {
        let previous = bracketRanges
        bracketRanges = []
        let range = textView.selectedRange
        let ns = text as NSString
        if range.length == 0, ns.length > 0, ns.length < 4_000_000 {
            for candidate in [range.location - 1, range.location] where candidate >= 0 && candidate < ns.length {
                if let match = TextNavigation.matchingBracket(in: ns, at: candidate, limit: 50_000) {
                    bracketRanges = [NSRange(location: candidate, length: 1), NSRange(location: match, length: 1)]
                    break
                }
            }
        }
        if previous != bracketRanges { restyle(force: true) }
    }

    private static let closers: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125, 34: 34, 39: 39, 96: 96]
    private static let closingCharacters: Set<UInt16> = [41, 93, 125, 34, 39, 96]

    private func isWordCharacter(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
        // Never interfere with an input method that is still composing (Chinese, Japanese, Korean).
        guard textView.markedTextRange == nil, textView.isEditable else { return true }
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return true }
        let indent = document?.indent ?? settings.defaultIndent

        if replacement == "\n", settings.autoIndent {
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var indentEnd = lineRange.location
            while indentEnd < range.location {
                let c = ns.character(at: indentEnd)
                if c == 32 || c == 9 { indentEnd += 1 } else { break }
            }
            let leading = ns.substring(with: NSRange(location: lineRange.location, length: indentEnd - lineRange.location))
            var insertion = "\n" + leading
            var caret = (insertion as NSString).length
            var previous = range.location - 1
            while previous >= lineRange.location, ns.character(at: previous) == 32 || ns.character(at: previous) == 9 { previous -= 1 }
            if previous >= lineRange.location {
                let c = ns.character(at: previous)
                let colonBlock = c == 58 && ["python", "yaml"].contains(document?.language.id ?? "")
                if c == 123 || c == 91 || c == 40 || colonBlock {
                    insertion += indent.unit
                    caret = (insertion as NSString).length
                    let next = NSMaxRange(range)
                    if next < ns.length, let closer = EditorController.closers[c], c != 58, ns.character(at: next) == closer {
                        insertion += "\n" + leading
                    }
                }
            }
            replace(range, with: insertion, selecting: NSRange(location: range.location + caret, length: 0))
            return false
        }

        if replacement == "\t" {
            if range.length > 0, ns.substring(with: range).contains("\n") {
                indentSelection()
                return false
            }
            if indent.usesTabs { return true }
            let lineStart = lineStarts[lineNumber(at: range.location) - 1]
            let column = range.location - lineStart
            let spaces = indent.width - (column % max(1, indent.width))
            replace(range, with: String(repeating: " ", count: spaces))
            return false
        }

        guard settings.autoClosePairs else { return true }
        let units = Array(replacement.utf16)
        if units.count == 1 {
            let c = units[0]
            let nextIndex = NSMaxRange(range)
            let next: UInt16? = nextIndex < ns.length ? ns.character(at: nextIndex) : nil
            let previous: UInt16? = range.location > 0 ? ns.character(at: range.location - 1) : nil
            // Typing a closer that is already there just steps over it.
            if range.length == 0, let next, next == c, EditorController.closingCharacters.contains(c) {
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                return false
            }
            if let closer = EditorController.closers[c] {
                let closerString = String(utf16CodeUnits: [closer], count: 1)
                if range.length > 0 {
                    let inner = ns.substring(with: range)
                    replace(range, with: replacement + inner + closerString, selecting: NSRange(location: range.location + 1, length: range.length))
                    return false
                }
                let isQuote = c == closer
                let nextAllows = next == nil || next == 32 || next == 9 || next == 10 || next == 41 || next == 93 || next == 125 || next == 44 || next == 59
                let previousAllows = !isQuote || previous == nil || !(isWordCharacter(previous!) || previous == c || previous == 92)
                if nextAllows, previousAllows {
                    replace(range, with: replacement + closerString, selecting: NSRange(location: range.location + 1, length: 0))
                    return false
                }
            }
        } else if units.isEmpty, range.length == 1, NSMaxRange(range) < ns.length {
            // Backspace between an empty pair removes both halves.
            let c = ns.character(at: range.location)
            if let closer = EditorController.closers[c], ns.character(at: NSMaxRange(range)) == closer {
                replace(NSRange(location: range.location, length: 2), with: "")
                return false
            }
        }
        return true
    }

    // MARK: - Line commands

    /// The full lines covered by the selection, without the final line break.
    private func selectedLinesRange() -> NSRange {
        let ns = text as NSString
        var range = ns.lineRange(for: textView.selectedRange)
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return range
    }

    private func transformSelectedLines(_ body: (String) -> String) {
        let range = selectedLinesRange()
        let original = (text as NSString).substring(with: range)
        let result = body(original)
        guard result != original else { return }
        replace(range, with: result, selecting: NSRange(location: range.location, length: (result as NSString).length))
    }

    func indentSelection() {
        let unit = (document?.indent ?? settings.defaultIndent).unit
        transformSelectedLines { LineEdit.indent($0, unit: unit) }
    }

    func outdentSelection() {
        let width = (document?.indent ?? settings.defaultIndent).width
        transformSelectedLines { LineEdit.outdent($0, width: width) }
    }

    func toggleComment() {
        guard let language = document?.language else { return }
        if let prefix = language.commentPrefix {
            transformSelectedLines { LineEdit.toggleComment($0, prefix: prefix.trimmingCharacters(in: .whitespaces)) }
        } else if let block = language.blockComment, block.count == 2 {
            let range = selectedLinesRange()
            let original = (text as NSString).substring(with: range)
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            let result: String
            if trimmed.hasPrefix(block[0]), trimmed.hasSuffix(block[1]), trimmed.count >= block[0].count + block[1].count {
                result = String(trimmed.dropFirst(block[0].count).dropLast(block[1].count)).trimmingCharacters(in: .whitespaces)
            } else {
                result = block[0] + " " + original + " " + block[1]
            }
            replace(range, with: result, selecting: NSRange(location: range.location, length: (result as NSString).length))
        }
    }

    /// Applies a transform to the selection, or to the whole document when nothing is selected.
    func apply(_ transform: TextTransform) throws {
        let selection = textView.selectedRange
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: length)
        let original = (text as NSString).substring(with: range)
        let width = (document?.indent ?? settings.defaultIndent).width
        let result = try transform.apply(to: original, indentWidth: width)
        guard result != original else { return }
        let resultLength = (result as NSString).length
        replace(range, with: result, selecting: selection.length > 0 ? NSRange(location: range.location, length: resultLength) : NSRange(location: min(selection.location, resultLength), length: 0))
    }

    func duplicateLine() {
        let ns = text as NSString
        let lines = ns.lineRange(for: textView.selectedRange)
        var content = ns.substring(with: lines)
        let caret = textView.selectedRange
        if !content.hasSuffix("\n") { content = "\n" + content }
        replace(NSRange(location: NSMaxRange(lines), length: 0), with: content, selecting: NSRange(location: caret.location + (content as NSString).length, length: caret.length))
    }

    func deleteLine() {
        let lines = (text as NSString).lineRange(for: textView.selectedRange)
        replace(lines, with: "", selecting: NSRange(location: min(lines.location, length - lines.length), length: 0))
    }

    func selectAll() {
        textView.selectedRange = NSRange(location: 0, length: length)
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
            controller?.layout(in: bounds)
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
