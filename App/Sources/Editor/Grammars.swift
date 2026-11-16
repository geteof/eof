import EOFCore
import Foundation
import Runestone
import TreeSitterSwiftRunestone
import TreeSitterObjectiveCRunestone
import TreeSitterCRunestone
import TreeSitterCPPRunestone
import TreeSitterCSharpRunestone
import TreeSitterJavaRunestone
import TreeSitterGoRunestone
import TreeSitterRustRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterPHPRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterTSXRunestone
import TreeSitterHTMLRunestone
import TreeSitterSvelteRunestone
import TreeSitterAstroRunestone
import TreeSitterXMLRunestone
import TreeSitterCSSRunestone
import TreeSitterSCSSRunestone
import TreeSitterJSONRunestone
import TreeSitterJSON5Runestone
import TreeSitterYAMLRunestone
import TreeSitterTOMLRunestone
import TreeSitterMarkdownRunestone
import TreeSitterMarkdownInlineRunestone
import TreeSitterBashRunestone
import TreeSitterFishRunestone
import TreeSitterSQLRunestone
import TreeSitterLuaRunestone
import TreeSitterDiffRunestone
import TreeSitterDartRunestone
import TreeSitterScalaRunestone
import TreeSitterPerlRunestone
import TreeSitterRRunestone
import TreeSitterHaskellRunestone
import TreeSitterElixirRunestone
import TreeSitterProtoRunestone
import TreeSitterHCLRunestone
import TreeSitterLaTeXRunestone
import TreeSitterCMakeRunestone
import TreeSitterNixRunestone
import TreeSitterOCamlRunestone
import TreeSitterElmRunestone
import TreeSitterJuliaRunestone
import TreeSitterPascalRunestone

/// Maps the editor's languages to Tree-sitter grammars from TreeSitterLanguages.
enum Grammars {
    private static var cache: [String: TreeSitterLanguage] = [:]
    private static let lock = NSLock()

    /// Grammar key for each `Language.id` that has one. Languages missing here open without colouring.
    private static let keysByLanguageID: [String: String] = [
        "swift": "swift", "objc": "objectiveC", "c": "c", "cpp": "cpp", "csharp": "cSharp", "java": "java", "go": "go",
        "rust": "rust", "python": "python", "ruby": "ruby", "php": "php", "javascript": "javaScript", "typescript": "typeScript",
        "html": "html", "xml": "xml", "css": "css", "scss": "scss", "json": "json", "yaml": "yaml", "toml": "toml",
        "markdown": "markdown", "shell": "bash", "sql": "sql", "lua": "lua", "diff": "diff", "dart": "dart", "scala": "scala",
        "perl": "perl", "r": "r", "haskell": "haskell", "elixir": "elixir", "protobuf": "proto", "terraform": "hcl",
        "tex": "latex", "cmake": "cmake", "nix": "nix", "ocaml": "ocaml", "elm": "elm", "julia": "julia", "pascal": "pascal",
    ]

    /// File extensions that need a different grammar from the rest of their language.
    private static let keysByExtension: [String: String] = [
        "jsx": "jsx", "tsx": "tsx", "svelte": "svelte", "astro": "astro", "json5": "json5", "fish": "fish",
    ]

    /// Names that injection queries and Markdown code fences use for languages.
    private static let aliases: [String: String] = [
        "markdown_inline": "markdownInline", "js": "javaScript", "javascript": "javaScript", "ts": "typeScript",
        "typescript": "typeScript", "sh": "bash", "shell": "bash", "zsh": "bash", "bash": "bash", "py": "python",
        "yml": "yaml", "objc": "objectiveC", "objective-c": "objectiveC", "c++": "cpp", "c#": "cSharp", "cs": "cSharp",
        "golang": "go", "rb": "ruby", "rs": "rust", "md": "markdown", "tex": "latex", "proto": "proto", "tf": "hcl",
    ]

    static func hasGrammar(for language: Language) -> Bool {
        keysByLanguageID[language.id] != nil
    }

    static func grammar(for language: Language, filename: String) -> TreeSitterLanguage? {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard let key = keysByExtension[ext] ?? keysByLanguageID[language.id] else { return nil }
        return cached(key)
    }

    static func grammar(named name: String) -> TreeSitterLanguage? {
        let lower = name.lowercased()
        if let key = aliases[lower] ?? keysByExtension[lower] { return cached(key) }
        if let key = keysByLanguageID[lower] { return cached(key) }
        // A code fence may name the language by a file extension, such as "kt" or "hpp".
        let byExtension = Languages.detect(filename: "x." + lower)
        return keysByLanguageID[byExtension.id].flatMap(cached)
    }

    /// Grammars compile their queries on first use, so each one is built once, under a lock:
    /// editor state is prepared on a background queue as well as on the main thread.
    private static func cached(_ key: String) -> TreeSitterLanguage? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        guard let created = make(key) else { return nil }
        created.prepare()
        cache[key] = created
        return created
    }

    private static func make(_ key: String) -> TreeSitterLanguage? {
        switch key {
        case "swift": return .swift
        case "objectiveC": return .objectiveC
        case "c": return .c
        case "cpp": return .cpp
        case "cSharp": return .cSharp
        case "java": return .java
        case "go": return .go
        case "rust": return .rust
        case "python": return .python
        case "ruby": return .ruby
        case "php": return .php
        case "javaScript": return .javaScript
        case "jsx": return .jsx
        case "typeScript": return .typeScript
        case "tsx": return .tsx
        case "html": return .html
        case "svelte": return .svelte
        case "astro": return .astro
        case "xml": return .xml
        case "css": return .css
        case "scss": return .scss
        case "json": return .json
        case "json5": return .json5
        case "yaml": return .yaml
        case "toml": return .toml
        case "markdown": return .markdown
        case "markdownInline": return .markdownInline
        case "bash": return .bash
        case "fish": return .fish
        case "sql": return .sql
        case "lua": return .lua
        case "diff": return .diff
        case "dart": return .dart
        case "scala": return .scala
        case "perl": return .perl
        case "r": return .r
        case "haskell": return .haskell
        case "elixir": return .elixir
        case "proto": return .proto
        case "hcl": return .hcl
        case "latex": return .latex
        case "cmake": return .cmake
        case "nix": return .nix
        case "ocaml": return .ocaml
        case "elm": return .elm
        case "julia": return .julia
        case "pascal": return .pascal
        default: return nil
        }
    }
}

/// Resolves the languages embedded in another one: script and style in HTML, code fences in Markdown.
final class GrammarProvider: TreeSitterLanguageProvider {
    static let shared = GrammarProvider()

    func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
        Grammars.grammar(named: languageName)
    }
}
