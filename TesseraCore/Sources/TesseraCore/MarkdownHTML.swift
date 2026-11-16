import Foundation

/// A small Markdown to HTML converter for the preview pane: headings, paragraphs, emphasis,
/// code, links, images, lists (nested, ordered, task), block quotes, rules and pipe tables.
/// Raw HTML is escaped, so previewing an untrusted file cannot inject markup.
public enum MarkdownHTML {
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func render(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        // YAML front matter is shown as a code block instead of a run-on paragraph.
        var out = ""
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            out += "<pre class=\"frontmatter\"><code>" + escape(lines[1..<close].joined(separator: "\n")) + "</code></pre>\n"
            lines.removeFirst(close + 1)
        }
        var parser = BlockParser(lines: lines)
        out += parser.parse()
        return out
    }

    // MARK: - Blocks

    private struct BlockParser {
        let lines: [String]
        var index = 0

        init(lines: [String]) { self.lines = lines }

        mutating func parse() -> String {
            var out = ""
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { index += 1; continue }

                if let fence = fenceMarker(trimmed) {
                    out += codeBlock(fence, info: String(trimmed.dropFirst(fence.count)))
                } else if let level = headingLevel(trimmed) {
                    var text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    while text.hasSuffix("#") { text.removeLast() }
                    let title = text.trimmingCharacters(in: .whitespaces)
                    out += "<h\(level) id=\"\(slug(title))\">\(inline(title))</h\(level)>\n"
                    index += 1
                } else if isRule(trimmed) {
                    out += "<hr>\n"
                    index += 1
                } else if trimmed.hasPrefix(">") {
                    out += blockQuote()
                } else if listMarker(line) != nil {
                    out += list()
                } else if isTableStart() {
                    out += table()
                } else {
                    out += paragraph()
                }
            }
            return out
        }

        private func fenceMarker(_ trimmed: String) -> String? {
            for ch in ["`", "~"] as [Character] {
                let run = trimmed.prefix { $0 == ch }.count
                if run >= 3 { return String(repeating: ch, count: run) }
            }
            return nil
        }

        private func headingLevel(_ trimmed: String) -> Int? {
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard hashes >= 1, hashes <= 6 else { return nil }
            let rest = trimmed.dropFirst(hashes)
            return rest.isEmpty || rest.first == " " ? hashes : nil
        }

        private func isRule(_ trimmed: String) -> Bool {
            guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
            let compact = trimmed.filter { $0 != " " }
            return compact.count >= 3 && compact.allSatisfy { $0 == first }
        }

        /// (indent, ordered, content after the marker)
        private func listMarker(_ line: String) -> (indent: Int, ordered: Bool, content: String)? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let rest = line.drop { $0 == " " || $0 == "\t" }
            guard let first = rest.first else { return nil }
            if first == "-" || first == "*" || first == "+" {
                let after = rest.dropFirst()
                guard after.first == " " else { return nil }
                return (indent, false, String(after.dropFirst()))
            }
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, digits.count < 10 {
                let after = rest.dropFirst(digits.count)
                if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                    return (indent, true, String(after.dropFirst(2)))
                }
            }
            return nil
        }

        private mutating func codeBlock(_ fence: String, info: String) -> String {
            index += 1
            var body: [String] = []
            while index < lines.count {
                let line = lines[index]
                index += 1
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                body.append(line)
            }
            let language = info.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let attribute = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
            return "<pre><code\(attribute)>" + escape(body.joined(separator: "\n")) + "</code></pre>\n"
        }

        private mutating func blockQuote() -> String {
            var inner: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else {
                    // Lazy continuation of the quoted paragraph.
                    if trimmed.isEmpty || inner.last?.isEmpty != false { break }
                    inner.append(trimmed)
                    index += 1
                    continue
                }
                var rest = trimmed.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                inner.append(String(rest))
                index += 1
            }
            var nested = BlockParser(lines: inner)
            return "<blockquote>\n" + nested.parse() + "</blockquote>\n"
        }

        private mutating func list() -> String {
            guard let first = listMarker(lines[index]) else { return "" }
            let baseIndent = first.indent
            let tag = first.ordered ? "ol" : "ul"
            var out = "<\(tag)>\n"
            while index < lines.count, let marker = listMarker(lines[index]), marker.indent >= baseIndent, marker.indent < baseIndent + 2, marker.ordered == first.ordered {
                index += 1
                var content = marker.content
                var checkbox = ""
                for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where content.hasPrefix(prefix) {
                    content.removeFirst(prefix.count)
                    checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                }
                var body = [content]
                var nested = ""
                while index < lines.count {
                    let line = lines[index]
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        // A blank line ends the item unless an indented continuation follows.
                        guard index + 1 < lines.count else { break }
                        let next = lines[index + 1]
                        let nextIndent = next.prefix { $0 == " " || $0 == "\t" }.count
                        if next.trimmingCharacters(in: .whitespaces).isEmpty || nextIndent < baseIndent + 2 { break }
                        index += 1
                        continue
                    }
                    if let inner = listMarker(line) {
                        if inner.indent >= baseIndent + 2 {
                            nested += list()
                            continue
                        }
                        break
                    }
                    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                    if indent < baseIndent + 2, headingLevel(trimmed) != nil || fenceMarker(trimmed) != nil || trimmed.hasPrefix(">") { break }
                    body.append(trimmed)
                    index += 1
                }
                out += "<li>" + checkbox + inline(body.joined(separator: "\n")) + (nested.isEmpty ? "" : "\n" + nested) + "</li>\n"
                // Skip blank lines between items.
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      index + 1 < lines.count, let next = listMarker(lines[index + 1]), next.indent == baseIndent { index += 1 }
            }
            return out + "</\(tag)>\n"
        }

        private func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
            var result: [String] = []
            var current = ""
            var escaped = false
            var inCode = false
            for ch in trimmed {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; current.append(ch); continue }
                if ch == "`" { inCode.toggle() }
                if ch == "|", !inCode {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            result.append(current.trimmingCharacters(in: .whitespaces))
            return result
        }

        private func alignment(_ cell: String) -> String? {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard c.count >= 1, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            if c.hasPrefix(":"), c.hasSuffix(":") { return "center" }
            if c.hasSuffix(":") { return "right" }
            return c.hasPrefix(":") ? "left" : ""
        }

        private func isTableStart() -> Bool {
            guard index + 1 < lines.count, lines[index].contains("|") else { return false }
            let separator = cells(lines[index + 1])
            return !separator.isEmpty && separator.allSatisfy { alignment($0) != nil } && lines[index + 1].contains("-")
        }

        private mutating func table() -> String {
            let header = cells(lines[index])
            let alignments = cells(lines[index + 1]).map { alignment($0) ?? "" }
            index += 2
            func style(_ column: Int) -> String {
                column < alignments.count && !alignments[column].isEmpty ? " style=\"text-align:\(alignments[column])\"" : ""
            }
            var out = "<table>\n<thead><tr>"
            for (column, cell) in header.enumerated() { out += "<th\(style(column))>\(inline(cell))</th>" }
            out += "</tr></thead>\n<tbody>\n"
            while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let row = cells(lines[index])
                out += "<tr>"
                for column in 0..<header.count {
                    out += "<td\(style(column))>\(column < row.count ? inline(row[column]) : "")</td>"
                }
                out += "</tr>\n"
                index += 1
            }
            return out + "</tbody>\n</table>\n"
        }

        private mutating func paragraph() -> String {
            var body: [String] = []
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }
                if !body.isEmpty {
                    // Setext headings
                    if trimmed.allSatisfy({ $0 == "=" }) {
                        index += 1
                        let title = body.joined(separator: " ")
                        return "<h1 id=\"\(slug(title))\">\(inline(title))</h1>\n"
                    }
                    if trimmed.count >= 2, trimmed.allSatisfy({ $0 == "-" }) {
                        index += 1
                        let title = body.joined(separator: " ")
                        return "<h2 id=\"\(slug(title))\">\(inline(title))</h2>\n"
                    }
                    if headingLevel(trimmed) != nil || fenceMarker(trimmed) != nil || trimmed.hasPrefix(">") || isRule(trimmed) || listMarker(line) != nil { break }
                }
                // Two trailing spaces or a backslash force a line break.
                if line.hasSuffix("  ") || trimmed.hasSuffix("\\") {
                    body.append((trimmed.hasSuffix("\\") ? String(trimmed.dropLast()) : trimmed) + "\u{0}")
                } else {
                    body.append(trimmed)
                }
                index += 1
            }
            let html = inline(body.joined(separator: "\n")).replacingOccurrences(of: "\u{0}\n", with: "<br>\n").replacingOccurrences(of: "\u{0}", with: "")
            return "<p>" + html + "</p>\n"
        }

        private func slug(_ title: String) -> String {
            var out = ""
            for ch in title.lowercased() {
                if ch.isLetter || ch.isNumber { out.append(ch) } else if ch == " " || ch == "-" { out.append("-") }
            }
            return out
        }

        private func inline(_ text: String) -> String { MarkdownHTML.inline(text) }
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0

        func findClosing(_ marker: [Character], from: Int) -> Int? {
            guard !marker.isEmpty, from < chars.count else { return nil }
            var j = from
            while j + marker.count <= chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if Array(chars[j..<j + marker.count]) == marker, chars[j - 1] != " " {
                    // For `*` do not stop inside a longer run (`**`).
                    if marker.count == 1, j + 1 < chars.count, chars[j + 1] == marker[0], j + 2 < chars.count, chars[j + 2] != marker[0] {
                        j += 2
                        continue
                    }
                    return j
                }
                j += 1
            }
            return nil
        }

        func safeURL(_ raw: String) -> String {
            let url = raw.trimmingCharacters(in: .whitespaces)
            let lower = url.lowercased()
            if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") { return "#" }
            return escape(url)
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>".contains(chars[i + 1]) {
                out += escape(String(chars[i + 1]))
                i += 2
                continue
            }
            if c == "`" {
                var run = i
                while run < chars.count, chars[run] == "`" { run += 1 }
                let ticks = run - i
                var j = run
                var close: Int? = nil
                while j < chars.count {
                    if chars[j] == "`" {
                        var end = j
                        while end < chars.count, chars[end] == "`" { end += 1 }
                        if end - j == ticks { close = j; break }
                        j = end
                    } else {
                        j += 1
                    }
                }
                if let close {
                    let code = String(chars[run..<close]).trimmingCharacters(in: .whitespaces)
                    out += "<code>" + escape(code) + "</code>"
                    i = close + ticks
                    continue
                }
                out += String(repeating: "`", count: ticks)
                i = run
                continue
            }
            if c == "!" || c == "[" {
                let isImage = c == "!" && i + 1 < chars.count && chars[i + 1] == "["
                if isImage || c == "[" {
                    let open = isImage ? i + 1 : i
                    var depth = 0
                    var close: Int? = nil
                    var j = open
                    while j < chars.count {
                        if chars[j] == "\\" { j += 2; continue }
                        if chars[j] == "[" { depth += 1 }
                        if chars[j] == "]" { depth -= 1; if depth == 0 { close = j; break } }
                        j += 1
                    }
                    if let close, close + 1 < chars.count, chars[close + 1] == "(" {
                        var end = close + 2
                        var parens = 1
                        while end < chars.count {
                            if chars[end] == "(" { parens += 1 }
                            if chars[end] == ")" { parens -= 1; if parens == 0 { break } }
                            end += 1
                        }
                        if end < chars.count {
                            let label = String(chars[(open + 1)..<close])
                            var target = String(chars[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
                            var title = ""
                            if let quote = target.firstIndex(of: "\""), target.hasSuffix("\""), quote != target.index(before: target.endIndex) {
                                title = String(target[target.index(after: quote)..<target.index(before: target.endIndex)])
                                target = String(target[..<quote]).trimmingCharacters(in: .whitespaces)
                            }
                            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
                            let titleAttribute = title.isEmpty ? "" : " title=\"\(escape(title))\""
                            if isImage {
                                out += "<img src=\"\(safeURL(target))\" alt=\"\(escape(label))\"\(titleAttribute)>"
                            } else {
                                out += "<a href=\"\(safeURL(target))\"\(titleAttribute)>\(inline(label))</a>"
                            }
                            i = end + 1
                            continue
                        }
                    }
                }
            }
            if c == "<" {
                // <https://example.com> autolink
                if let close = chars[i...].firstIndex(of: ">") {
                    let inner = String(chars[(i + 1)..<close])
                    if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:"), !inner.contains(" ") {
                        out += "<a href=\"\(safeURL(inner))\">\(escape(inner))</a>"
                        i = close + 1
                        continue
                    }
                }
            }
            if c == "h", i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber) {
                let rest = String(chars[i..<min(chars.count, i + 8)])
                if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                    var end = i
                    while end < chars.count, !chars[end].isWhitespace, chars[end] != "<", chars[end] != ")" { end += 1 }
                    while end > i, ".,;:!?".contains(chars[end - 1]) { end -= 1 }
                    let url = String(chars[i..<end])
                    out += "<a href=\"\(safeURL(url))\">\(escape(url))</a>"
                    i = end
                    continue
                }
            }
            if c == "*" || c == "_" || c == "~" {
                var run = i
                while run < chars.count, chars[run] == c { run += 1 }
                let count = run - i
                let insideWord = c == "_" && i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber)
                let valid = run < chars.count && !chars[run].isWhitespace && !insideWord && (c == "~" ? count == 2 : count <= 3)
                if valid, let close = findClosing(Array(repeating: c, count: count), from: run + 1) {
                    let inner = inline(String(chars[run..<close]))
                    switch (c, count) {
                    case ("~", _): out += "<del>\(inner)</del>"
                    case (_, 1): out += "<em>\(inner)</em>"
                    case (_, 2): out += "<strong>\(inner)</strong>"
                    default: out += "<strong><em>\(inner)</em></strong>"
                    }
                    i = close + count
                    continue
                }
                out += escape(String(repeating: c, count: count))
                i = run
                continue
            }
            out += escape(String(c))
            i += 1
        }
        return out
    }
}
