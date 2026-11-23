// swift-tools-version:5.9
import PackageDescription

/// Tree-sitter grammars vendored by Tools/grammars.py: generated C parsers at pinned upstream
/// revisions, one C target each, with their upstream licence beside the sources.
let grammars = [
    "TreeSitterMakeEOF", "TreeSitterPowerShellEOF", "TreeSitterBatchEOF", "TreeSitterGroovyEOF", "TreeSitterGraphQLEOF",
    "TreeSitterNginxEOF", "TreeSitterZigEOF", "TreeSitterClojureEOF", "TreeSitterGitignoreEOF",
]

let package = Package(
    name: "EOFGrammars",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: grammars.map { .library(name: $0, targets: [$0]) },
    targets: grammars.map { name in
        .target(
            name: name,
            path: "Sources/\(name)",
            exclude: ["LICENSE"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        )
    }
)
