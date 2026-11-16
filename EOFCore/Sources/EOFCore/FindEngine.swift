import Foundation

public struct FindOptions: Equatable, Sendable {
    public var caseSensitive = false
    public var wholeWord = false
    public var regex = false

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

public struct FindQuery: @unchecked Sendable {
    public let expression: NSRegularExpression
    public let options: FindOptions

    public enum Failure: Error, LocalizedError {
        case empty
        case invalidPattern(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return nil
            case .invalidPattern(let message): return message
            }
        }
    }

    public init(_ pattern: String, options: FindOptions) throws {
        guard !pattern.isEmpty else { throw Failure.empty }
        var source = options.regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if options.wholeWord { source = "\\b(?:\(source))\\b" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do {
            expression = try NSRegularExpression(pattern: source, options: flags)
        } catch {
            throw Failure.invalidPattern(error.localizedDescription)
        }
        self.options = options
    }

    /// All matches, in order, stopping at `limit`.
    public func matches(in text: String, range: NSRange? = nil, limit: Int = 50_000) -> [NSRange] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var result: [NSRange] = []
        expression.enumerateMatches(in: text, options: [], range: range ?? whole) { match, _, stop in
            guard let match else { return }
            result.append(match.range)
            if result.count >= limit { stop.pointee = true }
        }
        return result
    }

    private func template(_ replacement: String) -> String {
        options.regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// The text that would replace the match at `range`, with `$1`-style groups expanded in regex mode.
    public func replacement(in text: String, at range: NSRange, with replacement: String) -> String? {
        guard let match = expression.firstMatch(in: text, options: [.anchored], range: NSRange(location: range.location, length: (text as NSString).length - range.location)),
              match.range == range else { return nil }
        return expression.replacementString(for: match, in: text, offset: 0, template: template(replacement))
    }

    public func replaceAll(in text: String, range: NSRange? = nil, with replacement: String) -> (text: String, count: Int) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let target = range ?? whole
        let count = expression.numberOfMatches(in: text, options: [], range: target)
        guard count > 0 else { return (text, 0) }
        let result = expression.stringByReplacingMatches(in: text, options: [], range: target, withTemplate: template(replacement))
        return (result, count)
    }
}

public struct LineMatch: Identifiable, Sendable, Equatable {
    public var id: Int { range.location }
    /// 1-based.
    public var line: Int
    public var range: NSRange
    public var preview: String
    /// Range of the match inside `preview`, in UTF-16 units.
    public var previewRange: NSRange
}

public extension FindQuery {
    /// Matches with their line number and a one-line preview, for result lists.
    func lineMatches(in text: String, limit: Int = 2000) -> [LineMatch] {
        let ns = text as NSString
        let ranges = matches(in: text, limit: limit)
        var result: [LineMatch] = []
        var line = 1
        var cursor = 0
        for range in ranges {
            // Count newlines between the previous match and this one.
            if range.location > cursor {
                var i = cursor
                while i < range.location {
                    if ns.character(at: i) == 10 { line += 1 }
                    i += 1
                }
                cursor = range.location
            }
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var preview = ns.substring(with: lineRange)
            var offset = range.location - lineRange.location
            // Keep the match visible in long lines.
            if offset > 60 {
                let cut = offset - 40
                let safe = (preview as NSString).rangeOfComposedCharacterSequence(at: cut).location
                preview = "…" + (preview as NSString).substring(from: safe)
                offset = offset - safe + 1
            }
            let trimmed = preview.trimmingCharacters(in: .newlines)
            let capped = (trimmed as NSString).length > 240 ? (trimmed as NSString).substring(to: (trimmed as NSString).rangeOfComposedCharacterSequence(at: 240).location) : trimmed
            let length = max(0, min(range.length, (capped as NSString).length - offset))
            result.append(LineMatch(line: line, range: range, preview: capped, previewRange: NSRange(location: min(offset, (capped as NSString).length), length: length)))
        }
        return result
    }
}

public enum TextNavigation {
    /// UTF-16 offset of the start of a 1-based line, clamped to the text.
    public static func offset(ofLine line: Int, in text: String) -> Int {
        guard line > 1 else { return 0 }
        var current = 1
        var index = 0
        for unit in text.utf16 {
            index += 1
            if unit == 10 {
                current += 1
                if current == line { return index }
            }
        }
        return index
    }

    /// 1-based line and column (in characters) of a UTF-16 offset.
    public static func position(of offset: Int, in text: String) -> (line: Int, column: Int) {
        let ns = text as NSString
        let clamped = max(0, min(offset, ns.length))
        var line = 1
        var lineStart = 0
        var i = 0
        while i < clamped {
            if ns.character(at: i) == 10 {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        let column = ns.substring(with: NSRange(location: lineStart, length: clamped - lineStart)).count + 1
        return (line, column)
    }

    private static let pairs: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125]
    private static let reversePairs: [UInt16: UInt16] = [41: 40, 93: 91, 125: 123]

    /// The offset of the bracket matching the one at `offset`, scanning at most `limit` units.
    public static func matchingBracket(in text: NSString, at offset: Int, limit: Int = 200_000) -> Int? {
        guard offset >= 0, offset < text.length else { return nil }
        let c = text.character(at: offset)
        if let close = pairs[c] {
            var depth = 0
            var i = offset
            let end = min(text.length, offset + limit)
            while i < end {
                let d = text.character(at: i)
                if d == c { depth += 1 } else if d == close { depth -= 1; if depth == 0 { return i } }
                i += 1
            }
        } else if let open = reversePairs[c] {
            var depth = 0
            var i = offset
            let end = max(0, offset - limit)
            while i >= end {
                let d = text.character(at: i)
                if d == c { depth += 1 } else if d == open { depth -= 1; if depth == 0 { return i } }
                i -= 1
            }
        }
        return nil
    }
}
