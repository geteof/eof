import XCTest
@testable import EOFCore

final class LanguageTests: XCTestCase {
    func testDetectByExtensionAndName() {
        let cases: [(String, String)] = [
            ("main.swift", "swift"), ("a/b/app.TSX", "typescript"), ("index.html", "html"), ("x.yml", "yaml"),
            ("Dockerfile", "dockerfile"), ("Dockerfile.prod", "dockerfile"), ("Makefile", "makefile"),
            (".gitignore", "gitignore"), (".env", "ini"), (".env.local", "ini"), ("Cargo.toml", "toml"),
            ("package.json", "json"), ("notes.md", "markdown"), ("README", "markdown"), ("a.patch", "diff"),
            ("style.scss", "scss"), ("query.sql", "sql"), ("x.kt", "kotlin"), ("x.rs", "rust"), ("x.go", "go"),
            ("x.py", "python"), ("x.rb", "ruby"), ("x.php", "php"), ("x.cs", "csharp"), ("x.java", "java"),
            ("x.mm", "objc"), ("x.hpp", "cpp"), ("x.c", "c"), ("x.lua", "lua"), ("x.sh", "shell"),
            (".zshrc", "shell"), ("x.xml", "xml"), ("Info.plist", "xml"), ("x.ini", "ini"), ("x.css", "css"),
            ("x.js", "javascript"), ("types.d.ts", "typescript"), ("CMakeLists.txt", "cmake"), ("unknown.zzz", "plain"), ("noext", "plain"),
        ]
        for (name, id) in cases {
            XCTAssertEqual(Languages.detect(filename: name).id, id, name)
        }
    }

    func testDetectByShebang() {
        XCTAssertEqual(Languages.detect(filename: "run", firstLine: "#!/usr/bin/env python3").id, "python")
        XCTAssertEqual(Languages.detect(filename: "run", firstLine: "#!/bin/bash -e").id, "shell")
        XCTAssertEqual(Languages.detect(filename: "run", firstLine: "#!/usr/bin/env -S node --flag").id, "javascript")
        XCTAssertEqual(Languages.detect(filename: "run", firstLine: "#!/usr/local/bin/ruby").id, "ruby")
        XCTAssertEqual(Languages.detect(filename: "page", firstLine: "<!DOCTYPE html>").id, "html")
        XCTAssertEqual(Languages.detect(filename: "run", firstLine: "hello").id, "plain")
    }

    func testLanguageIDsAreUnique() {
        XCTAssertEqual(Set(Languages.all.map(\.id)).count, Languages.all.count)
    }
}

final class EncodingTests: XCTestCase {
    func testUTF8AndBOMRoundTrip() throws {
        let text = "héllo 世界 😀\n"
        for encoding in [TextEncoding.utf8, .utf8BOM, .utf16LE, .utf16BE, .utf32LE, .utf32BE] {
            let data = try XCTUnwrap(encoding.encode(text), encoding.id)
            let detected = try XCTUnwrap(TextEncoding.detect(data), encoding.id)
            XCTAssertEqual(detected.text, text, encoding.id)
            XCTAssertEqual(detected.encoding, encoding, encoding.id)
            XCTAssertEqual(encoding.encode(detected.text), data, encoding.id)
        }
    }

    func testBOMBytes() throws {
        XCTAssertEqual(Array(try XCTUnwrap(TextEncoding.utf8BOM.encode("a"))), [0xEF, 0xBB, 0xBF, 0x61])
        XCTAssertEqual(Array(try XCTUnwrap(TextEncoding.utf16LE.encode("a"))), [0xFF, 0xFE, 0x61, 0x00])
        XCTAssertEqual(Array(try XCTUnwrap(TextEncoding.utf16BE.encode("a"))), [0xFE, 0xFF, 0x00, 0x61])
        XCTAssertEqual(Array(try XCTUnwrap(TextEncoding.utf8.encode("a"))), [0x61])
    }

    func testUTF16WithoutBOM() throws {
        let data = try XCTUnwrap("plain ascii text in utf16\n".data(using: .utf16LittleEndian))
        let detected = try XCTUnwrap(TextEncoding.detect(data))
        XCTAssertEqual(detected.encoding, .utf16LENoBOM)
        XCTAssertEqual(detected.text, "plain ascii text in utf16\n")
    }

    func testBinaryIsRejected() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 0, 1, 0, 0, 0, 1, 0, 8, 6, 0, 0, 0, 0x5C])
        XCTAssertTrue(TextEncoding.looksBinary(png))
        XCTAssertNil(TextEncoding.detect(png))
        XCTAssertFalse(TextEncoding.looksBinary(Data("hello\n".utf8)))
        XCTAssertEqual(TextEncoding.detect(Data())?.text, "")
    }

    func testLatin1Fallback() throws {
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café\n" in Latin 1 / CP1252
        let detected = try XCTUnwrap(TextEncoding.detect(data))
        XCTAssertEqual(detected.text, "café\n")
        XCTAssertEqual(detected.encoding.encode(detected.text), data)
    }

    func testEncodeRejectsUnrepresentable() {
        XCTAssertNil(TextEncoding.ascii.encode("世界"))
        XCTAssertNil(TextEncoding.latin1.encode("世界"))
    }

    #if canImport(Darwin)
    /// Legacy encodings are detected by Foundation, which only does this on Apple platforms.
    func testLegacyEncodingDetection() throws {
        let samples: [(String, TextEncoding, String)] = [
            ("zh-long", .gb18030, "这是一个简体中文的文本文件，用来测试编码检测。\n第二行内容。\n"),
            ("zh-short", .gb18030, "不成，把大家都叫出来。\n"),
            ("zh-tiny", .gb18030, "你好\n"),
            ("zh-mixed", .gb18030, "name = 张三 # 用户名\nport = 8080\n"),
            ("tw-long", .big5, "這是一個繁體中文的文字檔案，用來測試編碼偵測。\n"),
            ("tw-short", .big5, "請問您的大名\n"),
            ("ja-sjis", .shiftJIS, "これは日本語のテキストファイルです。エンコードのテスト。\n"),
            ("ja-sjis-kanji", .shiftJIS, "東京都渋谷区\n"),
            ("ja-euc", .eucJP, "これは日本語のテキストファイルです。漢字も少し含みます。\n"),
            ("ko-long", .eucKR, "이것은 한국어 텍스트 파일입니다. 인코딩 테스트.\n"),
            ("ko-short", .eucKR, "안녕하세요\n"),
            ("latin1", .latin1, "café déjà vu naïve façade\n"),
            ("cp1252", .windows1252, "“smart quotes” — and a dash…\n"),
            ("cp1251", .windows1251, "Привет, это текстовый файл.\n"),
        ]
        for (label, encoding, text) in samples {
            let data = try XCTUnwrap(encoding.encode(text), label)
            let detected = try XCTUnwrap(TextEncoding.detect(data), label)
            XCTAssertEqual(detected.text, text, "\(label): detected \(detected.encoding.id)")
            // Saving with the detected encoding must give back the original bytes.
            XCTAssertEqual(detected.encoding.encode(detected.text), data, label)
        }
    }

    func testLegacyDetectionOfLargeInput() throws {
        let line = "这是一行用来填充的简体中文文本，后面还有很多行。\n"
        let data = try XCTUnwrap(TextEncoding.gb18030.encode(String(repeating: line, count: 12_000)))
        XCTAssertGreaterThan(data.count, 500_000)
        let detected = try XCTUnwrap(TextEncoding.detect(data))
        XCTAssertEqual(detected.encoding, .gb18030)
        XCTAssertTrue(detected.text.hasPrefix(line))
    }

    func testLegacyCJKRoundTrip() throws {
        let samples: [(TextEncoding, String)] = [
            (.gb18030, "这是一个简体中文的文本文件，用来测试编码检测。\n第二行内容。\n"),
            (.big5, "這是一個繁體中文的文字檔案，用來測試編碼偵測。\n"),
            (.shiftJIS, "これは日本語のテキストファイルです。エンコードのテスト。\n"),
            (.eucKR, "이것은 한국어 텍스트 파일입니다. 인코딩 테스트.\n"),
            (.eucJP, "これは日本語のテキストファイルです。漢字も少し含みます。\n"),
        ]
        for (encoding, text) in samples {
            let data = try XCTUnwrap(encoding.encode(text), encoding.id)
            XCTAssertEqual(encoding.decode(data), text, encoding.id)
            let detected = try XCTUnwrap(TextEncoding.detect(data), encoding.id)
            XCTAssertEqual(detected.text, text, "detected \(detected.encoding.id) for \(encoding.id)")
        }
    }
    #endif
}

final class LineEndingTests: XCTestCase {
    func testDetectAndRoundTrip() {
        let lf = "a\nb\nc\n"
        for ending in LineEnding.allCases {
            let raw = ending.apply(to: lf)
            XCTAssertEqual(LineEnding.detect(in: raw), ending)
            XCTAssertEqual(LineEnding.normalize(raw), lf)
            XCTAssertEqual(ending.apply(to: LineEnding.normalize(raw)), raw)
        }
        XCTAssertEqual(LineEnding.detect(in: "no newline", fallback: .crlf), .crlf)
    }

    func testMixed() {
        let counts = LineEnding.count(in: "a\r\nb\nc\rd\r")
        XCTAssertEqual(counts, LineEnding.Counts(lf: 1, crlf: 1, cr: 2))
        XCTAssertTrue(counts.isMixed)
        XCTAssertEqual(LineEnding.normalize("a\r\nb\nc\rd\r"), "a\nb\nc\nd\n")
        XCTAssertEqual(LineEnding.normalize("a\r\r\nb"), "a\n\nb")
    }

    func testIndentDetection() {
        XCTAssertEqual(IndentStyle.detect(in: "a:\n  b:\n    c: 1\n  d: 2\n"), IndentStyle(usesTabs: false, width: 2))
        XCTAssertEqual(IndentStyle.detect(in: "if x {\n    y()\n    if z {\n        w()\n    }\n}\n"), IndentStyle(usesTabs: false, width: 4))
        XCTAssertEqual(IndentStyle.detect(in: "a {\n\tb\n\t\tc\n}\n")?.usesTabs, true)
        XCTAssertNil(IndentStyle.detect(in: "flat\ntext\n"))
        XCTAssertNil(IndentStyle.detect(in: ""))
    }
}

final class FindTests: XCTestCase {
    func testPlainCaseAndWholeWord() throws {
        let text = "Cat cat concat CAT"
        XCTAssertEqual(try FindQuery("cat", options: .init()).matches(in: text).count, 4)
        XCTAssertEqual(try FindQuery("cat", options: .init(caseSensitive: true)).matches(in: text).count, 2)
        XCTAssertEqual(try FindQuery("cat", options: .init(wholeWord: true)).matches(in: text).count, 3)
        XCTAssertEqual(try FindQuery("cat", options: .init(caseSensitive: true, wholeWord: true)).matches(in: text).map(\.location), [4])
    }

    func testPlainTextIsNotARegex() throws {
        let text = "a.b a+b (x) $1"
        XCTAssertEqual(try FindQuery("a.b", options: .init()).matches(in: text).count, 1)
        XCTAssertEqual(try FindQuery("(x)", options: .init()).matches(in: text).count, 1)
        let replaced = try FindQuery("a+b", options: .init()).replaceAll(in: text, with: "$0\\n")
        XCTAssertEqual(replaced.text, "a.b $0\\n (x) $1")
        XCTAssertEqual(replaced.count, 1)
    }

    func testRegexWithGroups() throws {
        let query = try FindQuery("(\\w+)@(\\w+)\\.com", options: .init(regex: true))
        let text = "bob@site.com, amy@corp.com"
        let result = query.replaceAll(in: text, with: "$2:$1")
        XCTAssertEqual(result.text, "site:bob, corp:amy")
        XCTAssertEqual(result.count, 2)
        let first = query.matches(in: text)[0]
        XCTAssertEqual(query.replacement(in: text, at: first, with: "<$1>"), "<bob>")
        XCTAssertNil(query.replacement(in: text, at: NSRange(location: 1, length: 3), with: "x"))
    }

    func testAnchorsMatchLinesAndUnicode() throws {
        let text = "one\ntwo 😀\nthree"
        XCTAssertEqual(try FindQuery("^t", options: .init(regex: true)).matches(in: text).count, 2)
        let match = try FindQuery("😀", options: .init()).matches(in: text)
        XCTAssertEqual(match, [NSRange(location: 8, length: 2)])
    }

    func testInvalidRegexThrows() {
        XCTAssertThrowsError(try FindQuery("(", options: .init(regex: true)))
        XCTAssertThrowsError(try FindQuery("", options: .init()))
    }

    func testLineMatches() throws {
        let hits = try FindQuery("b", options: .init()).lineMatches(in: "a\nxbx\n\nb")
        XCTAssertEqual(hits.map(\.line), [2, 4])
        XCTAssertEqual(hits[0].preview, "xbx")
        XCTAssertEqual(hits[0].previewRange, NSRange(location: 1, length: 1))
    }

    func testNavigation() {
        let text = "ab\ncd\n\nef"
        XCTAssertEqual(TextNavigation.offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(TextNavigation.offset(ofLine: 2, in: text), 3)
        XCTAssertEqual(TextNavigation.offset(ofLine: 4, in: text), 7)
        XCTAssertEqual(TextNavigation.offset(ofLine: 99, in: text), 9)
        XCTAssertTrue(TextNavigation.position(of: 4, in: text) == (2, 2))
        XCTAssertTrue(TextNavigation.position(of: 0, in: text) == (1, 1))
        XCTAssertEqual(TextNavigation.matchingBracket(in: "f(a[1]{x})" as NSString, at: 1), 9)
        XCTAssertEqual(TextNavigation.matchingBracket(in: "f(a[1]{x})" as NSString, at: 9), 1)
        XCTAssertEqual(TextNavigation.matchingBracket(in: "f(a[1]{x})" as NSString, at: 3), 5)
        XCTAssertNil(TextNavigation.matchingBracket(in: "(((" as NSString, at: 0))
    }
}

final class TransformTests: XCTestCase {
    func testCase() throws {
        XCTAssertEqual(try TextTransform.uppercase.apply(to: "aBc"), "ABC")
        XCTAssertEqual(try TextTransform.lowercase.apply(to: "aBc"), "abc")
        XCTAssertEqual(try TextTransform.titleCase.apply(to: "hello world"), "Hello World")
    }

    func testLines() throws {
        XCTAssertEqual(try TextTransform.sortAscending.apply(to: "b\na\nC\n"), "a\nb\nC\n")
        XCTAssertEqual(try TextTransform.sortAscending.apply(to: "item10\nitem2"), "item2\nitem10")
        XCTAssertEqual(try TextTransform.sortDescending.apply(to: "a\nc\nb"), "c\nb\na")
        XCTAssertEqual(try TextTransform.sortNumeric.apply(to: "10 x\n9 y\n-1 z"), "-1 z\n9 y\n10 x")
        XCTAssertEqual(try TextTransform.reverseLines.apply(to: "1\n2\n3\n"), "3\n2\n1\n")
        XCTAssertEqual(try TextTransform.removeDuplicateLines.apply(to: "a\nb\na\nb\nc"), "a\nb\nc")
        XCTAssertEqual(try TextTransform.removeBlankLines.apply(to: "a\n\n  \nb\n"), "a\nb\n")
        XCTAssertEqual(try TextTransform.joinLines.apply(to: "a\n  b\n\nc\n"), "a b c")
    }

    func testWhitespace() throws {
        XCTAssertEqual(try TextTransform.trimTrailingWhitespace.apply(to: "a  \nb\t\n  c"), "a\nb\n  c")
        XCTAssertEqual(try TextTransform.tabsToSpaces.apply(to: "\ta\tb", indentWidth: 4), "    a   b")
        XCTAssertEqual(try TextTransform.spacesToTabs.apply(to: "        a  b\n  c", indentWidth: 4), "\t\ta  b\n  c")
    }

    func testEncodings() throws {
        XCTAssertEqual(try TextTransform.base64Encode.apply(to: "héllo"), "aMOpbGxv")
        XCTAssertEqual(try TextTransform.base64Decode.apply(to: "aMOp\nbGxv"), "héllo")
        XCTAssertThrowsError(try TextTransform.base64Decode.apply(to: "!!!"))
        XCTAssertEqual(try TextTransform.urlEncode.apply(to: "a b&c=中"), "a%20b%26c%3D%E4%B8%AD")
        XCTAssertEqual(try TextTransform.urlDecode.apply(to: "a%20b+c%3D%E4%B8%AD"), "a b c=中")
    }

    func testJSON() throws {
        let source = "{\"b\":1,\"a\":[1.50,true,{}],\"s\":\"x: {y}, [z]\",\"e\":[]}"
        let pretty = try TextTransform.jsonPretty.apply(to: source, indentWidth: 2)
        XCTAssertEqual(pretty, "{\n  \"b\": 1,\n  \"a\": [\n    1.50,\n    true,\n    {}\n  ],\n  \"s\": \"x: {y}, [z]\",\n  \"e\": []\n}")
        XCTAssertEqual(try TextTransform.jsonMinify.apply(to: pretty), source)
        XCTAssertThrowsError(try TextTransform.jsonPretty.apply(to: "{oops"))
    }

    func testLineEdits() {
        XCTAssertEqual(LineEdit.indent("a\n\nb", unit: "  "), "  a\n\n  b")
        XCTAssertEqual(LineEdit.outdent("    a\n\tb\n c\nd", width: 4), "a\nb\nc\nd")
        let commented = LineEdit.toggleComment("  a\n\n    b", prefix: "//")
        XCTAssertEqual(commented, "  // a\n\n  //   b")
        XCTAssertEqual(LineEdit.toggleComment(commented, prefix: "//"), "  a\n\n    b")
        XCTAssertEqual(LineEdit.toggleComment("#x\ny", prefix: "#"), "# #x\n# y")
    }
}

final class InsightTests: XCTestCase {
    func testStatistics() {
        let stats = TextStatistics("Hello, world!\n你好 it's\n")
        XCTAssertEqual(stats.lines, 2)
        XCTAssertEqual(stats.words, 5)
        XCTAssertEqual(stats.characters, 22)
        XCTAssertEqual(stats.bytes, 26)
        XCTAssertEqual(TextStatistics("").lines, 0)
        XCTAssertEqual(TextStatistics("a").lines, 1)
    }

    func testOutline() {
        let swift = Outline.items(in: "import X\n\n// MARK: - Model\nstruct Point {\n    func length() -> Double { 0 }\n    init(x: Int) {}\n}\nfinal class A: B {}\n", language: Languages.language(id: "swift")!)
        XCTAssertEqual(swift.map(\.title), ["Model", "Point", "length", "init", "A"])
        XCTAssertEqual(swift.map(\.line), [3, 4, 5, 6, 8])
        let md = Outline.items(in: "# A\ntext\n## B ##\n```\n# not\n```\n### C", language: Languages.language(id: "markdown")!)
        XCTAssertEqual(md.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(md.map(\.level), [0, 1, 2])
        let py = Outline.items(in: "class A:\n    def f(self):\n        pass\nasync def g():\n    pass\n", language: Languages.language(id: "python")!)
        XCTAssertEqual(py.map(\.title), ["A", "f", "g"])
        let js = Outline.items(in: "export function a() {}\nconst b = async (x) => {}\nclass C {}\nif (x) {}\n", language: Languages.language(id: "javascript")!)
        XCTAssertEqual(js.map(\.title), ["a", "b", "C"])
        let go = Outline.items(in: "type T struct {}\nfunc (t *T) Run() {}\nfunc main() {}\n", language: Languages.language(id: "go")!)
        XCTAssertEqual(go.map(\.title), ["T", "Run", "main"])
    }

    func testDiff() {
        let lines = LineDiff.compare("a\nb\nc\nd", "a\nB\nc\nd\ne")
        XCTAssertEqual(lines.map(\.text), ["a", "b", "B", "c", "d", "e"])
        XCTAssertEqual(lines.map(\.kind), [.same, .removed, .added, .same, .same, .added])
        XCTAssertEqual(LineDiff.summary(lines), LineDiff.Summary(added: 2, removed: 1))
        XCTAssertEqual(lines[2].rightNumber, 2)
        XCTAssertNil(lines[2].leftNumber)
        XCTAssertTrue(LineDiff.compare("x\ny", "x\ny").allSatisfy { $0.kind == .same })
    }

    func testHexDump() {
        let data = Data((0..<20).map { UInt8($0 + 0x3E) })
        XCTAssertEqual(HexDump.rowCount(for: 20), 2)
        XCTAssertEqual(HexDump.rowCount(for: 0), 0)
        let row = HexDump.row(0, of: data)
        XCTAssertEqual(row.offset, "00000000")
        XCTAssertEqual(row.hex, "3E 3F 40 41 42 43 44 45  46 47 48 49 4A 4B 4C 4D")
        XCTAssertEqual(row.ascii, ">?@ABCDEFGHIJKLM")
        XCTAssertEqual(HexDump.row(1, of: data).offset, "00000010")
        XCTAssertEqual(HexDump.row(1, of: data.dropFirst(2)).hex, "50 51")
        // Narrow screens show eight bytes per row.
        XCTAssertEqual(HexDump.rowCount(for: 20, bytesPerRow: 8), 3)
        XCTAssertEqual(HexDump.row(1, of: data, bytesPerRow: 8).hex, "46 47 48 49 4A 4B 4C 4D")
        XCTAssertEqual(HexDump.row(1, of: data, bytesPerRow: 8).offset, "00000008")
        XCTAssertEqual(HexDump.row(2, of: data, bytesPerRow: 8).ascii, "NOPQ")
        XCTAssertEqual(HexDump.hexColumnWidth(bytesPerRow: 16), 48)
        XCTAssertEqual(HexDump.hexColumnWidth(bytesPerRow: 8), 23)
        XCTAssertEqual(HexDump.row(0, of: data).hex.count, HexDump.hexColumnWidth(bytesPerRow: 16))
    }

    func testMarkdownHTML() {
        XCTAssertEqual(MarkdownHTML.render("# Hi *there*"), "<h1 id=\"hi-there\">Hi <em>there</em></h1>\n")
        XCTAssertEqual(MarkdownHTML.render("a **b** `c<d>` ~~e~~\n"), "<p>a <strong>b</strong> <code>c&lt;d&gt;</code> <del>e</del></p>\n")
        XCTAssertEqual(MarkdownHTML.render("[t](http://x \"T\") ![a](i.png)"), "<p><a href=\"http://x\" title=\"T\">t</a> <img src=\"i.png\" alt=\"a\"></p>\n")
        XCTAssertEqual(MarkdownHTML.render("```js\na < b\n```"), "<pre><code class=\"language-js\">a &lt; b</code></pre>\n")
        XCTAssertEqual(MarkdownHTML.render("- a\n- [x] b\n  - c\n"), "<ul>\n<li>a</li>\n<li><input type=\"checkbox\" disabled checked> b\n<ul>\n<li>c</li>\n</ul>\n</li>\n</ul>\n")
        XCTAssertEqual(MarkdownHTML.render("1. a\n2. b"), "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n")
        XCTAssertEqual(MarkdownHTML.render("> q\n> r"), "<blockquote>\n<p>q\nr</p>\n</blockquote>\n")
        XCTAssertEqual(MarkdownHTML.render("| a | b |\n|---|:-:|\n| 1 | 2 |"), "<table>\n<thead><tr><th>a</th><th style=\"text-align:center\">b</th></tr></thead>\n<tbody>\n<tr><td>1</td><td style=\"text-align:center\">2</td></tr>\n</tbody>\n</table>\n")
        XCTAssertEqual(MarkdownHTML.render("---"), "<hr>\n")
        XCTAssertEqual(MarkdownHTML.render("snake_case_name 2*3*4"), "<p>snake_case_name 2<em>3</em>4</p>\n")
        XCTAssertEqual(MarkdownHTML.render("---\ntitle: x\n---\n# H"), "<pre class=\"frontmatter\"><code>title: x</code></pre>\n<h1 id=\"h\">H</h1>\n")
    }

    /// Nothing in a previewed file may reach the page as live markup.
    func testMarkdownHTMLNeutralisesUntrustedInput() {
        XCTAssertEqual(MarkdownHTML.render("a <script>alert(1)</script> [x](javascript:alert(1))"), "<p>a &lt;script&gt;alert(1)&lt;/script&gt; <a href=\"#\">x</a></p>\n")
        // A line that starts with a tag is an HTML block in CommonMark: shown as text.
        XCTAssertEqual(MarkdownHTML.render("<script>alert(1)</script>"), "<pre class=\"raw-html\"><code>&lt;script&gt;alert(1)&lt;/script&gt;</code></pre>\n")
        let cases = [
            "<script>alert(1)</script>",
            "<div onclick=\"alert(1)\">block</div>\n\ntext",
            "text <img src=x onerror=alert(1)> more",
            "<iframe src=\"https://example.com\"></iframe>",
            "[x](JaVaScRiPt:alert(1))",
            "[x](<java\tscript:alert(1)>)",
            "![x](javascript:alert(1))",
            "[x](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)",
            "[x](http://a.b/\"onmouseover=\"alert(1))",
            "![a\" onerror=\"alert(1)](i.png)",
            "[x](http://a.b \"t\\\" onmouseover=\\\"alert(1)\")",
            "```\"><script>alert(1)</script>\ncode\n```",
            "<!-- comment --><style>body{display:none}</style>",
            "<https://a.b/?q=\"><script>alert(1)</script>>",
        ]
        let allowed = try! NSRegularExpression(pattern: "<(/?(p|a|img|em|strong|del|code|pre|ul|ol|li|blockquote|h[1-6]|hr|br|table|thead|tbody|tr|th|td|input))(\\s[^<>]*)?>")
        for source in cases {
            let html = MarkdownHTML.render(source)
            let lower = html.lowercased()
            XCTAssertFalse(lower.contains("<script"), source)
            XCTAssertFalse(lower.contains("<iframe"), source)
            XCTAssertFalse(lower.contains("<style"), source)
            XCTAssertFalse(lower.contains("<div"), source)
            XCTAssertFalse(lower.contains("javascript:"), source)
            XCTAssertFalse(lower.contains("data:text"), source)
            // Every tag left in the output is one this renderer writes, and no attribute value was broken out of.
            let stripped = allowed.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "")
            XCTAssertFalse(stripped.contains("<"), "unexpected tag in \(html)")
            for match in allowed.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)) {
                // Quoted attribute values are inert once their quotes are escaped; look only outside them.
                let tag = (html as NSString).substring(with: match.range).replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                XCTAssertFalse(tag.contains("\""), "unbalanced quote in a tag from \(source)")
                XCTAssertNil(tag.range(of: "\\son[a-z]+\\s*=", options: [.regularExpression, .caseInsensitive]), "event handler in \(tag) from \(source)")
            }
        }
        XCTAssertEqual(MarkdownHTML.safeURL("https://a.b/c?d=1&e=2"), "https://a.b/c?d=1&amp;e=2")
        XCTAssertEqual(MarkdownHTML.safeURL("data:image/png;base64,AAAA"), "data:image/png;base64,AAAA")
        XCTAssertEqual(MarkdownHTML.safeURL("data:image/svg+xml,<svg onload=alert(1)>"), "#")
        XCTAssertEqual(MarkdownHTML.safeURL(" vbscript:x"), "#")
    }
}
