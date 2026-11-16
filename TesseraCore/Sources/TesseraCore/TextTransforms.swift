import Foundation

public enum TextTransform: String, CaseIterable, Identifiable, Sendable {
    case uppercase, lowercase, titleCase
    case sortAscending, sortDescending, sortNumeric, reverseLines, removeDuplicateLines, removeBlankLines
    case trimTrailingWhitespace, joinLines, tabsToSpaces, spacesToTabs
    case base64Encode, base64Decode, urlEncode, urlDecode
    case jsonPretty, jsonMinify

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable {
        case letterCase, lines, whitespace, encode, json
    }

    public var group: Group {
        switch self {
        case .uppercase, .lowercase, .titleCase: return .letterCase
        case .sortAscending, .sortDescending, .sortNumeric, .reverseLines, .removeDuplicateLines, .removeBlankLines, .joinLines: return .lines
        case .trimTrailingWhitespace, .tabsToSpaces, .spacesToTabs: return .whitespace
        case .base64Encode, .base64Decode, .urlEncode, .urlDecode: return .encode
        case .jsonPretty, .jsonMinify: return .json
        }
    }

    public enum Failure: Error, Equatable {
        case notBase64, notJSON(String), notDecodable
    }

    /// Applies the transform to `\n`-separated text. `indentWidth` is used by the tab conversions and JSON.
    public func apply(to text: String, indentWidth: Int = 4) throws -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .sortAscending:
            return mapLines(text) { $0.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending } }
        case .sortDescending:
            return mapLines(text) { $0.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedDescending } }
        case .sortNumeric:
            return mapLines(text) { lines in
                lines.enumerated().sorted { a, b in
                    let x = TextTransform.leadingNumber(a.element), y = TextTransform.leadingNumber(b.element)
                    return x == y ? a.offset < b.offset : x < y
                }.map(\.element)
            }
        case .reverseLines: return mapLines(text) { $0.reversed() }
        case .removeDuplicateLines:
            return mapLines(text) { lines in
                var seen = Set<String>()
                return lines.filter { seen.insert($0).inserted }
            }
        case .removeBlankLines:
            return mapLines(text) { $0.filter { !$0.allSatisfy { $0 == " " || $0 == "\t" } } }
        case .trimTrailingWhitespace:
            return mapEachLine(text) { line in
                var end = line.endIndex
                while end > line.startIndex {
                    let before = line.index(before: end)
                    if line[before] == " " || line[before] == "\t" { end = before } else { break }
                }
                return String(line[..<end])
            }
        case .joinLines:
            return text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .tabsToSpaces:
            return mapEachLine(text) { TextTransform.expandTabs($0, width: indentWidth) }
        case .spacesToTabs:
            return mapEachLine(text) { TextTransform.leadingSpacesToTabs($0, width: indentWidth) }
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            let compact = text.filter { !$0.isWhitespace }
            var padded = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while padded.count % 4 != 0 { padded.append("=") }
            guard let data = Data(base64Encoded: padded) else { throw Failure.notBase64 }
            guard let decoded = String(data: data, encoding: .utf8) else { throw Failure.notDecodable }
            return decoded
        case .urlEncode:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        case .urlDecode:
            guard let decoded = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { throw Failure.notDecodable }
            return decoded
        case .jsonPretty:
            return try JSONFormatter.format(text, indent: String(repeating: " ", count: max(1, indentWidth)))
        case .jsonMinify:
            return try JSONFormatter.format(text, indent: nil)
        }
    }

    private func mapLines(_ text: String, _ body: ([String]) -> [String]) -> String {
        let trailingNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        let result = body(lines).joined(separator: "\n")
        return trailingNewline ? result + "\n" : result
    }

    private func mapEachLine(_ text: String, _ body: (String) -> String) -> String {
        text.components(separatedBy: "\n").map(body).joined(separator: "\n")
    }

    private static func leadingNumber(_ line: String) -> Double {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var prefix = ""
        for ch in trimmed {
            if ch.isNumber || ch == "." || (prefix.isEmpty && (ch == "-" || ch == "+")) { prefix.append(ch) } else { break }
        }
        return Double(prefix) ?? .greatestFiniteMagnitude
    }

    static func expandTabs(_ line: String, width: Int) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        var column = 0
        for ch in line {
            if ch == "\t" {
                let pad = width - (column % width)
                out.append(String(repeating: " ", count: pad))
                column += pad
            } else {
                out.append(ch)
                column += 1
            }
        }
        return out
    }

    static func leadingSpacesToTabs(_ line: String, width: Int) -> String {
        var spaces = 0
        var tabs = 0
        var rest = line.startIndex
        for index in line.indices {
            let ch = line[index]
            if ch == " " {
                spaces += 1
                if spaces == width { tabs += 1; spaces = 0 }
            } else if ch == "\t" {
                tabs += 1
                spaces = 0
            } else {
                rest = index
                return String(repeating: "\t", count: tabs) + String(repeating: " ", count: spaces) + line[rest...]
            }
        }
        return String(repeating: "\t", count: tabs) + String(repeating: " ", count: spaces)
    }
}

/// Line-level edits that depend on the editor's indentation and the language's comment marker.
public enum LineEdit {
    public static func indent(_ text: String, unit: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : unit + $0 }.joined(separator: "\n")
    }

    public static func outdent(_ text: String, width: Int) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var removed = 0
            var rest = Substring(line)
            while removed < width, rest.first == " " {
                rest = rest.dropFirst()
                removed += 1
            }
            return String(rest)
        }.joined(separator: "\n")
    }

    /// Comments every non-blank line, or uncomments when all of them are already commented.
    public static func toggleComment(_ text: String, prefix: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return text }
        let allCommented = content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
        if allCommented {
            return lines.map { line -> String in
                guard let range = line.range(of: prefix) else { return line }
                var result = line
                var end = range.upperBound
                if end < line.endIndex, line[end] == " " { end = line.index(after: end) }
                result.removeSubrange(range.lowerBound..<end)
                return result
            }.joined(separator: "\n")
        }
        // Insert at the shallowest indentation so the block stays aligned.
        let depth = content.map { line in line.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let index = line.index(line.startIndex, offsetBy: depth)
            return line[..<index] + prefix + " " + line[index...]
        }.joined(separator: "\n")
    }
}

/// Re-indents JSON without reordering keys or rewriting numbers.
public enum JSONFormatter {
    public static func format(_ text: String, indent: String?) throws -> String {
        guard let data = text.data(using: .utf8) else { throw TextTransform.Failure.notDecodable }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw TextTransform.Failure.notJSON(error.localizedDescription)
        }
        let s = Array(text.utf16)
        var out = [UInt16]()
        out.reserveCapacity(s.count * 2)
        let pad = indent.map { Array($0.utf16) }
        var depth = 0
        var i = 0

        func newline(_ out: inout [UInt16]) {
            guard let pad else { return }
            out.append(10)
            for _ in 0..<depth { out.append(contentsOf: pad) }
        }
        func nextSignificant(_ from: Int) -> UInt16? {
            var j = from
            while j < s.count {
                let c = s[j]
                if c != 32, c != 9, c != 10, c != 13 { return c }
                j += 1
            }
            return nil
        }

        while i < s.count {
            let c = s[i]
            switch c {
            case 34: // string
                let start = i
                i += 1
                while i < s.count, s[i] != 34 {
                    if s[i] == 92 { i += 1 }
                    i += 1
                }
                i = min(i + 1, s.count)
                out.append(contentsOf: s[start..<i])
                continue
            case 123, 91: // { [
                out.append(c)
                let close: UInt16 = c == 123 ? 125 : 93
                if nextSignificant(i + 1) == close {
                    // Keep empty containers on one line.
                    var j = i + 1
                    while s[j] != close { j += 1 }
                    out.append(close)
                    i = j + 1
                    continue
                }
                depth += 1
                newline(&out)
            case 125, 93: // } ]
                depth = max(0, depth - 1)
                newline(&out)
                out.append(c)
            case 44: // ,
                out.append(c)
                newline(&out)
            case 58: // :
                out.append(c)
                if pad != nil { out.append(32) }
            case 32, 9, 10, 13:
                break
            default:
                out.append(c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }
}
