import UIKit

/// Draws markers for spaces, tabs and line breaks on top of the normal glyphs.
final class CodeLayoutManager: NSLayoutManager {
    var showsInvisibles = false
    var invisiblesColor: UIColor = .tertiaryLabel
    var invisiblesFont: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let storage = textStorage, glyphsToShow.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let text = storage.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: invisiblesFont, .foregroundColor: invisiblesColor]
        let ascender = invisiblesFont.ascender
        var index = characters.location
        let end = min(NSMaxRange(characters), text.length)
        while index < end {
            let symbol: String
            switch text.character(at: index) {
            case 32: symbol = "·"
            case 9: symbol = "→"
            case 10: symbol = "¬"
            default:
                index += 1
                continue
            }
            let glyph = glyphIndexForCharacter(at: index)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let location = self.location(forGlyphAt: glyph)
            let point = CGPoint(x: origin.x + fragment.minX + location.x, y: origin.y + fragment.minY + location.y - ascender)
            (symbol as NSString).draw(at: point, withAttributes: attributes)
            index += 1
        }
    }
}

protocol CodeTextViewCommands: AnyObject {
    func indentSelection()
    func outdentSelection()
    func toggleComment()
}

final class CodeTextView: UITextView {
    let codeLayoutManager: CodeLayoutManager
    weak var commands: CodeTextViewCommands?
    /// Sits behind the text and marks the line that holds the caret.
    let currentLineView = UIView()
    var onLayout: (() -> Void)?

    init() {
        let storage = NSTextStorage()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        let layout = CodeLayoutManager()
        layout.allowsNonContiguousLayout = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        codeLayoutManager = layout
        super.init(frame: .zero, textContainer: container)

        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        inlinePredictionType = .no
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 120, right: 8)
        adjustsFontForContentSizeCategory = false
        isFindInteractionEnabled = false

        currentLineView.isUserInteractionEnabled = false
        insertSubview(currentLineView, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override var keyCommands: [UIKeyCommand]? {
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdentCommand))
        outdent.wantsPriorityOverSystemBehavior = true
        return [
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

/// Line numbers, drawn beside the text view from its layout.
final class GutterView: UIView {
    weak var controller: EditorController?
    var font: UIFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var textColor: UIColor = .secondaryLabel
    var currentLineColor: UIColor = .label
    var currentLine = 0 { didSet { if currentLine != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let controller else { return }
        let textView = controller.textView
        let layout = textView.layoutManager
        let container = textView.textContainer
        let inset = textView.textContainerInset
        let offset = textView.contentOffset
        let visible = CGRect(x: 0, y: offset.y - inset.top, width: container.size.width, height: textView.bounds.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let rightEdge = bounds.width - 6

        func drawNumber(_ number: Int, lineRect: CGRect) {
            let isCurrent = number == currentLine
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isCurrent ? currentLineColor : textColor]
            let string = String(number) as NSString
            let size = string.size(withAttributes: attributes)
            // Sit on the same baseline as the text: both are bottom-aligned in the line fragment.
            let y = lineRect.maxY + inset.top - offset.y - size.height - (controller.lineBottomPadding)
            string.draw(at: CGPoint(x: rightEdge - size.width, y: y), withAttributes: attributes)
        }

        if glyphs.length > 0 {
            layout.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, glyphRange, _ in
                let character = layout.characterIndexForGlyph(at: glyphRange.location)
                guard let number = controller.lineNumberIfLineStart(character) else { return }
                drawNumber(number, lineRect: lineRect)
            }
        }
        // The empty last line has no glyphs of its own.
        let extra = layout.extraLineFragmentRect
        if extra.height > 0, extra.maxY >= visible.minY, extra.minY <= visible.maxY {
            drawNumber(controller.lineCount, lineRect: extra)
        }
    }
}
