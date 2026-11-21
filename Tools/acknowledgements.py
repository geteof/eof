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
    ("ZIPFoundation", "Zip archives", "weichsel/ZIPFoundation", "86fc841708997c5bce8545e23845125f4eb28493", ["LICENSE"]),
    ("SWCompression", "TAR, GZIP, BZIP2, XZ and 7-Zip", "tsolomko/SWCompression", "03a68e67991815a267e28174a0a01fbe0cff937b", ["LICENSE"]),
    ("BitByteData", "Used by SWCompression", "tsolomko/BitByteData", "e1a5443be67daf0833cbb5f4fa3a06a265ca3105", ["LICENSE"]),
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
        for file in files(repo, rev, path) if path.endswith("/") else [path]:
            body = text(repo, rev, file)
            parts.append(body if file == paths[0] else f"— {pathlib.PurePath(file).stem} —\n\n{body}")
    entries.append({"name": name, "use": use, "url": f"https://github.com/{repo}", "license": "\n\n".join(parts)})
    print(name, len(parts), "file(s)")

out = ROOT / "App/Resources/Acknowledgements.json"
out.write_text(json.dumps(entries, ensure_ascii=False, indent=1) + "\n")
print("wrote", out, out.stat().st_size, "bytes")
