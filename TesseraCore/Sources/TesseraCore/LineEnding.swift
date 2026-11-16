import Foundation

public enum LineEnding: String, CaseIterable, Identifiable, Sendable {
    case lf, crlf, cr

    public var id: String { rawValue }

    public var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    public var name: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    public var detail: String {
        switch self {
        case .lf: return "Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr: return "Classic Mac (CR)"
        }
    }

    public struct Counts: Equatable, Sendable {
        public var lf = 0, crlf = 0, cr = 0
        public var isMixed: Bool { [lf, crlf, cr].filter { $0 > 0 }.count > 1 }
    }

    public static func count(in text: String) -> Counts {
        var counts = Counts()
        var previousCR = false
        for unit in text.utf16 {
            if unit == 13 {
                if previousCR { counts.cr += 1 }
                previousCR = true
            } else {
                if unit == 10 {
                    if previousCR { counts.crlf += 1 } else { counts.lf += 1 }
                } else if previousCR {
                    counts.cr += 1
                }
                previousCR = false
            }
        }
        if previousCR { counts.cr += 1 }
        return counts
    }

    /// The most frequent line ending, or `fallback` for single-line text.
    public static func detect(in text: String, fallback: LineEnding = .lf) -> LineEnding {
        let c = count(in: text)
        if c.lf == 0, c.crlf == 0, c.cr == 0 { return fallback }
        if c.crlf >= c.lf, c.crlf >= c.cr { return .crlf }
        if c.lf >= c.cr { return .lf }
        return .cr
    }

    /// Rewrites every line ending as `\n`. The editor always works on this form.
    public static func normalize(_ text: String) -> String {
        guard text.utf16.contains(13) else { return text }
        var out = [UInt16]()
        out.reserveCapacity(text.utf16.count)
        var previousCR = false
        for unit in text.utf16 {
            if unit == 13 {
                if previousCR { out.append(10) }
                previousCR = true
                continue
            }
            if previousCR, unit != 10 { out.append(10) }
            previousCR = false
            out.append(unit)
        }
        if previousCR { out.append(10) }
        return String(decoding: out, as: UTF16.self)
    }

    /// Converts `\n`-normalized text to this line ending.
    public func apply(to normalized: String) -> String {
        self == .lf ? normalized : normalized.replacingOccurrences(of: "\n", with: sequence)
    }
}

public struct IndentStyle: Equatable, Sendable {
    public var usesTabs: Bool
    public var width: Int

    public init(usesTabs: Bool, width: Int) {
        self.usesTabs = usesTabs
        self.width = width
    }

    public var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }

    /// Guesses the indentation from the leading whitespace of the first few thousand lines.
    /// Returns nil when the text gives no evidence either way.
    public static func detect(in text: String, maxLines: Int = 4000) -> IndentStyle? {
        var tabLines = 0, spaceLines = 0
        var deltas: [Int: Int] = [:]
        var previous = 0
        var lines = 0
        text.enumerateLines { line, stop in
            lines += 1
            if lines > maxLines { stop = true; return }
            guard let first = line.utf16.first else { return }
            if first == 9 { tabLines += 1; previous = 0; return }
            var spaces = 0
            for unit in line.utf16 {
                if unit == 32 { spaces += 1 } else { break }
            }
            if spaces == line.utf16.count { return } // whitespace only
            if spaces > 0 { spaceLines += 1 }
            let delta = abs(spaces - previous)
            if delta > 1, delta <= 8 { deltas[delta, default: 0] += 1 }
            previous = spaces
        }
        if tabLines == 0, spaceLines == 0 { return nil }
        if tabLines > spaceLines { return IndentStyle(usesTabs: true, width: 4) }
        let best = deltas.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }
        return IndentStyle(usesTabs: false, width: best?.key ?? 4)
    }
}
