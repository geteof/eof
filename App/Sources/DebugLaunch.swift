#if DEBUG
import SwiftUI

/// Launch arguments for checking screens in the simulator without tapping through the UI.
///
///     -open <path>      open a file (repeatable; paths are relative to the app's Documents folder)
///     -folder <path>    open a folder as the project
///     -find <text>      show the find bar with this query (-replace also shows the replace row)
///     -preview          show the Markdown / HTML preview
///     -sheet <name>     outline | statistics | compare | language
///     -line <n>         put the caret on this line
///     -readonly         open in read-only mode
///     -selftest         drive the editor through its commands and write Documents/selftest.txt
enum DebugLaunch {
    private static let arguments = ProcessInfo.processInfo.arguments
    private static var consumed = false

    static var isActive: Bool { arguments.contains("-open") || arguments.contains("-folder") }

    private static func values(_ flag: String) -> [String] {
        arguments.indices.compactMap { index in
            arguments[index] == flag && index + 1 < arguments.count ? arguments[index + 1] : nil
        }
    }

    private static func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
    }

    static func open(in model: AppModel) {
        if let folder = values("-folder").first { model.openFolder(resolve(folder)) }
        for path in values("-open") { model.open(resolve(path)) }
    }

    static func apply(to document: EditorDocument, showFind: inout Bool, findWithReplace: inout Bool, showPreview: inout Bool, sheet: inout EditorSheet?) {
        guard isActive, !consumed else { return }
        // Only the last file given is decorated; earlier ones just fill the tab strip.
        guard let last = values("-open").last, document.url?.lastPathComponent == resolve(last).lastPathComponent else { return }
        consumed = true
        if arguments.contains("-readonly") { document.userReadOnly = true }
        if arguments.contains("-preview") { showPreview = true }
        if let name = values("-sheet").first { sheet = EditorSheet(rawValue: name) }
        if let line = values("-line").first.flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { document.controller.goToLine(line) }
        }
        if arguments.contains("-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { selfTest(document) }
        }
        if let query = values("-find").first {
            findWithReplace = arguments.contains("-replace")
            showFind = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NotificationCenter.default.post(name: .debugFindQuery, object: query)
            }
        }
    }
}

extension DebugLaunch {
    /// Exercises the editor commands the way menus and the keyboard bar call them, then writes one
    /// PASS/FAIL line per check. Everything is undone at the end.
    static func selfTest(_ document: EditorDocument) {
        let editor = document.controller
        var lines: [String] = []
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            lines.append(passed ? "PASS \(name)" : "FAIL \(name) \(detail())")
        }
        func head(_ count: Int = 24) -> String {
            String(editor.text.prefix(count)).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        }
        let original = editor.text
        let unit = document.indent.unit

        check("length", editor.length == (original as NSString).length, "\(editor.length)")
        editor.select(NSRange(location: 0, length: 0))
        editor.insert("X")
        check("insert", editor.text == "X" + original, head())
        check("dirty", document.isDirty)
        editor.undo()
        check("undo", editor.text == original, head())
        editor.redo()
        check("redo", editor.text == "X" + original, head())
        editor.undo()

        editor.replace(NSRange(location: 0, length: 0), with: "ab\ncd\n")
        check("replace", editor.text.hasPrefix("ab\ncd\n"), head())
        editor.goToLine(2, column: 2)
        check("goToLine", editor.selectedRange == NSRange(location: 4, length: 0), "\(editor.selectedRange)")
        check("status", document.status.line == 2 && document.status.column == 2, "\(document.status.line):\(document.status.column)")
        check("lineCount", editor.lineCount == original.components(separatedBy: "\n").count + 2, "\(editor.lineCount)")

        if let prefix = document.language.commentPrefix?.trimmingCharacters(in: .whitespaces) {
            editor.toggleComment()
            check("comment", editor.text.hasPrefix("ab\n\(prefix) cd\n"), head())
            editor.toggleComment()
            check("uncomment", editor.text.hasPrefix("ab\ncd\n"), head())
        }

        editor.select(NSRange(location: 0, length: 5))
        editor.indentSelection()
        check("indent", editor.text.hasPrefix(unit + "ab\n" + unit + "cd\n"), head())
        editor.outdentSelection()
        check("outdent", editor.text.hasPrefix("ab\ncd\n"), head())

        editor.goToLine(1)
        editor.duplicateLine()
        check("duplicateLine", editor.text.hasPrefix("ab\nab\ncd\n"), head())
        editor.deleteLine()
        check("deleteLine", editor.text.hasPrefix("ab\ncd\n"), head())
        editor.goToLine(1)
        editor.moveLinesDown()
        check("moveLineDown", editor.text.hasPrefix("cd\nab\n"), head())
        editor.moveLinesUp()
        check("moveLineUp", editor.text.hasPrefix("ab\ncd\n"), head())

        editor.select(NSRange(location: 0, length: 2))
        check("selectedText", editor.selectedText == "ab", editor.selectedText)
        do {
            try editor.apply(.uppercase)
            check("transform", editor.text.hasPrefix("AB\ncd\n"), head())
        } catch {
            check("transform", false, "\(error)")
        }

        editor.select(NSRange(location: 0, length: 0))
        editor.insert("(")
        check("bracketPair", editor.text.hasPrefix("()AB"), head())
        editor.select(NSRange(location: 0, length: 0))
        editor.insert("\t")
        check("tab", editor.text.hasPrefix(unit + "()AB"), head())
        editor.moveCaret(by: 1)
        check("moveCaret", editor.selectedRange.location == (unit as NSString).length + 1, "\(editor.selectedRange)")

        editor.setFindMatches([NSRange(location: 0, length: 2), NSRange(location: 4, length: 1)], current: NSRange(location: 0, length: 2))
        check("findHighlights", editor.textView.highlightedRanges.count >= 2, "\(editor.textView.highlightedRanges.count)")
        editor.setFindMatches([], current: nil)

        var steps = 0
        while editor.canUndo, steps < 300 {
            editor.undo()
            steps += 1
        }
        check("undoAll", editor.text == original, "steps=\(steps) \(head())")

        lines.append("language=\(document.language.id) grammar=\(Grammars.hasGrammar(for: document.language)) indent=\(document.indent.usesTabs ? "tabs" : "spaces")\(document.indent.width)")
        let failures = lines.filter { $0.hasPrefix("FAIL") }.count
        lines.append("RESULT \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.txt")
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}

extension Notification.Name {
    static let debugFindQuery = Notification.Name("EOFDebugFindQuery")
}
#endif
