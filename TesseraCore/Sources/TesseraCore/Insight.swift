import Foundation

public struct TextStatistics: Equatable, Sendable {
    public var characters = 0
    public var charactersNoSpaces = 0
    public var words = 0
    public var lines = 0
    public var bytes = 0

    public init(_ text: String) {
        var inWord = false
        var newlines = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isSpace = v == 32 || v == 9 || v == 10 || v == 13 || v == 0x3000 || v == 0xA0
            if v == 10 { newlines += 1 }
            // Each CJK ideograph or kana counts as a word of its own.
            let isCJK = (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x3040 && v <= 0x30FF) || (v >= 0x20000 && v <= 0x2FFFF)
            if isCJK {
                words += 1
                inWord = false
            } else if isSpace || !(scalar.properties.isAlphabetic || scalar.properties.numericType != nil || v == 39 || v == 95) {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
            if !isSpace { charactersNoSpaces += 1 }
        }
        characters = text.count
        bytes = text.utf8.count
        lines = text.isEmpty ? 0 : newlines + (text.hasSuffix("\n") ? 0 : 1)
    }
}

public struct OutlineItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case heading, type, function, section, tag }

    public var id: Int { line }
    public var title: String
    /// 1-based.
    public var line: Int
    public var level: Int
    public var kind: Kind
}

public enum Outline {
    private struct Rule {
        let regex: NSRegularExpression
        let kind: OutlineItem.Kind

        init(_ pattern: String, _ kind: OutlineItem.Kind) {
            // Patterns are literals in this file; a bad one is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: [])
            self.kind = kind
        }
    }

    private static let ident = "[A-Za-z_$][\\w$]*"

    private static let rules: [String: [Rule]] = {
        let cFunction = Rule("^[A-Za-z_][\\w\\s\\*&:<>,~]*?\\b(\(ident)(?:::\(ident))*)\\s*\\([^;]*$", .function)
        let braceTypes = Rule("^\\s*(?:(?:public|private|protected|internal|export|default|abstract|final|static|sealed|open|data|partial)\\s+)*(?:class|interface|enum|struct|trait|record|object|namespace)\\s+(\(ident))", .type)
        return [
            "swift": [
                Rule("^\\s*(?:(?:public|private|fileprivate|internal|open|package|final|indirect|nonisolated|@\\w+(?:\\([^)]*\\))?)\\s+)*(?:class|struct|enum|protocol|extension|actor)\\s+([\\w.]+)", .type),
                Rule("^\\s*(?:(?:public|private|fileprivate|internal|open|package|final|static|class|override|mutating|nonisolated|convenience|required|@\\w+(?:\\([^)]*\\))?)\\s+)*(?:func\\s+(\(ident)|[^\\s(]+)|(init\\??|deinit|subscript))", .function),
                Rule("^\\s*//\\s*MARK:\\s*-?\\s*(.+)$", .section),
            ],
            "python": [Rule("^\\s*class\\s+(\(ident))", .type), Rule("^\\s*(?:async\\s+)?def\\s+(\(ident))", .function)],
            "ruby": [Rule("^\\s*(?:class|module)\\s+([\\w:]+)", .type), Rule("^\\s*def\\s+([\\w.?!=]+)", .function)],
            "javascript": [braceTypes, Rule("^\\s*(?:export\\s+)?(?:default\\s+)?(?:async\\s+)?function\\s*\\*?\\s*(\(ident))", .function), Rule("^\\s*(?:export\\s+)?(?:const|let|var)\\s+(\(ident))\\s*=\\s*(?:async\\s*)?(?:\\([^)]*\\)|\(ident))\\s*=>", .function)],
            "typescript": [braceTypes, Rule("^\\s*(?:export\\s+)?(?:declare\\s+)?type\\s+(\(ident))", .type), Rule("^\\s*(?:export\\s+)?(?:default\\s+)?(?:async\\s+)?function\\s*\\*?\\s*(\(ident))", .function), Rule("^\\s*(?:export\\s+)?(?:const|let|var)\\s+(\(ident))\\s*=\\s*(?:async\\s*)?(?:\\([^)]*\\)|\(ident))\\s*(?::[^=]+)?=>", .function)],
            "go": [Rule("^type\\s+(\(ident))", .type), Rule("^func\\s+(?:\\([^)]*\\)\\s*)?(\(ident))", .function)],
            "rust": [Rule("^\\s*(?:pub(?:\\([^)]*\\))?\\s+)?(?:struct|enum|trait|mod|union|type)\\s+(\(ident))", .type), Rule("^\\s*impl(?:<[^>]*>)?\\s+([^{]+?)\\s*\\{?$", .type), Rule("^\\s*(?:pub(?:\\([^)]*\\))?\\s+)?(?:const\\s+)?(?:async\\s+)?(?:unsafe\\s+)?fn\\s+(\(ident))", .function)],
            "java": [braceTypes, Rule("^\\s+(?:(?:public|private|protected|static|final|abstract|synchronized|native)\\s+)+[\\w<>\\[\\],.? ]+\\s+(\(ident))\\s*\\([^;]*$", .function)],
            "csharp": [braceTypes, Rule("^\\s+(?:(?:public|private|protected|internal|static|virtual|override|async|abstract|sealed|partial)\\s+)+[\\w<>\\[\\],.? ]+\\s+(\(ident))\\s*\\([^;]*$", .function)],
            "kotlin": [braceTypes, Rule("^\\s*(?:(?:public|private|protected|internal|override|suspend|inline|open|abstract|operator)\\s+)*fun\\s+(?:<[^>]*>\\s*)?([\\w.]+)", .function)],
            "php": [braceTypes, Rule("^\\s*(?:(?:public|private|protected|static|abstract|final)\\s+)*function\\s+&?(\(ident))", .function)],
            "c": [Rule("^(?:typedef\\s+)?(?:struct|enum|union)\\s+(\(ident))\\s*\\{?$", .type), cFunction],
            "cpp": [Rule("^\\s*(?:class|struct|enum(?:\\s+class)?|namespace|union)\\s+(\(ident))[^;]*$", .type), cFunction],
            "objc": [Rule("^@(?:interface|implementation|protocol)\\s+(\(ident))", .type), Rule("^[-+]\\s*\\([^)]*\\)\\s*([^{;]+)", .function), cFunction],
            "shell": [Rule("^\\s*(?:function\\s+)?([\\w-]+)\\s*\\(\\)", .function), Rule("^\\s*function\\s+([\\w-]+)", .function)],
            "lua": [Rule("^\\s*(?:local\\s+)?function\\s+([\\w.:]+)", .function)],
            "sql": [Rule("(?i)^\\s*create\\s+(?:or\\s+replace\\s+)?(?:temp(?:orary)?\\s+)?(?:unique\\s+)?(?:table|view|index|function|procedure|trigger|type|schema)\\s+(?:if\\s+not\\s+exists\\s+)?([\\w.\"`]+)", .type)],
            "css": [Rule("^([^\\s@/{][^{]*?)\\s*\\{", .section), Rule("^(@(?:media|keyframes|supports|font-face|layer)[^{]*)\\{", .type)],
            "scss": [Rule("^([^\\s@/{$][^{:;]*?)\\s*\\{", .section), Rule("^\\s*@mixin\\s+([\\w-]+)", .function)],
            "ini": [Rule("^\\s*\\[([^\\]]+)\\]", .section)],
            "toml": [Rule("^\\s*\\[+([^\\]]+)\\]+", .section)],
            "yaml": [Rule("^([A-Za-z_][\\w .-]*):", .section)],
            "makefile": [Rule("^([A-Za-z_.][\\w.-]*)\\s*:(?!=)", .function)],
            "dockerfile": [Rule("(?i)^FROM\\s+(.+)$", .section)],
            "html": [Rule("(?i)<(h[1-6])[^>]*>(.*?)</h[1-6]>", .heading), Rule("(?i)<[a-z][\\w-]*[^>]*\\sid=[\"']([^\"']+)[\"']", .tag)],
            "xml": [Rule("^<([A-Za-z_][\\w:.-]*)", .tag), Rule("^\\s{1,4}<([A-Za-z_][\\w:.-]*)", .tag)],
            "dart": [braceTypes], "scala": [braceTypes, Rule("^\\s*(?:override\\s+)?def\\s+(\(ident))", .function)],
            "elixir": [Rule("^\\s*defmodule\\s+([\\w.]+)", .type), Rule("^\\s*defp?\\s+([\\w?!]+)", .function)],
            "zig": [Rule("^\\s*(?:pub\\s+)?fn\\s+(\(ident))", .function)],
            "terraform": [Rule("^(?:resource|data|module|variable|output|provider)\\s+(.+?)\\s*\\{", .section)],
            "tex": [Rule("^\\\\(?:part|chapter|section|subsection|subsubsection)\\*?\\{([^}]*)\\}", .heading)],
            "protobuf": [Rule("^\\s*(?:message|enum|service)\\s+(\(ident))", .type), Rule("^\\s*rpc\\s+(\(ident))", .function)],
            "graphql": [Rule("^\\s*(?:type|interface|enum|input|union|scalar|query|mutation|subscription|fragment)\\s+(\(ident))", .type)],
            "groovy": [braceTypes, Rule("^\\s*def\\s+(\(ident))\\s*\\(", .function)],
            "perl": [Rule("^\\s*sub\\s+(\(ident))", .function), Rule("^package\\s+([\\w:]+)", .type)],
            "r": [Rule("^\\s*([\\w.]+)\\s*(?:<-|=)\\s*function", .function)],
            "haskell": [Rule("^(?:data|newtype|type|class|instance)\\s+(.+?)(?:\\s+where|\\s*=|$)", .type), Rule("^([a-z_][\\w']*)\\s*::", .function)],
            "powershell": [Rule("(?i)^\\s*function\\s+([\\w-]+)", .function)],
            "clojure": [Rule("^\\((?:defn-?|defmacro|defun|def|define)\\s+\\(?([^\\s()]+)", .function)],
        ]
    }()

    public static func supports(_ language: Language) -> Bool {
        language.mode == .markdown || rules[language.id] != nil
    }

    public static func items(in text: String, language: Language, limit: Int = 3000) -> [OutlineItem] {
        if language.mode == .markdown { return markdown(text, limit: limit) }
        guard let rules = rules[language.id] else { return [] }
        var result: [OutlineItem] = []
        var lineNumber = 0
        text.enumerateLines { line, stop in
            lineNumber += 1
            guard line.utf16.count < 600, !line.isEmpty else { return }
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            for rule in rules {
                guard let match = rule.regex.firstMatch(in: line, options: [], range: whole) else { continue }
                var title = ""
                var level = 0
                if language.id == "html", rule.kind == .heading {
                    level = Int(ns.substring(with: match.range(at: 1)).dropFirst()) ?? 1
                    title = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                } else {
                    for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                        title = ns.substring(with: match.range(at: group))
                        break
                    }
                    let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                    level = min(indent / 2, 6)
                }
                title = title.trimmingCharacters(in: .whitespaces)
                if title.isEmpty || Outline.controlWords.contains(title) { continue }
                result.append(OutlineItem(title: title, line: lineNumber, level: level, kind: rule.kind))
                break
            }
            if result.count >= limit { stop = true }
        }
        return result
    }

    private static let controlWords: Set<String> = ["if", "for", "while", "switch", "return", "else", "catch", "sizeof", "do", "new", "delete", "case", "throw"]

    private static func markdown(_ text: String, limit: Int) -> [OutlineItem] {
        var result: [OutlineItem] = []
        var lineNumber = 0
        var fence: Character? = nil
        text.enumerateLines { line, stop in
            lineNumber += 1
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let ch = trimmed.first!
                if fence == nil { fence = ch } else if fence == ch { fence = nil }
                return
            }
            guard fence == nil, trimmed.hasPrefix("#") else { return }
            let hashes = trimmed.prefix { $0 == "#" }.count
            let rest = trimmed.dropFirst(hashes)
            guard hashes <= 6, rest.first == " " else { return }
            var title = rest.trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("#") { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            result.append(OutlineItem(title: title, line: lineNumber, level: hashes - 1, kind: .heading))
            if result.count >= limit { stop = true }
        }
        return result
    }
}

public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case same, added, removed }

    public var id: Int
    public var kind: Kind
    public var text: String
    public var leftNumber: Int?
    public var rightNumber: Int?
}

public enum LineDiff {
    public struct Summary: Equatable, Sendable {
        public var added = 0
        public var removed = 0
    }

    /// A unified line-by-line comparison of two `\n`-separated texts.
    public static func compare(_ left: String, _ right: String) -> [DiffLine] {
        let a = left.components(separatedBy: "\n")
        let b = right.components(separatedBy: "\n")
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffLine] = []
        result.reserveCapacity(a.count + inserted.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                result.append(DiffLine(id: result.count, kind: .removed, text: a[i], leftNumber: i + 1, rightNumber: nil))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                result.append(DiffLine(id: result.count, kind: .added, text: b[j], leftNumber: nil, rightNumber: j + 1))
                j += 1
            } else if i < a.count, j < b.count {
                result.append(DiffLine(id: result.count, kind: .same, text: a[i], leftNumber: i + 1, rightNumber: j + 1))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return result
    }

    public static func summary(_ lines: [DiffLine]) -> Summary {
        var summary = Summary()
        for line in lines {
            if line.kind == .added { summary.added += 1 } else if line.kind == .removed { summary.removed += 1 }
        }
        return summary
    }
}

public enum HexDump {
    public static let bytesPerRow = 16

    public static func rowCount(for byteCount: Int) -> Int {
        (byteCount + bytesPerRow - 1) / bytesPerRow
    }

    public struct Row: Equatable, Sendable {
        public var offset: String
        public var hex: String
        public var ascii: String
    }

    private static let digits = Array("0123456789ABCDEF")

    public static func row(_ index: Int, of data: Data) -> Row {
        let start = index * bytesPerRow
        let end = min(start + bytesPerRow, data.count)
        var hex = ""
        var ascii = ""
        hex.reserveCapacity(bytesPerRow * 3 + 1)
        if start < end {
            let base = data.startIndex
            for k in start..<end {
                let byte = data[base + k]
                if k > start { hex.append((k - start) == 8 ? "  " : " ") }
                hex.append(digits[Int(byte >> 4)])
                hex.append(digits[Int(byte & 0x0F)])
                ascii.append(byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : "·")
            }
        }
        var offset = String(start, radix: 16, uppercase: true)
        offset = String(repeating: "0", count: max(0, 8 - offset.count)) + offset
        return Row(offset: offset, hex: hex, ascii: ascii)
    }
}
