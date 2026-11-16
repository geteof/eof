import Foundation

/// How a language's source text is scanned.
public enum LexMode: Sendable {
    case plain
    case code
    case markup
    case markdown
    case yaml
    case json
    case ini
    case diff
}

/// A string literal form in a `.code` language.
public struct StringRule: Sendable, Hashable {
    public var open: String
    public var close: String
    public var multiline: Bool
    public var escapes: Bool

    public init(_ open: String, _ close: String? = nil, multiline: Bool = false, escapes: Bool = true) {
        self.open = open
        self.close = close ?? open
        self.multiline = multiline
        self.escapes = escapes
    }
}

public struct Language: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var mode: LexMode
    public var extensions: [String] = []
    public var filenames: [String] = []
    public var interpreters: [String] = []
    public var lineComments: [String] = []
    public var blockComment: [String]? = nil
    public var nestedBlockComments = false
    public var strings: [StringRule] = []
    public var keywords: Set<String> = []
    public var types: Set<String> = []
    public var constants: Set<String> = []
    public var caseInsensitive = false
    /// `#include`-style directives at the start of a line.
    public var hashDirectives = false
    /// `@name` annotations and attributes.
    public var atAnnotations = false
    /// `$name` and `${name}` variables.
    public var dollarVariables = false
    /// Identifiers may contain `-` (CSS, Lisp-like names).
    public var hyphenIdentifiers = false
    /// `'` only opens a literal when it closes within a few characters (Rust lifetimes, generics).
    public var shortCharLiterals = false
    /// Identifiers starting with an uppercase letter are coloured as types.
    public var capitalizedTypes = false
    /// Languages embedded in a markup host: tag name → language id.
    public var embedded: [String: String] = [:]

    public static func == (lhs: Language, rhs: Language) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The token that starts a line comment, used by "toggle comment".
    public var commentPrefix: String? { lineComments.first }
}

private func words(_ s: String) -> Set<String> {
    Set(s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
}

private let dq = StringRule("\"")
private let sq = StringRule("'")
private let bq = StringRule("`", multiline: true)

public enum Languages {
    public static let plain = Language(id: "plain", name: "Plain Text", mode: .plain, extensions: ["txt", "text", "log"])

    public static let all: [Language] = build()

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

    // swiftlint:disable function_body_length
    private static func build() -> [Language] {
        var list: [Language] = [plain]

        func add(_ id: String, _ name: String, _ mode: LexMode = .code, _ configure: (inout Language) -> Void) {
            var language = Language(id: id, name: name, mode: mode)
            configure(&language)
            list.append(language)
        }

        let cTypes = words("int long short char float double void unsigned signed bool size_t ssize_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t wchar_t auto")
        let cKeywords = words("if else for while do switch case default break continue return goto sizeof typedef struct union enum static extern const volatile register inline restrict")
        let cConstants = words("NULL true false nullptr TRUE FALSE YES NO nil")

        add("swift", "Swift") {
            $0.extensions = ["swift"]
            $0.interpreters = ["swift"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.nestedBlockComments = true
            $0.strings = [StringRule("\"\"\"", multiline: true), dq]
            $0.keywords = words("actor any as associatedtype async await borrowing break case catch class consuming continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let macro mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet")
            $0.constants = words("true false nil self Self")
            $0.atAnnotations = true
            $0.hashDirectives = true
            $0.capitalizedTypes = true
        }
        add("objc", "Objective-C") {
            $0.extensions = ["m", "mm"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq]
            $0.keywords = cKeywords.union(words("self super in out inout bycopy byref oneway instancetype id SEL IMP BOOL Class nonatomic strong weak copy assign readonly readwrite atomic"))
            $0.types = cTypes.union(words("NSString NSArray NSDictionary NSNumber NSObject NSInteger NSUInteger CGFloat"))
            $0.constants = cConstants
            $0.atAnnotations = true
            $0.hashDirectives = true
            $0.capitalizedTypes = true
        }
        add("c", "C") {
            $0.extensions = ["c", "h"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq]
            $0.keywords = cKeywords
            $0.types = cTypes
            $0.constants = cConstants
            $0.hashDirectives = true
        }
        add("cpp", "C++") {
            $0.extensions = ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ino", "ipp", "tpp"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq]
            $0.keywords = cKeywords.union(words("alignas alignof and bitand bitor catch class co_await co_return co_yield concept consteval constexpr constinit const_cast decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual xor override final"))
            $0.types = cTypes.union(words("string vector map set unordered_map unordered_set shared_ptr unique_ptr optional variant tuple pair array"))
            $0.constants = cConstants
            $0.hashDirectives = true
        }
        add("csharp", "C#") {
            $0.extensions = ["cs", "csx"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("@\"", "\"", multiline: true, escapes: false), dq, sq]
            $0.keywords = words("abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach get goto if implicit in init interface internal is lock namespace new operator out override params partial private protected public readonly record ref required return sealed set sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using var virtual volatile when where while with yield")
            $0.types = words("bool byte char decimal double dynamic float int long object sbyte short string uint ulong ushort void nint nuint")
            $0.constants = words("true false null")
            $0.hashDirectives = true
            $0.capitalizedTypes = true
        }
        add("java", "Java") {
            $0.extensions = ["java"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [StringRule("\"\"\"", multiline: true), dq, sq]
            $0.keywords = words("abstract assert break case catch class const continue default do else enum exports extends final finally for goto if implements import instanceof interface module native new non-sealed package permits private protected public record requires return sealed static strictfp super switch synchronized this throw throws transient try var volatile while yield")
            $0.types = words("boolean byte char double float int long short void String Object Integer Long Double Boolean List Map Set")
            $0.constants = words("true false null")
            $0.atAnnotations = true
            $0.capitalizedTypes = true
        }
        add("kotlin", "Kotlin") {
            $0.extensions = ["kt", "kts"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.nestedBlockComments = true
            $0.strings = [StringRule("\"\"\"", multiline: true, escapes: false), dq, sq]
            $0.keywords = words("abstract actual annotation as break by catch class companion const constructor continue crossinline data do else enum expect external final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias val value var vararg when where while")
            $0.constants = words("true false null")
            $0.atAnnotations = true
            $0.capitalizedTypes = true
        }
        add("go", "Go") {
            $0.extensions = ["go"]
            $0.filenames = ["go.mod", "go.sum", "go.work"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq, StringRule("`", multiline: true, escapes: false)]
            $0.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
            $0.types = words("any bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr")
            $0.constants = words("true false nil iota")
        }
        add("rust", "Rust") {
            $0.extensions = ["rs"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.nestedBlockComments = true
            $0.strings = [StringRule("\"", multiline: true), sq]
            $0.shortCharLiterals = true
            $0.keywords = words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while")
            $0.types = words("bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box")
            $0.constants = words("true false None Some Ok Err")
            $0.capitalizedTypes = true
        }
        add("python", "Python") {
            $0.extensions = ["py", "pyw", "pyi", "pyx"]
            $0.filenames = ["SConstruct"]
            $0.interpreters = ["python", "python2", "python3", "pypy"]
            $0.lineComments = ["#"]
            $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), dq, sq]
            $0.keywords = words("and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try type while with yield")
            $0.types = words("int float str bool bytes list dict set tuple object complex frozenset")
            $0.constants = words("True False None self cls")
            $0.atAnnotations = true
        }
        add("ruby", "Ruby") {
            $0.extensions = ["rb", "rake", "gemspec", "ru", "erb"]
            $0.filenames = ["Gemfile", "Rakefile", "Podfile", "Fastfile", "Appfile", "Vagrantfile", "Brewfile"]
            $0.interpreters = ["ruby"]
            $0.lineComments = ["#"]
            $0.blockComment = ["=begin", "=end"]
            $0.strings = [dq, sq, bq]
            $0.keywords = words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private public protected")
            $0.constants = words("true false nil self")
            $0.capitalizedTypes = true
        }
        add("php", "PHP") {
            $0.extensions = ["php", "phtml", "php5"]
            $0.interpreters = ["php"]
            $0.lineComments = ["//", "#"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq]
            $0.keywords = words("abstract and as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield")
            $0.types = words("int float string bool array object mixed void iterable never")
            $0.constants = words("true false null TRUE FALSE NULL")
            $0.dollarVariables = true
            $0.capitalizedTypes = true
        }
        let jsKeywords = words("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield")
        let jsConstants = words("true false null undefined NaN Infinity")
        add("javascript", "JavaScript") {
            $0.extensions = ["js", "mjs", "cjs", "jsx"]
            $0.interpreters = ["node", "nodejs", "deno", "bun"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq, bq]
            $0.keywords = jsKeywords
            $0.constants = jsConstants
            $0.capitalizedTypes = true
        }
        add("typescript", "TypeScript") {
            $0.extensions = ["ts", "tsx", "mts", "cts"]
            $0.interpreters = ["ts-node", "tsx"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq, bq]
            $0.keywords = jsKeywords.union(words("abstract as asserts declare enum implements infer interface is keyof module namespace override private protected public readonly satisfies type unique"))
            $0.types = words("any boolean bigint never number object string symbol unknown void")
            $0.constants = jsConstants
            $0.atAnnotations = true
            $0.capitalizedTypes = true
        }
        add("html", "HTML", .markup) {
            $0.extensions = ["html", "htm", "xhtml", "vue", "svelte", "astro", "hbs", "ejs", "njk", "liquid"]
            $0.blockComment = ["<!--", "-->"]
            $0.embedded = ["script": "javascript", "style": "css"]
        }
        add("xml", "XML", .markup) {
            $0.extensions = ["xml", "xsd", "xsl", "xslt", "svg", "plist", "storyboard", "xib", "rss", "atom", "xaml", "csproj", "entitlements", "xcscheme", "opml", "gpx", "kml"]
            $0.blockComment = ["<!--", "-->"]
        }
        let cssConstants = words("inherit initial unset revert none auto important")
        add("css", "CSS") {
            $0.extensions = ["css"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq]
            $0.constants = cssConstants
            $0.atAnnotations = true
            $0.hyphenIdentifiers = true
        }
        add("scss", "SCSS") {
            $0.extensions = ["scss", "sass", "less", "styl"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq]
            $0.constants = cssConstants
            $0.atAnnotations = true
            $0.dollarVariables = true
            $0.hyphenIdentifiers = true
        }
        add("json", "JSON", .json) {
            $0.extensions = ["json", "jsonc", "json5", "geojson", "webmanifest", "ipynb", "xcstrings", "resolved", "code-workspace", "jsonl", "ndjson", "har", "map"]
            $0.filenames = [".prettierrc", ".eslintrc", ".babelrc", ".swcrc", "composer.lock", "flake.lock"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
        }
        add("yaml", "YAML", .yaml) {
            $0.extensions = ["yaml", "yml"]
            $0.filenames = [".clang-format", ".clang-tidy", "pubspec.lock", "Podfile.lock", ".yamllint"]
            $0.lineComments = ["#"]
        }
        add("toml", "TOML", .ini) {
            $0.extensions = ["toml"]
            $0.filenames = ["Cargo.lock", "poetry.lock", "uv.lock", "Pipfile"]
            $0.lineComments = ["#"]
        }
        add("ini", "INI / Properties", .ini) {
            $0.extensions = ["ini", "cfg", "conf", "config", "properties", "env", "editorconfig", "desktop", "service", "prefs", "gitconfig", "npmrc"]
            $0.filenames = [".env", ".editorconfig", ".gitconfig", ".npmrc", ".gitmodules", ".gitattributes", ".flake8", ".pylintrc", "setup.cfg", ".yarnrc"]
            $0.lineComments = ["#", ";"]
        }
        add("markdown", "Markdown", .markdown) {
            $0.extensions = ["md", "markdown", "mdown", "mkd", "mdx", "rmd", "qmd"]
            $0.filenames = ["README", "CHANGELOG", "LICENSE", "AUTHORS", "CONTRIBUTING", "NOTICE", "TODO"]
            $0.blockComment = ["<!--", "-->"]
        }
        add("shell", "Shell") {
            $0.extensions = ["sh", "bash", "zsh", "fish", "ksh", "command", "bats"]
            $0.filenames = [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".zshenv", ".profile", ".bash_aliases", ".envrc", "PKGBUILD", "APKBUILD"]
            $0.interpreters = ["sh", "bash", "zsh", "fish", "ksh", "dash", "ash"]
            $0.lineComments = ["#"]
            $0.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true, escapes: false), bq]
            $0.keywords = words("if then else elif fi case esac for select while until do done in function time coproc return exit break continue local export readonly declare typeset unset shift source alias eval exec set trap echo printf read cd test")
            $0.constants = words("true false")
            $0.dollarVariables = true
            $0.hyphenIdentifiers = true
        }
        add("sql", "SQL") {
            $0.extensions = ["sql", "psql", "ddl", "dml", "pgsql", "mysql"]
            $0.lineComments = ["--"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [StringRule("'", multiline: true, escapes: false), StringRule("\"", escapes: false), StringRule("`", escapes: false)]
            $0.caseInsensitive = true
            $0.keywords = words("add all alter and any as asc begin between by cascade case check column commit constraint create cross database default delete desc distinct drop else end except exists explain foreign from full function grant group having if in index inner insert intersect into is join key left like limit not offset on or order outer primary procedure references returning revoke right rollback schema select set table then transaction trigger truncate union unique update using values view when where window with")
            $0.types = words("bigint binary bit blob boolean char date datetime decimal double float int integer json jsonb numeric real serial smallint text time timestamp timestamptz uuid varchar")
            $0.constants = words("true false null")
        }
        add("lua", "Lua") {
            $0.extensions = ["lua", "rockspec"]
            $0.interpreters = ["lua", "luajit"]
            $0.lineComments = ["--"]
            $0.blockComment = ["--[[", "]]"]
            $0.strings = [dq, sq, StringRule("[[", "]]", multiline: true, escapes: false)]
            $0.keywords = words("and break do else elseif end for function goto if in local not or repeat return then until while")
            $0.constants = words("true false nil self")
        }
        add("dockerfile", "Dockerfile") {
            $0.extensions = ["dockerfile"]
            $0.filenames = ["Dockerfile", "Containerfile"]
            $0.lineComments = ["#"]
            $0.strings = [dq, sq]
            $0.caseInsensitive = true
            $0.keywords = words("add arg cmd copy entrypoint env expose from healthcheck label maintainer onbuild run shell stopsignal user volume workdir as")
            $0.dollarVariables = true
        }
        add("makefile", "Makefile") {
            $0.extensions = ["mk", "mak", "make"]
            $0.filenames = ["Makefile", "GNUmakefile", "makefile", "Justfile", "justfile"]
            $0.lineComments = ["#"]
            $0.strings = [dq, sq]
            $0.keywords = words("ifeq ifneq ifdef ifndef else endif include define endef export unexport override vpath .PHONY .DEFAULT .SUFFIXES")
            $0.dollarVariables = true
        }
        add("diff", "Diff", .diff) {
            $0.extensions = ["diff", "patch", "rej"]
        }
        add("dart", "Dart") {
            $0.extensions = ["dart"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), dq, sq]
            $0.keywords = words("abstract as assert async await base break case catch class const continue covariant default deferred do else enum export extends extension external factory final finally for get if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync this throw try typedef var when while with yield")
            $0.types = words("bool double dynamic int num void String List Map Set Future Stream Object")
            $0.constants = words("true false null")
            $0.atAnnotations = true
            $0.capitalizedTypes = true
        }
        add("scala", "Scala") {
            $0.extensions = ["scala", "sc", "sbt"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.nestedBlockComments = true
            $0.strings = [StringRule("\"\"\"", multiline: true, escapes: false), dq, sq]
            $0.shortCharLiterals = true
            $0.keywords = words("abstract case catch class def do else enum export extends extension final finally for forSome given if implicit import inline lazy match new object opaque override package private protected return sealed super then this throw trait try type using val var while with yield")
            $0.constants = words("true false null")
            $0.atAnnotations = true
            $0.capitalizedTypes = true
        }
        add("perl", "Perl") {
            $0.extensions = ["pl", "pm", "t"]
            $0.interpreters = ["perl"]
            $0.lineComments = ["#"]
            $0.strings = [dq, sq, bq]
            $0.keywords = words("my our local sub if elsif else unless while until for foreach do last next redo return use no package require print say die warn eq ne lt gt le ge cmp and or not xor")
            $0.dollarVariables = true
        }
        add("r", "R") {
            $0.extensions = ["r"]
            $0.interpreters = ["Rscript"]
            $0.lineComments = ["#"]
            $0.strings = [dq, sq]
            $0.keywords = words("if else repeat while function for next break in return library require")
            $0.constants = words("TRUE FALSE NULL NA Inf NaN")
        }
        add("haskell", "Haskell") {
            $0.extensions = ["hs", "lhs", "cabal"]
            $0.lineComments = ["--"]
            $0.blockComment = ["{-", "-}"]
            $0.nestedBlockComments = true
            $0.strings = [dq, sq]
            $0.shortCharLiterals = true
            $0.keywords = words("case class data default deriving do else forall foreign if import in infix infixl infixr instance let module newtype of qualified then type where as hiding")
            $0.constants = words("True False Nothing Just")
            $0.capitalizedTypes = true
        }
        add("elixir", "Elixir") {
            $0.extensions = ["ex", "exs", "heex"]
            $0.interpreters = ["elixir"]
            $0.lineComments = ["#"]
            $0.strings = [StringRule("\"\"\"", multiline: true), dq, sq]
            $0.keywords = words("after alias and case catch cond def defimpl defmacro defmodule defp defprotocol defstruct do else end fn for if import in not or quote raise receive require rescue try unless unquote use when with")
            $0.constants = words("true false nil")
            $0.atAnnotations = true
            $0.capitalizedTypes = true
        }
        add("zig", "Zig") {
            $0.extensions = ["zig", "zon"]
            $0.lineComments = ["//"]
            $0.strings = [dq, sq]
            $0.keywords = words("align allowzero and anyframe anytype asm async await break catch comptime const continue defer else enum errdefer error export extern fn for if inline noalias nosuspend or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while")
            $0.types = words("bool f16 f32 f64 i8 i16 i32 i64 isize u8 u16 u32 u64 usize void type anyerror noreturn")
            $0.constants = words("true false null undefined")
            $0.atAnnotations = true
        }
        add("powershell", "PowerShell") {
            $0.extensions = ["ps1", "psm1", "psd1"]
            $0.interpreters = ["pwsh", "powershell"]
            $0.lineComments = ["#"]
            $0.blockComment = ["<#", "#>"]
            $0.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true, escapes: false)]
            $0.caseInsensitive = true
            $0.keywords = words("begin break catch class continue data do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using while")
            $0.dollarVariables = true
            $0.hyphenIdentifiers = true
        }
        add("batch", "Batch") {
            $0.extensions = ["bat", "cmd"]
            $0.lineComments = ["::", "rem ", "REM "]
            $0.strings = [dq]
            $0.caseInsensitive = true
            $0.keywords = words("call cd cls copy del dir do echo else endlocal exit for goto if in mkdir move not pause set setlocal shift start")
        }
        add("groovy", "Groovy / Gradle") {
            $0.extensions = ["groovy", "gradle", "gvy"]
            $0.filenames = ["Jenkinsfile"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), dq, sq]
            $0.keywords = words("abstract as assert break case catch class const continue def default do else enum extends final finally for goto if implements import in instanceof interface new package private protected public return static super switch this throw throws trait try var while")
            $0.constants = words("true false null")
            $0.atAnnotations = true
            $0.capitalizedTypes = true
        }
        add("graphql", "GraphQL") {
            $0.extensions = ["graphql", "gql", "graphqls"]
            $0.lineComments = ["#"]
            $0.strings = [StringRule("\"\"\"", multiline: true), dq]
            $0.keywords = words("query mutation subscription fragment on type interface union enum input scalar schema extend directive implements repeatable")
            $0.types = words("Int Float String Boolean ID")
            $0.constants = words("true false null")
            $0.atAnnotations = true
            $0.dollarVariables = true
            $0.capitalizedTypes = true
        }
        add("protobuf", "Protocol Buffers") {
            $0.extensions = ["proto"]
            $0.lineComments = ["//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq, sq]
            $0.keywords = words("syntax import package option message enum service rpc returns oneof map repeated optional required reserved extend extensions stream public weak")
            $0.types = words("double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes")
            $0.constants = words("true false")
            $0.capitalizedTypes = true
        }
        add("terraform", "Terraform / HCL") {
            $0.extensions = ["tf", "tfvars", "hcl", "nomad"]
            $0.lineComments = ["#", "//"]
            $0.blockComment = ["/*", "*/"]
            $0.strings = [dq]
            $0.keywords = words("resource data variable output locals module provider terraform backend for in if else dynamic content")
            $0.types = words("string number bool list map set object tuple any")
            $0.constants = words("true false null")
        }
        add("nginx", "Nginx") {
            $0.extensions = ["nginx", "nginxconf"]
            $0.filenames = ["nginx.conf"]
            $0.lineComments = ["#"]
            $0.strings = [dq, sq]
            $0.keywords = words("server location upstream http events listen server_name root index proxy_pass return rewrite include if set try_files error_page access_log error_log worker_processes")
            $0.dollarVariables = true
        }
        add("gitignore", "Ignore File") {
            $0.extensions = ["gitignore", "dockerignore", "npmignore", "eslintignore", "prettierignore"]
            $0.filenames = [".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore", "CODEOWNERS"]
            $0.lineComments = ["#"]
        }
        add("csv", "CSV / TSV", .plain) {
            $0.extensions = ["csv", "tsv", "tab"]
        }
        add("tex", "LaTeX") {
            $0.extensions = ["tex", "sty", "cls", "bib", "ltx"]
            $0.lineComments = ["%"]
        }
        add("clojure", "Clojure / Lisp") {
            $0.extensions = ["clj", "cljs", "cljc", "edn", "lisp", "el", "scm", "rkt"]
            $0.lineComments = [";"]
            $0.strings = [StringRule("\"", multiline: true)]
            $0.keywords = words("def defn defn- defmacro defun defvar let let* fn lambda if when cond do loop recur ns require use import quote setq progn define")
            $0.constants = words("true false nil t")
            $0.hyphenIdentifiers = true
        }
        return list
    }
}
