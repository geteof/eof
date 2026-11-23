#if DEBUG
import SwiftUI
import EOFCore

/// Launch arguments for checking screens in the simulator without tapping through the UI.
///
///     -open <path>      open a file (repeatable; paths are relative to the app's Documents folder)
///     -find <text>      show the find bar with this query (-replace also shows the replace row)
///     -preview          show the Markdown / HTML preview
///     -sidebyside       show the source and the preview side by side (wide windows)
///     -sheet <name>     outline | statistics | compare | language
///     -line <n>         put the caret on this line
///     -readonly         open in read-only mode
///     -split <path>     open a file in the second pane
///     -selftest         drive the editor through its commands and write Documents/selftest.txt
///     -sidebar          show the sidebar once the files have loaded (the sidebar page when narrow)
///     -layoutreport     write window, safe-area and bar geometry to Documents/layout.txt
enum DebugLaunch {
    private static let arguments = ProcessInfo.processInfo.arguments
    private static var consumed = false

    static var isActive: Bool { arguments.contains("-open") }

    static var showsSidebar: Bool { arguments.contains("-sidebar") }

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
        for path in values("-open") { model.open(resolve(path)) }
        // Loading is serial, so the split document arrives after the first pane has one.
        for path in values("-split") { model.open(resolve(path), pane: .secondary) }
    }

    static func apply(to document: EditorDocument, showFind: inout Bool, findWithReplace: inout Bool, viewMode: inout ViewMode, sheet: inout EditorSheet?) {
        guard isActive, !consumed else { return }
        // Only the last file given is decorated; earlier ones just fill the tab strip.
        guard let last = values("-open").last, document.url?.lastPathComponent == resolve(last).lastPathComponent else { return }
        consumed = true
        if arguments.contains("-readonly") { document.userReadOnly = true }
        if arguments.contains("-preview") { viewMode = .preview }
        if arguments.contains("-sidebyside") { viewMode = .sideBySide }
        if let name = values("-sheet").first { sheet = EditorSheet(rawValue: name) }
        if let line = values("-line").first.flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { document.controller.goToLine(line) }
        }
        if arguments.contains("-layoutreport") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { layoutReport(document) }
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

        // A syntax node at the start proves the grammar loaded and parsed the text.
        lines.append("syntaxNode=\(editor.textView.syntaxNode(at: 0)?.type ?? "nil")")
        lines.append("language=\(document.language.id) grammar=\(Grammars.hasGrammar(for: document.language)) indent=\(document.indent.usesTabs ? "tabs" : "spaces")\(document.indent.width)")
        let failures = lines.filter { $0.hasPrefix("FAIL") }.count
        lines.append("RESULT \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.txt")
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}

extension DebugLaunch {
    /// Describes how the system laid the window out: needed for displays this code cannot be seen on.
    static func layoutReport(_ document: EditorDocument) {
        var lines: [String] = []
        let editor = document.controller.view
        func rect(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }
        func insets(_ i: UIEdgeInsets) -> String { "top=\(Int(i.top)) left=\(Int(i.left)) bottom=\(Int(i.bottom)) right=\(Int(i.right))" }
        // A binary document (PDF, image) has no editor view on screen; use the app's key window.
        let keyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        if let window = editor.window ?? keyWindow {
            let screen = window.screen
            lines.append("statusBar hidden=\(window.windowScene?.statusBarManager?.isStatusBarHidden ?? false) rootPrefersHidden=\(window.rootViewController?.prefersStatusBarHidden ?? false)")
            lines.append("screen bounds=\(rect(screen.bounds)) nativeBounds=\(rect(screen.nativeBounds)) scale=\(screen.scale)")
            lines.append("window bounds=\(rect(window.bounds)) frame=\(rect(window.frame)) safeArea \(insets(window.safeAreaInsets))")
            if let scene = window.windowScene {
                lines.append("scene orientation=\(scene.interfaceOrientation.rawValue) (1 portrait, 2 upsideDown, 3 landscapeLeft, 4 landscapeRight) statusBarFrame=\(rect(scene.statusBarManager?.statusBarFrame ?? .zero)) sceneBounds=\(rect(scene.coordinateSpace.bounds))")
            }
            let traits = window.traitCollection
            lines.append("traits horizontal=\(traits.horizontalSizeClass.rawValue) vertical=\(traits.verticalSizeClass.rawValue) (1 compact, 2 regular) idiom=\(traits.userInterfaceIdiom.rawValue) (0 phone, 1 pad)")
            lines.append("editor frameInWindow=\(rect(editor.convert(editor.bounds, to: window))) safeArea \(insets(editor.safeAreaInsets))")
            if let root = window.rootViewController?.view {
                lines.append("root frame=\(rect(root.frame)) safeArea \(insets(root.safeAreaInsets)) transform=\(root.transform)")
            }
            // Bars and other chrome, with where they sit in the window.
            var count = 0
            func walk(_ view: UIView, depth: Int) {
                guard count < 120, depth < 14 else { return }
                let name = String(describing: type(of: view))
                let interesting = view is UINavigationBar || view is UIToolbar || view is UITabBar || name.contains("Bar") || name.contains("Toolbar") || name.contains("Glass") || name.contains("Platter") || name.contains("Button") || name.contains("Sidebar")
                if interesting, !view.isHidden, view.bounds.width > 0 {
                    count += 1
                    lines.append("\(String(repeating: " ", count: min(depth, 8)))\(name) \(rect(view.convert(view.bounds, to: window))) alpha=\(view.alpha)")
                }
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
            walk(window, depth: 0)
            for other in window.windowScene?.windows ?? [] where other !== window {
                lines.append("other window \(String(describing: type(of: other))) frame=\(rect(other.frame)) level=\(other.windowLevel.rawValue) hidden=\(other.isHidden)")
            }
        } else {
            lines.append("editor view is not in a window")
        }
        lines.append("bar changes: " + (BarVisibility.log.isEmpty ? "none" : BarVisibility.log.joined(separator: " | ")))
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("layout.txt")
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}

extension Notification.Name {
    static let debugFindQuery = Notification.Name("EOFDebugFindQuery")
}
#endif
