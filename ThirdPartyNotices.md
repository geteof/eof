# Third-party code

EOF builds on these projects. Each keeps its own licence; the full texts are in the linked repositories.

| Project | Used for | Licence |
| --- | --- | --- |
| [Runestone](https://github.com/simonbs/Runestone) | Text view, line numbers, Tree-sitter highlighting | MIT |
| [TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages) | Grammars and highlight queries for most languages | MIT (each grammar under its own licence) |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) and [swift-cmark](https://github.com/swiftlang/swift-cmark) | Markdown parsing for the preview | Apache-2.0, BSD-2-Clause |
| [tree-sitter-kotlin](https://github.com/fwcd/tree-sitter-kotlin) | Kotlin grammar; `App/Resources/Queries/kotlin.scm` is its highlight query, itself based on nvim-treesitter (Apache-2.0) | MIT |
| [tree-sitter-dockerfile](https://github.com/camdencheek/tree-sitter-dockerfile) | Dockerfile grammar; `App/Resources/Queries/dockerfile.scm` is its highlight query | MIT |
| [tree-sitter-ini](https://github.com/justinmk/tree-sitter-ini) | INI grammar; `App/Resources/Queries/ini.scm` is its highlight query | Apache-2.0 |
| [tree-sitter-make](https://github.com/tree-sitter-grammars/tree-sitter-make), [tree-sitter-powershell](https://github.com/airbus-cert/tree-sitter-powershell), [tree-sitter-batch](https://github.com/wharflab/tree-sitter-batch), [tree-sitter-groovy](https://github.com/murtaza64/tree-sitter-groovy), [tree-sitter-graphql](https://github.com/bkegley/tree-sitter-graphql), [tree-sitter-nginx](https://github.com/opa-oz/tree-sitter-nginx), [tree-sitter-zig](https://github.com/tree-sitter-grammars/tree-sitter-zig), [tree-sitter-gitignore](https://github.com/shunsambongi/tree-sitter-gitignore) | Makefile, PowerShell, Batch, Groovy, GraphQL, Nginx, Zig and ignore-file grammars, vendored in `Grammars/Sources/` with each licence beside the sources; their highlight queries are in `App/Resources/Queries/`. Made by `Tools/grammars.py` | MIT |
| [tree-sitter-clojure](https://github.com/sogaiu/tree-sitter-clojure) | Clojure grammar, vendored in `Grammars/Sources/TreeSitterClojureEOF` | CC0-1.0 |
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | Highlight queries for Clojure and ignore files (`App/Resources/Queries/clojure.scm`, `gitignore.scm`), rewritten for Runestone's predicates | Apache-2.0 |
| [Mermaid](https://github.com/mermaid-js/mermaid) 12.3.0 | Diagrams in the Markdown preview: `App/Resources/Mermaid/mermaid.min.js` is the npm package's `dist/mermaid.min.js`, unchanged. It bundles DOMPurify (Apache-2.0 or MPL-2.0), lodash, cytoscape, d3 and others; their notices are at the end of that file and in the app's acknowledgements | MIT |
| [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme) 5.40.0 | File and folder icons in `App/Resources/MaterialIcons.xcassets`, made by `Tools/material-icons.py` from the npm package. The same set the "Material Icons for GitHub" browser extension uses | MIT |
