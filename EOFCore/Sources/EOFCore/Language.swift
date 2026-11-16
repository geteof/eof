import Foundation

/// A file type the editor knows: how to recognise it and how it writes comments.
/// Syntax colouring itself is done by Tree-sitter grammars in the app.
public struct Language: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var extensions: [String]
    public var filenames: [String]
    public var interpreters: [String]
    public var lineComments: [String]
    public var blockComment: [String]?

    public init(id: String, name: String, extensions: [String] = [], filenames: [String] = [], interpreters: [String] = [], lineComments: [String] = [], blockComment: [String]? = nil) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.filenames = filenames
        self.interpreters = interpreters
        self.lineComments = lineComments
        self.blockComment = blockComment
    }

    public static func == (lhs: Language, rhs: Language) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The token that starts a line comment, used by "toggle comment".
    public var commentPrefix: String? { lineComments.first }

    public var isPlainText: Bool { id == "plain" || id == "csv" }
}

public enum Languages {
    public static let plain = Language(id: "plain", name: "Plain Text", extensions: ["txt", "text", "log"])

    public static let all: [Language] = [plain] + definitions

    private static let byID: [String: Language] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        for language in all {
            for ext in language.extensions where map[ext] == nil { map[ext] = language }
        }
        return map
    }()

    private static let byFilename: [String: Language] = {
        var map: [String: Language] = [:]
        for language in all {
            for name in language.filenames where map[name.lowercased()] == nil { map[name.lowercased()] = language }
        }
        return map
    }()

    public static func language(id: String) -> Language? { byID[id] }

    /// Picks a language from the file name, then the extension, then a `#!` line.
    public static func detect(filename: String, firstLine: String? = nil) -> Language {
        let name = (filename as NSString).lastPathComponent.lowercased()
        if let hit = byFilename[name] { return hit }
        if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") { return byID["dockerfile"]! }
        if name.hasPrefix(".env.") { return byID["ini"]! }
        // Try the longest extension first so "d.ts" or "blade.php" style names resolve sensibly.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1 {
            for start in 1..<parts.count {
                let ext = parts[start...].joined(separator: ".")
                if let hit = byExtension[ext] { return hit }
            }
        }
        if let firstLine, let hit = detect(shebang: firstLine) { return hit }
        if let firstLine {
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("<?xml") { return byID["xml"]! }
            if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") { return byID["html"]! }
            if trimmed.hasPrefix("<?php") { return byID["php"]! }
        }
        return plain
    }

    public static func detect(shebang line: String) -> Language? {
        guard line.hasPrefix("#!") else { return nil }
        let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        var parts = body.split(separator: " ").map(String.init)
        guard var program = parts.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if program == "env" {
            parts.removeFirst()
            // `env -S prog` and `env VAR=1 prog`
            guard let next = parts.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) else { return nil }
            program = (next as NSString).lastPathComponent
        }
        // python3.12 → python
        let base = String(program.prefix { !($0.isNumber || $0 == ".") })
        for language in all where language.interpreters.contains(program) || language.interpreters.contains(base) {
            return language
        }
        return nil
    }

    private static let definitions: [Language] = [
        Language(id: "swift", name: "Swift", extensions: ["swift"], interpreters: ["swift"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "objc", name: "Objective-C", extensions: ["m", "mm"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "c", name: "C", extensions: ["c", "h"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "cpp", name: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ino", "ipp", "tpp"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "csharp", name: "C#", extensions: ["cs", "csx"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "java", name: "Java", extensions: ["java"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "kotlin", name: "Kotlin", extensions: ["kt", "kts"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "go", name: "Go", extensions: ["go"], filenames: ["go.mod", "go.sum", "go.work"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "rust", name: "Rust", extensions: ["rs"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "python", name: "Python", extensions: ["py", "pyw", "pyi", "pyx"], filenames: ["SConstruct"], interpreters: ["python", "python2", "python3", "pypy"], lineComments: ["#"]),
        Language(id: "ruby", name: "Ruby", extensions: ["rb", "rake", "gemspec", "ru", "erb"], filenames: ["Gemfile", "Rakefile", "Podfile", "Fastfile", "Appfile", "Vagrantfile", "Brewfile"], interpreters: ["ruby"], lineComments: ["#"], blockComment: ["=begin", "=end"]),
        Language(id: "php", name: "PHP", extensions: ["php", "phtml", "php5"], interpreters: ["php"], lineComments: ["//", "#"], blockComment: ["/*", "*/"]),
        Language(id: "javascript", name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"], interpreters: ["node", "nodejs", "deno", "bun"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "typescript", name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"], interpreters: ["ts-node", "tsx"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "html", name: "HTML", extensions: ["html", "htm", "xhtml", "vue", "svelte", "astro", "hbs", "ejs", "njk", "liquid"], blockComment: ["<!--", "-->"]),
        Language(id: "xml", name: "XML", extensions: ["xml", "xsd", "xsl", "xslt", "svg", "plist", "storyboard", "xib", "rss", "atom", "xaml", "csproj", "entitlements", "xcscheme", "opml", "gpx", "kml"], blockComment: ["<!--", "-->"]),
        Language(id: "css", name: "CSS", extensions: ["css"], blockComment: ["/*", "*/"]),
        Language(id: "scss", name: "SCSS", extensions: ["scss", "sass", "less", "styl"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "json", name: "JSON", extensions: ["json", "jsonc", "json5", "geojson", "webmanifest", "ipynb", "xcstrings", "resolved", "code-workspace", "jsonl", "ndjson", "har", "map"], filenames: [".prettierrc", ".eslintrc", ".babelrc", ".swcrc", "composer.lock", "flake.lock"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "yaml", name: "YAML", extensions: ["yaml", "yml"], filenames: [".clang-format", ".clang-tidy", "pubspec.lock", "Podfile.lock", ".yamllint"], lineComments: ["#"]),
        Language(id: "toml", name: "TOML", extensions: ["toml"], filenames: ["Cargo.lock", "poetry.lock", "uv.lock", "Pipfile"], lineComments: ["#"]),
        Language(id: "ini", name: "INI / Properties", extensions: ["ini", "cfg", "conf", "config", "properties", "env", "editorconfig", "desktop", "service", "prefs", "gitconfig", "npmrc"], filenames: [".env", ".editorconfig", ".gitconfig", ".npmrc", ".gitmodules", ".gitattributes", ".flake8", ".pylintrc", "setup.cfg", ".yarnrc"], lineComments: ["#", ";"]),
        Language(id: "markdown", name: "Markdown", extensions: ["md", "markdown", "mdown", "mkd", "mdx", "rmd", "qmd"], filenames: ["README", "CHANGELOG", "LICENSE", "AUTHORS", "CONTRIBUTING", "NOTICE", "TODO"], blockComment: ["<!--", "-->"]),
        Language(id: "shell", name: "Shell", extensions: ["sh", "bash", "zsh", "fish", "ksh", "command", "bats"], filenames: [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".zshenv", ".profile", ".bash_aliases", ".envrc", "PKGBUILD", "APKBUILD"], interpreters: ["sh", "bash", "zsh", "fish", "ksh", "dash", "ash"], lineComments: ["#"]),
        Language(id: "sql", name: "SQL", extensions: ["sql", "psql", "ddl", "dml", "pgsql", "mysql"], lineComments: ["--"], blockComment: ["/*", "*/"]),
        Language(id: "lua", name: "Lua", extensions: ["lua", "rockspec"], interpreters: ["lua", "luajit"], lineComments: ["--"], blockComment: ["--[[", "]]"]),
        Language(id: "dockerfile", name: "Dockerfile", extensions: ["dockerfile"], filenames: ["Dockerfile", "Containerfile"], lineComments: ["#"]),
        Language(id: "makefile", name: "Makefile", extensions: ["mk", "mak", "make"], filenames: ["Makefile", "GNUmakefile", "makefile", "Justfile", "justfile"], lineComments: ["#"]),
        Language(id: "diff", name: "Diff", extensions: ["diff", "patch", "rej"]),
        Language(id: "dart", name: "Dart", extensions: ["dart"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "scala", name: "Scala", extensions: ["scala", "sc", "sbt"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "perl", name: "Perl", extensions: ["pl", "pm", "t"], interpreters: ["perl"], lineComments: ["#"]),
        Language(id: "r", name: "R", extensions: ["r"], interpreters: ["Rscript"], lineComments: ["#"]),
        Language(id: "haskell", name: "Haskell", extensions: ["hs", "lhs", "cabal"], lineComments: ["--"], blockComment: ["{-", "-}"]),
        Language(id: "elixir", name: "Elixir", extensions: ["ex", "exs", "heex"], interpreters: ["elixir"], lineComments: ["#"]),
        Language(id: "zig", name: "Zig", extensions: ["zig", "zon"], lineComments: ["//"]),
        Language(id: "powershell", name: "PowerShell", extensions: ["ps1", "psm1", "psd1"], interpreters: ["pwsh", "powershell"], lineComments: ["#"], blockComment: ["<#", "#>"]),
        Language(id: "batch", name: "Batch", extensions: ["bat", "cmd"], lineComments: ["::", "rem ", "REM "]),
        Language(id: "groovy", name: "Groovy / Gradle", extensions: ["groovy", "gradle", "gvy"], filenames: ["Jenkinsfile"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "graphql", name: "GraphQL", extensions: ["graphql", "gql", "graphqls"], lineComments: ["#"]),
        Language(id: "protobuf", name: "Protocol Buffers", extensions: ["proto"], lineComments: ["//"], blockComment: ["/*", "*/"]),
        Language(id: "terraform", name: "Terraform / HCL", extensions: ["tf", "tfvars", "hcl", "nomad"], lineComments: ["#", "//"], blockComment: ["/*", "*/"]),
        Language(id: "nginx", name: "Nginx", extensions: ["nginx", "nginxconf"], filenames: ["nginx.conf"], lineComments: ["#"]),
        Language(id: "gitignore", name: "Ignore File", extensions: ["gitignore", "dockerignore", "npmignore", "eslintignore", "prettierignore"], filenames: [".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore", "CODEOWNERS"], lineComments: ["#"]),
        Language(id: "csv", name: "CSV / TSV", extensions: ["csv", "tsv", "tab"]),
        Language(id: "tex", name: "LaTeX", extensions: ["tex", "sty", "cls", "bib", "ltx"], lineComments: ["%"]),
        Language(id: "clojure", name: "Clojure / Lisp", extensions: ["clj", "cljs", "cljc", "edn", "lisp", "el", "scm", "rkt"], lineComments: [";"]),
        Language(id: "cmake", name: "CMake", extensions: ["cmake"], filenames: ["CMakeLists.txt"], lineComments: ["#"]),
        Language(id: "nix", name: "Nix", extensions: ["nix"], lineComments: ["#"], blockComment: ["/*", "*/"]),
        Language(id: "ocaml", name: "OCaml", extensions: ["ml", "mli"], blockComment: ["(*", "*)"]),
        Language(id: "elm", name: "Elm", extensions: ["elm"], lineComments: ["--"], blockComment: ["{-", "-}"]),
        Language(id: "julia", name: "Julia", extensions: ["jl"], interpreters: ["julia"], lineComments: ["#"], blockComment: ["#=", "=#"]),
        Language(id: "pascal", name: "Pascal", extensions: ["pas", "pp", "lpr", "dpr"], lineComments: ["//"], blockComment: ["{", "}"]),
    ]
}
