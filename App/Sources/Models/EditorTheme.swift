import SwiftUI
import UIKit

/// The colour roles a theme defines. Tree-sitter highlight names are folded into these.
enum HighlightKind: CaseIterable {
    case comment, string, number, keyword, type, function, constant, variable, tag, attribute, meta, heading, emphasis, link, inserted, deleted

    /// Maps a capture name from a highlights query, such as `function.method` or `text.title`.
    /// Returns nil for names that keep the plain text colour (operators, punctuation, variables).
    static func named(_ highlightName: String) -> HighlightKind? {
        if let exact = exactNames[highlightName] { return exact }
        var parts = highlightName.split(separator: ".")
        while !parts.isEmpty {
            if let hit = prefixes[parts.joined(separator: ".")] { return hit }
            parts.removeLast()
        }
        return nil
    }

    private static let exactNames: [String: HighlightKind] = [
        "variable.builtin": .constant, "variable.parameter": .variable, "variable.member": .attribute,
        "string.escape": .constant, "string.special.key": .attribute, "string.special.uri": .link, "string.special.symbol": .constant,
        "tag.attribute": .attribute, "punctuation.special": .meta, "keyword.directive": .meta,
        "text.title": .heading, "text.strong": .emphasis, "text.emphasis": .emphasis, "text.strike": .comment,
        "text.uri": .link, "text.reference": .link, "text.literal": .string, "text.math": .number,
        "text.environment": .keyword, "text.environment.name": .type, "text.warning": .deleted, "text.danger": .deleted,
        "diff.plus": .inserted, "diff.minus": .deleted, "diff.delta": .meta,
    ]

    private static let prefixes: [String: HighlightKind] = [
        "comment": .comment, "string": .string, "character": .string, "escape": .constant,
        "number": .number, "float": .number, "boolean": .constant, "constant": .constant,
        "keyword": .keyword, "conditional": .keyword, "repeat": .keyword, "include": .keyword, "import": .keyword,
        "exception": .keyword, "storageclass": .keyword, "define": .meta, "preproc": .meta, "macro": .meta,
        "type": .type, "constructor": .type, "interface": .type, "namespace": .type, "module": .type,
        "function": .function, "method": .function,
        "property": .attribute, "field": .attribute, "attribute": .attribute, "parameter": .variable,
        "tag": .tag, "label": .meta, "markup": .heading, "title": .heading, "selector": .tag,
    ]
}

struct EditorTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let background: UIColor
    let foreground: UIColor
    let gutterForeground: UIColor
    let currentLine: UIColor
    let selection: UIColor
    let findMatch: UIColor
    let bracketMatch: UIColor
    let invisibles: UIColor
    let colors: [HighlightKind: UIColor]

    static func == (lhs: EditorTheme, rhs: EditorTheme) -> Bool { lhs.id == rhs.id }

    func color(for kind: HighlightKind) -> UIColor { colors[kind] ?? foreground }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// Builds a theme from eight accents; the rest is derived so every theme stays consistent.
    private static func make(
        _ id: String, _ name: String, dark: Bool, bg: UInt32, fg: UInt32, muted: UInt32, line: UInt32, selection: UInt32,
        comment: UInt32, string: UInt32, number: UInt32, keyword: UInt32, type: UInt32, function: UInt32, constant: UInt32, tag: UInt32, attribute: UInt32,
        inserted: UInt32, deleted: UInt32
    ) -> EditorTheme {
        EditorTheme(
            id: id, name: name, isDark: dark,
            background: hex(bg), foreground: hex(fg), gutterForeground: hex(muted), currentLine: hex(line), selection: hex(selection),
            findMatch: hex(dark ? 0xE5B800 : 0xFFD60A, alpha: dark ? 0.38 : 0.5),
            bracketMatch: hex(dark ? 0x7FB4FF : 0x0A84FF, alpha: 0.28),
            invisibles: hex(muted, alpha: 0.55),
            colors: [
                .comment: hex(comment), .string: hex(string), .number: hex(number), .keyword: hex(keyword), .type: hex(type),
                .function: hex(function), .constant: hex(constant), .variable: hex(attribute), .tag: hex(tag), .attribute: hex(attribute),
                .meta: hex(constant), .heading: hex(keyword), .emphasis: hex(number), .link: hex(function),
                .inserted: hex(inserted), .deleted: hex(deleted),
            ]
        )
    }

    static let paper = make("paper", "Paper", dark: false, bg: 0xFFFFFF, fg: 0x1F2328, muted: 0x9AA1AA, line: 0xF3F5F8, selection: 0xB4D8FD,
                            comment: 0x7A828C, string: 0xB3401E, number: 0x1A5FB4, keyword: 0x9B2393, type: 0x0B6E75, function: 0x3A4FC4, constant: 0x8250DF, tag: 0x116329, attribute: 0x945A00,
                            inserted: 0x1A7F37, deleted: 0xCF222E)
    static let midnight = make("midnight", "Midnight", dark: true, bg: 0x16181D, fg: 0xDCDFE4, muted: 0x5E6673, line: 0x1F232B, selection: 0x2F4A6B,
                               comment: 0x7B8494, string: 0xF28B6E, number: 0xE2C16B, keyword: 0xE873B8, type: 0x64D2C8, function: 0x7FB4FF, constant: 0xB79CFF, tag: 0x8FD46E, attribute: 0xE5B567,
                               inserted: 0x7EE08A, deleted: 0xFF7B72)
    static let sand = make("sand", "Sand", dark: false, bg: 0xFAF6EC, fg: 0x3B3A36, muted: 0xA8A292, line: 0xF1EBDC, selection: 0xE3D7B8,
                           comment: 0x8C8676, string: 0x4E7A27, number: 0xB3531B, keyword: 0xB02A5B, type: 0x23708C, function: 0x3855B3, constant: 0x7C4DBB, tag: 0x23708C, attribute: 0x8F5E00,
                           inserted: 0x4E7A27, deleted: 0xB3261E)
    static let solarizedLight = make("solarized-light", "Solarized Light", dark: false, bg: 0xFDF6E3, fg: 0x586E75, muted: 0x93A1A1, line: 0xEEE8D5, selection: 0xD9D2BC,
                                     comment: 0x93A1A1, string: 0x2AA198, number: 0xD33682, keyword: 0x859900, type: 0xB58900, function: 0x268BD2, constant: 0xCB4B16, tag: 0x268BD2, attribute: 0x6C71C4,
                                     inserted: 0x859900, deleted: 0xDC322F)
    static let solarizedDark = make("solarized-dark", "Solarized Dark", dark: true, bg: 0x002B36, fg: 0x93A1A1, muted: 0x586E75, line: 0x073642, selection: 0x174652,
                                    comment: 0x657B83, string: 0x2AA198, number: 0xD33682, keyword: 0x859900, type: 0xB58900, function: 0x268BD2, constant: 0xCB4B16, tag: 0x268BD2, attribute: 0x6C71C4,
                                    inserted: 0x859900, deleted: 0xDC322F)
    static let ember = make("ember", "Ember", dark: true, bg: 0x211D1B, fg: 0xE8DFD4, muted: 0x766A60, line: 0x2B2623, selection: 0x4A3B30,
                            comment: 0x8A7D70, string: 0xE6C07B, number: 0xB48EFF, keyword: 0xFF6F7D, type: 0x7FD4E0, function: 0xA6DB6C, constant: 0xB48EFF, tag: 0xFF6F7D, attribute: 0xFFA657,
                            inserted: 0xA6DB6C, deleted: 0xFF6F7D)
    static let frost = make("frost", "Frost", dark: true, bg: 0x2B303B, fg: 0xD8DEE9, muted: 0x66708A, line: 0x333947, selection: 0x44506A,
                            comment: 0x7B869E, string: 0xA3BE8C, number: 0xC59AC0, keyword: 0x81A1C1, type: 0x8FBCBB, function: 0x88C0D0, constant: 0xC59AC0, tag: 0x81A1C1, attribute: 0xEBCB8B,
                            inserted: 0xA3BE8C, deleted: 0xD0707A)
    static let ink = make("ink", "Ink", dark: true, bg: 0x000000, fg: 0xE6E6E6, muted: 0x5A5A5E, line: 0x121214, selection: 0x263F5F,
                          comment: 0x7D7D85, string: 0xFF9F6B, number: 0xFFD76B, keyword: 0xFF7AB2, type: 0x6BDFD0, function: 0x6CB6FF, constant: 0xC6A0FF, tag: 0x9BE077, attribute: 0xF0B866,
                          inserted: 0x7EE08A, deleted: 0xFF7B72)

    static let all: [EditorTheme] = [paper, sand, solarizedLight, midnight, frost, ember, solarizedDark, ink]
    static let light = all.filter { !$0.isDark }
    static let dark = all.filter { $0.isDark }

    static func named(_ id: String, fallback: EditorTheme) -> EditorTheme {
        all.first { $0.id == id } ?? fallback
    }
}
