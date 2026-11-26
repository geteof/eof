#!/usr/bin/env python3
"""Builds App/Resources/Acknowledgements.json: the licence text of every third-party project in
the app, read from GitHub at the exact revision the app uses. Run it again when a dependency
or its pin changes. Needs an authenticated `gh`.

    python3 -I Tools/acknowledgements.py
"""
import base64
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent

# name, what EOF uses it for, owner/repo, revision, licence files (first = the project's own)
PROJECTS = [
    ("Runestone", "Text view, line numbers and syntax highlighting", "simonbs/Runestone", "00426ba7f8681a90c1ea0b5c03a0e0bec8cba883", ["LICENSE"]),
    ("TreeSitterLanguages", "Grammars and highlight queries", "simonbs/TreeSitterLanguages", "4442182303a00bf2764b10ead923a1066a0946f6", ["LICENSE", "Licenses/"]),
    ("tree-sitter-kotlin", "Kotlin grammar", "fwcd/tree-sitter-kotlin", "d6af96d2e23ef0a8ff5ab512864378cf08fba311", ["LICENSE"]),
    ("tree-sitter-dockerfile", "Dockerfile grammar", "camdencheek/tree-sitter-dockerfile", "971acdd908568b4531b0ba28a445bf0bb720aba5", ["LICENSE"]),
    ("tree-sitter-ini", "INI grammar", "justinmk/tree-sitter-ini", "e4018b5176132b4f3c5d6e61cea383f42288d0f5", ["LICENSE"]),
    ("swift-markdown", "Markdown parsing for the preview", "swiftlang/swift-markdown", "bc55d614bc8608d74cdc18d3aa6413bd8661e444", ["LICENSE.txt"]),
    ("swift-cmark", "Markdown parsing for the preview", "swiftlang/swift-cmark", "08ddb528923cc1a6527e02b7a1aee9e516ca749a", ["COPYING"]),
    ("tree-sitter-make", "Makefile grammar and highlights", "tree-sitter-grammars/tree-sitter-make", "70613f3d812cbabbd7f38d104d60a409c4008b43", ["LICENSE"]),
    ("tree-sitter-powershell", "PowerShell grammar and highlights", "airbus-cert/tree-sitter-powershell", "65ea6919e816a7ac142acec7ee72757f89db8439", ["LICENSE"]),
    ("tree-sitter-batch", "Batch grammar and highlights", "wharflab/tree-sitter-batch", "2aa22f00d7f5bbe58556b8eef0b1fc1629508603", ["LICENSE"]),
    ("tree-sitter-groovy", "Groovy and Gradle grammar and highlights", "murtaza64/tree-sitter-groovy", "2a6ddd558b6aa39c5b77d8db9fe9baf817486b2c", ["LICENSE"]),
    ("tree-sitter-graphql", "GraphQL grammar and highlights", "bkegley/tree-sitter-graphql", "5e66e961eee421786bdda8495ed1db045e06b5fe", ["LICENSE"]),
    ("tree-sitter-nginx", "Nginx grammar and highlights", "opa-oz/tree-sitter-nginx", "7cdf006ed1addef698fc680ae31721950f85e5e9", ["LICENSE"]),
    ("tree-sitter-zig", "Zig grammar and highlights", "tree-sitter-grammars/tree-sitter-zig", "6479aa13f32f701c383083d8b28360ebd682fb7d", ["LICENSE"]),
    ("tree-sitter-clojure", "Clojure grammar", "sogaiu/tree-sitter-clojure", "e43eff80d17cf34852dcd92ca5e6986d23a7040f", ["COPYING.txt"]),
    ("tree-sitter-gitignore", "Ignore-file grammar", "shunsambongi/tree-sitter-gitignore", "f4685bf11ac466dd278449bcfe5fd014e94aa504", ["LICENSE"]),
    ("nvim-treesitter", "Highlight queries for Clojure and ignore files, and the base of the Kotlin query", "nvim-treesitter/nvim-treesitter", "52773f0d13a0c11d0c3ef33c14ab6ecc1c17148b", ["LICENSE"]),
    ("Mermaid", "Diagrams in the Markdown preview (App/Resources/Mermaid/mermaid.min.js, npm mermaid 12.3.0)", "mermaid-js/mermaid", "2086904e76c692331e34a45d7cc3bc30860d040e", ["LICENSE", "@bundled:App/Resources/Mermaid/mermaid.min.js"]),
    ("DOMPurify", "Bundled in Mermaid; cleans diagram output", "cure53/DOMPurify", "3.4.17", ["LICENSE"]),
    ("Material Icon Theme", "File and folder icons", "material-extensions/vscode-material-icon-theme", "0d17360506c477b4ccb065d8acdbd056331af1fb", ["LICENSE"]),
]


def gh(path):
    return json.loads(subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout)


def text(repo, rev, path):
    item = gh(f"repos/{repo}/contents/{path}?ref={rev}")
    return base64.b64decode(item["content"]).decode("utf-8", "replace").strip()


def files(repo, rev, folder):
    tree = gh(f"repos/{repo}/git/trees/{rev}?recursive=1")["tree"]
    return sorted(i["path"] for i in tree if i["type"] == "blob" and i["path"].startswith(folder) and not i["path"].endswith("README.md"))


entries = []
for name, use, repo, rev, paths in PROJECTS:
    parts = []
    for path in paths:
        if path.startswith("@bundled:"):
            # The licence notes esbuild collected from the libraries inside a bundled script.
            script = (ROOT / path.removeprefix("@bundled:")).read_text()
            block = script[script.rfind("/*! Bundled license information"):]
            parts.append("— Bundled in " + pathlib.PurePath(path).name + " —\n\n" + block.strip())
            continue
        for file in files(repo, rev, path) if path.endswith("/") else [path]:
            body = text(repo, rev, file)
            parts.append(body if file == paths[0] else f"— {pathlib.PurePath(file).stem} —\n\n{body}")
    entries.append({"name": name, "use": use, "url": f"https://github.com/{repo}", "license": "\n\n".join(parts)})
    print(name, len(parts), "file(s)")

out = ROOT / "App/Resources/Acknowledgements.json"
out.write_text(json.dumps(entries, ensure_ascii=False, indent=1) + "\n")
print("wrote", out, out.stat().st_size, "bytes")
