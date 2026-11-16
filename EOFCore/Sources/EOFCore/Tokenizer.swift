import Foundation

public enum TokenKind: UInt8, Sendable, CaseIterable {
    case comment
    case string
    case number
    case keyword
    case type
    case function
    case constant
    case variable
    case tag
    case attribute
    case meta
    case heading
    case emphasis
    case link
    case inserted
    case deleted
}

public struct Token: Sendable, Equatable {
    /// UTF-16 range in the tokenized text.
    public var range: NSRange
    public var kind: TokenKind

    public init(_ location: Int, _ length: Int, _ kind: TokenKind) {
        self.range = NSRange(location: location, length: length)
        self.kind = kind
    }
}

/// A single-pass scanner over UTF-16 code units. It is deliberately forgiving:
/// broken input never fails, it only colours less.
public struct Tokenizer {
    private typealias U = UInt16

    private let s: [UInt16]
    private let language: Language
    private var tokens: [Token] = []
    private let base: Int

    public static func tokenize(_ text: String, language: Language) -> [Token] {
        tokenize(Array(text.utf16), language: language)
    }

    public static func tokenize(_ units: [UInt16], language: Language, offset: Int = 0) -> [Token] {
        guard language.mode != .plain, !units.isEmpty else { return [] }
        var tokenizer = Tokenizer(units: units, language: language, base: offset)
        tokenizer.run()
        return tokenizer.tokens
    }

    private init(units: [UInt16], language: Language, base: Int) {
        self.s = units
        self.language = language
        self.base = base
        self.codeConfig = CodeConfig(language)
    }

    private mutating func run() {
        switch language.mode {
        case .plain: break
        case .code: scanCode(0, s.count)
        case .markup: scanMarkup()
        case .markdown: scanMarkdown()
        case .yaml: scanLines(Tokenizer.scanYAMLLine)
        case .json: scanJSON()
        case .ini: scanLines(Tokenizer.scanINILine)
        case .diff: scanLines(Tokenizer.scanDiffLine)
        }
    }

    private mutating func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start else { return }
        tokens.append(Token(base + start, end - start, kind))
    }

    // MARK: - Character classes

    private static let nl: U = 10
    private static let cr: U = 13

    @inline(__always) private func isSpace(_ c: U) -> Bool { c == 32 || c == 9 }
    @inline(__always) private func isNewline(_ c: U) -> Bool { c == 10 || c == 13 }
    @inline(__always) private func isDigit(_ c: U) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) private func isAlpha(_ c: U) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }
    @inline(__always) private func isUpper(_ c: U) -> Bool { c >= 65 && c <= 90 }
    @inline(__always) private func isIdent(_ c: U) -> Bool { isAlpha(c) || isDigit(c) }

    private func lineEnd(_ from: Int, _ limit: Int) -> Int {
        var i = from
        while i < limit, !isNewline(s[i]) { i += 1 }
        return i
    }

    private func matches(_ pattern: [U], at i: Int, _ limit: Int, caseInsensitive: Bool = false) -> Bool {
        guard !pattern.isEmpty, i + pattern.count <= limit else { return false }
        for k in 0..<pattern.count {
            var a = s[i + k]
            var b = pattern[k]
            if caseInsensitive {
                if isUpper(a) { a += 32 }
                if isUpper(b) { b += 32 }
            }
            if a != b { return false }
        }
        return true
    }

    private func find(_ pattern: [U], from: Int, _ limit: Int) -> Int? {
        guard !pattern.isEmpty else { return nil }
        var i = from
        let first = pattern[0]
        while i + pattern.count <= limit {
            if s[i] == first, matches(pattern, at: i, limit) { return i }
            i += 1
        }
        return nil
    }

    private func string(_ start: Int, _ end: Int) -> String {
        String(decoding: s[start..<end], as: UTF16.self)
    }

    // MARK: - Code

    private struct CodeConfig {
        var lineComments: [[U]]
        var blockOpen: [U]
        var blockClose: [U]
        var strings: [(open: [U], close: [U], rule: StringRule)]
        var keywords: Set<String>
        var types: Set<String>
        var constants: Set<String>

        init(_ language: Language) {
            lineComments = language.lineComments.map { Array($0.utf16) }
            blockOpen = Array((language.blockComment?.first ?? "").utf16)
            blockClose = Array((language.blockComment?.last ?? "").utf16)
            // Longest opener first so `"""` wins over `"`.
            strings = language.strings
                .sorted { $0.open.utf16.count > $1.open.utf16.count }
                .map { (Array($0.open.utf16), Array($0.close.utf16), $0) }
            if language.caseInsensitive {
                keywords = Set(language.keywords.map { $0.lowercased() })
                types = Set(language.types.map { $0.lowercased() })
                constants = Set(language.constants.map { $0.lowercased() })
            } else {
                keywords = language.keywords
                types = language.types
                constants = language.constants
            }
        }
    }

    private var codeConfig: CodeConfig

    private mutating func scanCode(_ from: Int, _ limit: Int) {
        let config = codeConfig
        var i = from
        var lineStart = true
        while i < limit {
            let c = s[i]
            if isNewline(c) { lineStart = true; i += 1; continue }
            if isSpace(c) { i += 1; continue }
            let atLineStart = lineStart
            lineStart = false

            // Comments
            if !config.blockOpen.isEmpty, matches(config.blockOpen, at: i, limit) {
                let end = blockCommentEnd(i, limit, config)
                emit(i, end, .comment)
                i = end
                continue
            }
            if let prefix = config.lineComments.first(where: { matches($0, at: i, limit) }) {
                // `#` inside a shell word (`$#`, `a#b`) is not a comment.
                let wordBefore = i > from && !isSpace(s[i - 1]) && !isNewline(s[i - 1])
                if !(prefix.count == 1 && prefix[0] == 35 && wordBefore && language.dollarVariables) {
                    let end = lineEnd(i, limit)
                    emit(i, end, .comment)
                    i = end
                    continue
                }
            }

            // Preprocessor / compiler directives
            if language.hashDirectives, c == 35, atLineStart || language.id == "swift" {
                var end = i + 1
                while end < limit, isSpace(s[end]) { end += 1 }
                while end < limit, isIdent(s[end]) { end += 1 }
                if end > i + 1 {
                    emit(i, end, .meta)
                    i = end
                    continue
                }
            }

            // Strings
            if let rule = config.strings.first(where: { matches($0.open, at: i, limit) }) {
                if language.shortCharLiterals, rule.open.count == 1, rule.open[0] == 39 {
                    if let end = shortCharLiteralEnd(i, limit) {
                        emit(i, end, .string)
                        i = end
                    } else {
                        i += 1
                    }
                    continue
                }
                let end = stringEnd(i, limit, open: rule.open, close: rule.close, rule: rule.rule)
                emit(i, end, .string)
                i = end
                continue
            }

            // Numbers
            if isDigit(c) || (c == 46 && i + 1 < limit && isDigit(s[i + 1]) && (i == from || !isIdent(s[i - 1]))) {
                var end = i + 1
                while end < limit {
                    let d = s[end]
                    if isIdent(d) || d == 46 {
                        // `1..5` ranges: stop before a second dot.
                        if d == 46, end + 1 < limit, s[end + 1] == 46 { break }
                        end += 1
                    } else if (d == 43 || d == 45), (s[end - 1] == 101 || s[end - 1] == 69), !(s[i] == 48 && i + 1 < limit && (s[i + 1] | 32) == 120) {
                        end += 1 // exponent sign
                    } else {
                        break
                    }
                }
                emit(i, end, .number)
                i = end
                continue
            }

            // Variables
            if language.dollarVariables, c == 36, i + 1 < limit {
                let n = s[i + 1]
                if n == 123 || n == 40 {
                    let close: U = n == 123 ? 125 : 41
                    var end = i + 2
                    while end < limit, s[end] != close, !isNewline(s[end]) { end += 1 }
                    if end < limit, s[end] == close { end += 1 }
                    emit(i, end, .variable)
                    i = end
                    continue
                }
                if isIdent(n) || n == 64 || n == 60 || n == 94 || n == 63 || n == 42 || n == 35 || n == 33 {
                    var end = i + 2
                    if isAlpha(n) { while end < limit, isIdent(s[end]) { end += 1 } }
                    emit(i, end, .variable)
                    i = end
                    continue
                }
            }

            // Annotations
            if language.atAnnotations, c == 64, i + 1 < limit, isAlpha(s[i + 1]) {
                var end = i + 1
                while end < limit, isIdent(s[end]) || (language.hyphenIdentifiers && s[end] == 45) { end += 1 }
                emit(i, end, .meta)
                i = end
                continue
            }

            // Identifiers
            if isAlpha(c) || (c == 36 && !language.dollarVariables) || (c == 46 && language.id == "makefile" && atLineStart) {
                var end = i + 1
                while end < limit {
                    let d = s[end]
                    if isIdent(d) || d == 36 { end += 1 }
                    else if language.hyphenIdentifiers, d == 45, end + 1 < limit, isIdent(s[end + 1]) { end += 1 }
                    else if d == 63, language.id == "ruby", end + 1 < limit, !isIdent(s[end + 1]) { end += 1; break }
                    else { break }
                }
                classifyIdentifier(i, end, limit, config, atLineStart: atLineStart)
                i = end
                continue
            }

            i += 1
        }
    }

    private mutating func classifyIdentifier(_ start: Int, _ end: Int, _ limit: Int, _ config: CodeConfig, atLineStart: Bool) {
        var word = string(start, end)
        if language.caseInsensitive { word = word.lowercased() }
        let afterDot = start > 0 && s[start - 1] == 46
        if !afterDot || language.id == "makefile" {
            if config.keywords.contains(word) { emit(start, end, .keyword); return }
            if config.constants.contains(word) { emit(start, end, .constant); return }
            if config.types.contains(word) { emit(start, end, .type); return }
        }
        var next = end
        while next < limit, isSpace(s[next]) { next += 1 }
        if next < limit, s[next] == 40 {
            emit(start, end, .function)
            return
        }
        if language.id == "makefile", atLineStart, next < limit, s[next] == 58, !(next + 1 < limit && s[next + 1] == 61) {
            emit(start, end, .function)
            return
        }
        if language.hyphenIdentifiers, language.id == "css" || language.id == "scss", next < limit, s[next] == 58 {
            emit(start, end, .attribute)
            return
        }
        if language.capitalizedTypes, isUpper(s[start]), end - start > 1 {
            // ALL_CAPS reads as a constant, CamelCase as a type.
            var hasLower = false
            for k in start..<end where s[k] >= 97 && s[k] <= 122 { hasLower = true; break }
            emit(start, end, hasLower ? .type : .constant)
        }
    }

    private func blockCommentEnd(_ start: Int, _ limit: Int, _ config: CodeConfig) -> Int {
        var i = start + config.blockOpen.count
        var depth = 1
        while i < limit {
            if matches(config.blockClose, at: i, limit) {
                depth -= 1
                i += config.blockClose.count
                if depth == 0 { return i }
            } else if language.nestedBlockComments, matches(config.blockOpen, at: i, limit) {
                depth += 1
                i += config.blockOpen.count
            } else {
                i += 1
            }
        }
        return limit
    }

    private func stringEnd(_ start: Int, _ limit: Int, open: [U], close: [U], rule: StringRule) -> Int {
        var i = start + open.count
        while i < limit {
            let c = s[i]
            if rule.escapes, c == 92, i + 1 < limit {
                i += 2
                continue
            }
            if matches(close, at: i, limit) { return i + close.count }
            if !rule.multiline, isNewline(c) { return i }
            i += 1
        }
        return limit
    }

    /// `'a'`, `'\n'`, `'\u{1F600}'` are literals; `'a` (a lifetime) is not.
    private func shortCharLiteralEnd(_ start: Int, _ limit: Int) -> Int? {
        var i = start + 1
        guard i < limit else { return nil }
        if s[i] == 92 {
            i += 2
            while i < limit, i - start < 12, s[i] != 39, !isNewline(s[i]) { i += 1 }
        } else {
            i += 1
            // A surrogate pair is one character.
            if i < limit, s[i] >= 0xDC00, s[i] <= 0xDFFF { i += 1 }
        }
        guard i < limit, s[i] == 39 else { return nil }
        return i + 1
    }

    // MARK: - Markup (HTML, XML)

    private mutating func scanMarkup() {
        let limit = s.count
        let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
        let cdataOpen = Array("<![CDATA[".utf16), cdataClose = Array("]]>".utf16)
        var i = 0
        while i < limit {
            let c = s[i]
            if c == 38 { // &entity;
                var end = i + 1
                while end < limit, end - i < 12, isIdent(s[end]) || s[end] == 35 { end += 1 }
                if end < limit, s[end] == 59, end > i + 1 {
                    emit(i, end + 1, .constant)
                    i = end + 1
                    continue
                }
                i += 1
                continue
            }
            guard c == 60 else { i += 1; continue }
            if matches(commentOpen, at: i, limit) {
                let end = find(commentClose, from: i + 4, limit).map { $0 + 3 } ?? limit
                emit(i, end, .comment)
                i = end
                continue
            }
            if matches(cdataOpen, at: i, limit) {
                let end = find(cdataClose, from: i + 9, limit).map { $0 + 3 } ?? limit
                emit(i, end, .string)
                i = end
                continue
            }
            if i + 1 < limit, s[i + 1] == 33 || s[i + 1] == 63 { // <!DOCTYPE …> <?xml …?>
                var end = i + 2
                while end < limit, s[end] != 62 { end += 1 }
                if end < limit { end += 1 }
                emit(i, end, .meta)
                i = end
                continue
            }
            // <tag or </tag
            var nameStart = i + 1
            let closing = nameStart < limit && s[nameStart] == 47
            if closing { nameStart += 1 }
            guard nameStart < limit, isAlpha(s[nameStart]) else { i += 1; continue }
            var nameEnd = nameStart
            while nameEnd < limit, isIdent(s[nameEnd]) || s[nameEnd] == 45 || s[nameEnd] == 58 || s[nameEnd] == 46 { nameEnd += 1 }
            emit(i, nameEnd, .tag)
            let tagName = string(nameStart, nameEnd).lowercased()
            // Attributes
            var j = nameEnd
            var selfClosing = false
            while j < limit, s[j] != 62 {
                let d = s[j]
                if d == 34 || d == 39 {
                    var end = j + 1
                    while end < limit, s[end] != d { end += 1 }
                    if end < limit { end += 1 }
                    emit(j, end, .string)
                    j = end
                } else if isAlpha(d) || d == 64 || d == 58 {
                    var end = j + 1
                    while end < limit, isIdent(s[end]) || s[end] == 45 || s[end] == 58 || s[end] == 46 || s[end] == 64 { end += 1 }
                    emit(j, end, .attribute)
                    j = end
                } else if d == 60 {
                    break // a stray "<": the tag was never closed
                } else {
                    selfClosing = d == 47
                    j += 1
                }
            }
            if j < limit, s[j] == 62 {
                emit(j - (selfClosing ? 1 : 0), j + 1, .tag)
                j += 1
            }
            i = j
            // Embedded script / style bodies
            if !closing, !selfClosing, let embeddedID = language.embedded[tagName],
               let embedded = Languages.language(id: embeddedID) {
                let closeTag = Array("</\(tagName)".utf16)
                var end = i
                while end < limit, !(s[end] == 60 && matches(closeTag, at: end, limit, caseInsensitive: true)) { end += 1 }
                if end > i {
                    let inner = Tokenizer.tokenize(Array(s[i..<end]), language: embedded, offset: base + i)
                    tokens.append(contentsOf: inner)
                }
                i = end
            }
        }
    }

    // MARK: - Line-oriented modes

    private mutating func scanLines(_ body: (inout Tokenizer, Int, Int) -> Void) {
        let limit = s.count
        var i = 0
        while i < limit {
            let end = lineEnd(i, limit)
            if end > i { body(&self, i, end) }
            i = end
            while i < limit, isNewline(s[i]) {
                i += 1
                if s[i - 1] == Tokenizer.nl { break }
            }
        }
    }

    /// Emits tokens for a scalar value: quoted strings, numbers, booleans, a trailing comment.
    private mutating func scanScalar(_ from: Int, _ end: Int, commentChars: [U]) {
        var i = from
        while i < end {
            let c = s[i]
            if isSpace(c) { i += 1; continue }
            if commentChars.contains(c), i == from || isSpace(s[i - 1]) {
                emit(i, end, .comment)
                return
            }
            if c == 34 || c == 39 {
                var j = i + 1
                while j < end, s[j] != c {
                    if c == 34, s[j] == 92 { j += 1 }
                    j += 1
                }
                j = min(j + 1, end)
                emit(i, j, .string)
                i = j
                continue
            }
            // A bare word up to whitespace, comma or bracket.
            var j = i
            while j < end, !isSpace(s[j]), s[j] != 44, s[j] != 93, s[j] != 125, s[j] != 91, s[j] != 123 { j += 1 }
            if j == i { i += 1; continue }
            let word = string(i, j)
            if Tokenizer.scalarConstants.contains(word.lowercased()) {
                emit(i, j, .constant)
            } else if isNumber(word) {
                emit(i, j, .number)
            } else if c == 38 || c == 42 {
                emit(i, j, .meta) // YAML anchor / alias
            }
            i = j
        }
    }

    private static let scalarConstants: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~", "nan", "inf", "+inf", "-inf"]

    private func isNumber(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        guard (first.value >= 48 && first.value <= 57) || first == "-" || first == "+" || first == "." else { return false }
        if word.hasPrefix("0x") || word.hasPrefix("0o") || word.hasPrefix("0b") { return true }
        return Double(word.replacingOccurrences(of: "_", with: "")) != nil
    }

    private static func scanYAMLLine(_ t: inout Tokenizer, _ start: Int, _ end: Int) { t.yamlLine(start, end) }
    private static func scanINILine(_ t: inout Tokenizer, _ start: Int, _ end: Int) { t.iniLine(start, end) }
    private static func scanDiffLine(_ t: inout Tokenizer, _ start: Int, _ end: Int) { t.diffLine(start, end) }

    private mutating func yamlLine(_ start: Int, _ end: Int) {
        var i = start
        while i < end, isSpace(s[i]) { i += 1 }
        guard i < end else { return }
        if s[i] == 35 { emit(i, end, .comment); return }
        if end - i >= 3, (s[i] == 45 && s[i + 1] == 45 && s[i + 2] == 45) || (s[i] == 46 && s[i + 1] == 46 && s[i + 2] == 46) {
            emit(i, end, .meta)
            return
        }
        // List dashes
        while i + 1 < end, s[i] == 45, isSpace(s[i + 1]) {
            emit(i, i + 1, .keyword)
            i += 2
            while i < end, isSpace(s[i]) { i += 1 }
        }
        guard i < end else { return }
        // key: — the colon must be followed by a space or end of line and sit outside quotes.
        var j = i
        var quote: U = 0
        var colon: Int? = nil
        while j < end {
            let c = s[j]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if (c == 34 || c == 39), j == i {
                quote = c
            } else if c == 58, j + 1 == end || isSpace(s[j + 1]) {
                colon = j
                break
            } else if c == 35, j > i, isSpace(s[j - 1]) {
                break
            } else if c == 123 || c == 91 {
                break
            }
            j += 1
        }
        if let colon {
            emit(i, colon, .attribute)
            scanScalar(colon + 1, end, commentChars: [35])
        } else {
            scanScalar(i, end, commentChars: [35])
        }
    }

    private mutating func iniLine(_ start: Int, _ end: Int) {
        var i = start
        while i < end, isSpace(s[i]) { i += 1 }
        guard i < end else { return }
        let c = s[i]
        if c == 35 || c == 59 { emit(i, end, .comment); return }
        if c == 91 { // [section] or [[table]]
            var j = end
            while j > i, isSpace(s[j - 1]) { j -= 1 }
            if let close = (i..<j).last(where: { s[$0] == 93 }) {
                emit(i, close + 1, .heading)
                scanScalar(close + 1, end, commentChars: [35, 59])
                return
            }
        }
        var j = i
        var quote: U = 0
        while j < end {
            let d = s[j]
            if quote != 0 { if d == quote { quote = 0 } }
            else if d == 34 || d == 39 { quote = d }
            else if d == 61 || (d == 58 && language.id == "ini") { break }
            j += 1
        }
        if j < end {
            var keyEnd = j
            while keyEnd > i, isSpace(s[keyEnd - 1]) { keyEnd -= 1 }
            emit(i, keyEnd, .attribute)
            scanScalar(j + 1, end, commentChars: [35, 59])
        } else {
            scanScalar(i, end, commentChars: [35, 59])
        }
    }

    private mutating func diffLine(_ start: Int, _ end: Int) {
        let c = s[start]
        let plusHeader = Array("+++".utf16), minusHeader = Array("---".utf16)
        if matches(plusHeader, at: start, end) || matches(minusHeader, at: start, end) {
            emit(start, end, .heading)
        } else if c == 43 || c == 62 {
            emit(start, end, .inserted)
        } else if c == 45 || c == 60 {
            emit(start, end, .deleted)
        } else if c == 64 {
            emit(start, end, .meta)
        } else if !isSpace(c) && c != 92 {
            emit(start, end, .heading) // diff, index, Only in …
        }
    }

    // MARK: - JSON

    private mutating func scanJSON() {
        let limit = s.count
        var i = 0
        while i < limit {
            let c = s[i]
            if c == 34 {
                var j = i + 1
                while j < limit, s[j] != 34, !isNewline(s[j]) {
                    if s[j] == 92 { j += 1 }
                    j += 1
                }
                j = min(j + 1, limit)
                var next = j
                while next < limit, isSpace(s[next]) || isNewline(s[next]) { next += 1 }
                emit(i, j, next < limit && s[next] == 58 ? .attribute : .string)
                i = j
            } else if c == 47, i + 1 < limit, s[i + 1] == 47 {
                let end = lineEnd(i, limit)
                emit(i, end, .comment)
                i = end
            } else if c == 47, i + 1 < limit, s[i + 1] == 42 {
                let end = find([42, 47], from: i + 2, limit).map { $0 + 2 } ?? limit
                emit(i, end, .comment)
                i = end
            } else if isDigit(c) || (c == 45 && i + 1 < limit && isDigit(s[i + 1])) {
                var j = i + 1
                while j < limit, isIdent(s[j]) || s[j] == 46 || s[j] == 43 || s[j] == 45 { j += 1 }
                emit(i, j, .number)
                i = j
            } else if isAlpha(c) {
                var j = i + 1
                while j < limit, isIdent(s[j]) { j += 1 }
                let word = string(i, j)
                if word == "true" || word == "false" || word == "null" { emit(i, j, .constant) }
                i = j
            } else {
                i += 1
            }
        }
    }

    // MARK: - Markdown

    private mutating func scanMarkdown() {
        let limit = s.count
        var i = 0
        var fence: (char: U, count: Int)? = nil
        while i < limit {
            let end = lineEnd(i, limit)
            var p = i
            while p < end, isSpace(s[p]) { p += 1 }
            let indent = p - i

            // Fenced code
            if p < end, s[p] == 96 || s[p] == 126 {
                let ch = s[p]
                var q = p
                while q < end, s[q] == ch { q += 1 }
                let run = q - p
                if run >= 3 {
                    if let open = fence {
                        if open.char == ch, run >= open.count {
                            emit(i, end, .meta)
                            fence = nil
                            i = nextLine(end, limit)
                            continue
                        }
                    } else {
                        emit(i, end, .meta)
                        fence = (ch, run)
                        i = nextLine(end, limit)
                        continue
                    }
                }
            }
            if fence != nil {
                emit(i, end, .string)
                i = nextLine(end, limit)
                continue
            }
            if p < end {
                let c = s[p]
                if c == 35, indent < 4 { // # heading
                    var q = p
                    while q < end, s[q] == 35 { q += 1 }
                    if q - p <= 6, q == end || isSpace(s[q]) {
                        emit(i, end, .heading)
                        i = nextLine(end, limit)
                        continue
                    }
                }
                if c == 62 { // > quote
                    emit(p, p + 1, .keyword)
                    markdownInline(p + 1, end)
                    i = nextLine(end, limit)
                    continue
                }
                if isRule(p, end) {
                    emit(p, end, .meta)
                    i = nextLine(end, limit)
                    continue
                }
                // List markers
                if (c == 45 || c == 42 || c == 43), p + 1 < end, isSpace(s[p + 1]) {
                    emit(p, p + 1, .keyword)
                    p += 2
                    // Task list box
                    if p + 2 < end, s[p] == 91, s[p + 2] == 93 {
                        emit(p, p + 3, .constant)
                        p += 3
                    }
                } else if isDigit(c) {
                    var q = p
                    while q < end, isDigit(s[q]) { q += 1 }
                    if q + 1 < end, s[q] == 46 || s[q] == 41, isSpace(s[q + 1]) {
                        emit(p, q + 1, .keyword)
                        p = q + 1
                    }
                }
                markdownInline(p, end)
            }
            i = nextLine(end, limit)
        }
    }

    private func nextLine(_ end: Int, _ limit: Int) -> Int {
        var i = end
        if i < limit, s[i] == Tokenizer.cr { i += 1 }
        if i < limit, s[i] == Tokenizer.nl { i += 1 }
        return max(i, min(end + 1, limit))
    }

    private func isRule(_ start: Int, _ end: Int) -> Bool {
        let c = s[start]
        guard c == 45 || c == 42 || c == 95 else { return false }
        var count = 0
        for k in start..<end {
            if s[k] == c { count += 1 } else if !isSpace(s[k]) { return false }
        }
        return count >= 3
    }

    private mutating func markdownInline(_ from: Int, _ end: Int) {
        var i = from
        while i < end {
            let c = s[i]
            if c == 92 { i += 2; continue }
            if c == 96 { // `code`
                var run = i
                while run < end, s[run] == 96 { run += 1 }
                let ticks = Array(repeating: U(96), count: run - i)
                if let close = find(ticks, from: run, end) {
                    emit(i, close + ticks.count, .string)
                    i = close + ticks.count
                } else {
                    i = run
                }
                continue
            }
            if c == 42 || c == 95 || c == 126 { // *em* **strong** ~~strike~~
                var run = i
                while run < end, s[run] == c { run += 1 }
                let count = run - i
                let wordBefore = i > from && isIdent(s[i - 1])
                if count <= 3, run < end, !isSpace(s[run]), !(c == 95 && wordBefore), !(c == 126 && count != 2) {
                    let marker = Array(repeating: c, count: count)
                    var close = run
                    var found: Int? = nil
                    while let hit = find(marker, from: close, end) {
                        if !isSpace(s[hit - 1]) { found = hit; break }
                        close = hit + 1
                    }
                    if let found {
                        emit(i, found + count, .emphasis)
                        i = found + count
                        continue
                    }
                }
                i = run
                continue
            }
            if c == 91 || (c == 33 && i + 1 < end && s[i + 1] == 91) { // [text](url) ![alt](src)
                let open = c == 33 ? i + 1 : i
                var close = open + 1
                while close < end, s[close] != 93 { close += 1 }
                if close + 1 < end, s[close + 1] == 40 || s[close + 1] == 91 {
                    let closer: U = s[close + 1] == 40 ? 41 : 93
                    var urlEnd = close + 2
                    while urlEnd < end, s[urlEnd] != closer { urlEnd += 1 }
                    if urlEnd < end {
                        emit(i, close + 1, .link)
                        emit(close + 1, urlEnd + 1, .string)
                        i = urlEnd + 1
                        continue
                    }
                }
                i += 1
                continue
            }
            if c == 60 { // <https://…> or inline HTML tag
                var close = i + 1
                while close < end, s[close] != 62, !isSpace(s[close]) || s[i + 1] != 104 { close += 1 }
                if close < end, s[close] == 62, close > i + 1 {
                    emit(i, close + 1, isAlpha(s[i + 1]) || s[i + 1] == 47 ? .tag : .link)
                    i = close + 1
                    continue
                }
            }
            if c == 104, matches(Tokenizer.httpPrefix, at: i, end) || matches(Tokenizer.httpsPrefix, at: i, end) {
                var close = i
                while close < end, !isSpace(s[close]), s[close] != 41, s[close] != 62 { close += 1 }
                emit(i, close, .link)
                i = close
                continue
            }
            i += 1
        }
    }

    private static let httpPrefix = Array("http://".utf16)
    private static let httpsPrefix = Array("https://".utf16)
}
