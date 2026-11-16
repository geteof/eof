import Foundation
import Markdown

/// Markdown to HTML for the preview pane. Parsing is swift-markdown (cmark-gfm); the rendering is
/// done here instead of with the package's `HTMLFormatter`, because that one writes raw HTML blocks,
/// inline HTML and link targets into the output unchanged. A preview of an untrusted file must not
/// let the file inject markup, so this renderer escapes all of them.
public enum MarkdownHTML {
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func render(_ markdown: String) -> String {
        var source = markdown
        var out = ""
        // YAML front matter is shown as a code block instead of a rule and a run-on paragraph.
        if source.hasPrefix("---\n"), let close = source.range(of: "\n---", range: source.index(source.startIndex, offsetBy: 3)..<source.endIndex) {
            let after = source[close.upperBound...]
            if after.isEmpty || after.first == "\n" {
                let body = source[source.index(source.startIndex, offsetBy: 4)..<close.lowerBound]
                out += "<pre class=\"frontmatter\"><code>" + escape(String(body)) + "</code></pre>\n"
                source = String(after.dropFirst())
            }
        }
        var renderer = SafeHTMLRenderer()
        renderer.visit(Document(parsing: source))
        return out + renderer.result
    }

    /// A URL that is safe to put in `href` or `src`: script-running schemes are replaced by `#`.
    static func safeURL(_ raw: String?) -> String {
        guard let raw else { return "" }
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Browsers ignore control characters and whitespace inside the scheme, so strip them before checking.
        let compact = url.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }.map(String.init).joined().lowercased()
        for scheme in ["javascript:", "vbscript:", "data:", "file:"] where compact.hasPrefix(scheme) {
            if scheme == "data:", compact.hasPrefix("data:image/"), !compact.hasPrefix("data:image/svg") { break }
            return "#"
        }
        return escape(url)
    }
}

private struct SafeHTMLRenderer: MarkupWalker {
    var result = ""
    private var inTableHead = false
    private var alignments: [Table.ColumnAlignment?] = []
    private var column = 0

    private func escape(_ text: String) -> String { MarkdownHTML.escape(text) }

    private func slug(_ title: String) -> String {
        var out = ""
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if ch == " " || ch == "-" { out.append("-") }
        }
        return out
    }

    private mutating func wrap(_ tag: String, _ markup: Markup) {
        result += "<\(tag)>"
        descendInto(markup)
        result += "</\(tag)>"
    }

    // MARK: Blocks

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        var attribute = ""
        if let language = codeBlock.language?.split(separator: " ").first, !language.isEmpty {
            attribute = " class=\"language-\(escape(String(language)))\""
        }
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        result += "<pre><code\(attribute)>\(escape(code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        let level = min(max(heading.level, 1), 6)
        result += "<h\(level) id=\"\(escape(slug(heading.plainText)))\">"
        descendInto(heading)
        result += "</h\(level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Shown as text, never interpreted.
        var raw = html.rawHTML
        while raw.hasSuffix("\n") { raw.removeLast() }
        result += "<pre class=\"raw-html\"><code>\(escape(raw))</code></pre>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        result += "<li>"
        if let checkbox = listItem.checkbox {
            result += "<input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")> "
        }
        // A tight item holds one paragraph; render it inline so simple lists stay compact.
        let children = Array(listItem.children)
        for (index, child) in children.enumerated() {
            if index == 0, let paragraph = child as? Paragraph, children.dropFirst().allSatisfy({ $0 is UnorderedList || $0 is OrderedList }) {
                descendInto(paragraph)
                if children.count > 1 { result += "\n" }
            } else {
                visit(child)
            }
        }
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        result += orderedList.startIndex != 1 ? "<ol start=\"\(orderedList.startIndex)\">\n" : "<ol>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitTable(_ table: Table) {
        result += "<table>\n"
        alignments = table.columnAlignments
        descendInto(table)
        alignments = []
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead><tr>"
        inTableHead = true
        column = 0
        descendInto(tableHead)
        inTableHead = false
        result += "</tr></thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        result += "<tr>"
        column = 0
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }
        let tag = inTableHead ? "th" : "td"
        result += "<\(tag)"
        if column < alignments.count, let alignment = alignments[column] {
            let value: String
            switch alignment {
            case .left: value = "left"
            case .center: value = "center"
            case .right: value = "right"
            }
            result += " style=\"text-align:\(value)\""
        }
        column += 1
        if tableCell.rowspan > 1 { result += " rowspan=\"\(tableCell.rowspan)\"" }
        if tableCell.colspan > 1 { result += " colspan=\"\(tableCell.colspan)\"" }
        result += ">"
        descendInto(tableCell)
        result += "</\(tag)>"
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) {
        result += escape(text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(escape(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) { wrap("em", emphasis) }
    mutating func visitStrong(_ strong: Strong) { wrap("strong", strong) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap("del", strikethrough) }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += escape(inlineHTML.rawHTML)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLink(_ link: Link) {
        result += "<a href=\"\(MarkdownHTML.safeURL(link.destination))\""
        if let title = link.title, !title.isEmpty { result += " title=\"\(escape(title))\"" }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        result += "<img src=\"\(MarkdownHTML.safeURL(image.source))\" alt=\"\(escape(image.plainText))\""
        if let title = image.title, !title.isEmpty { result += " title=\"\(escape(title))\"" }
        result += ">"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        if let destination = symbolLink.destination { result += "<code>\(escape(destination))</code>" }
    }

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) {
        descendInto(attributes)
    }

    mutating func visitCustomInline(_ customInline: CustomInline) {
        result += escape(customInline.text)
    }
}
