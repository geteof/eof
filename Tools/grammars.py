#!/usr/bin/env python3
"""Vendors the Tree-sitter grammars that neither TreeSitterLanguages nor a usable Swift package
provides. Each grammar's generated C parser is copied, at a pinned revision, into
Grammars/Sources/<Module>/ (a C target of the local EOFGrammars package), and its highlight
query into App/Resources/Queries/<name>.scm, rewritten for Runestone, which only understands the
eq?, not-eq?, match?, not-match? and set! predicates. Needs an authenticated `gh`.

    python3 -I Tools/grammars.py
"""
import io
import json
import pathlib
import re
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NVIM = ("nvim-treesitter/nvim-treesitter", "52773f0d13a0c11d0c3ef33c14ab6ecc1c17148b")

# query name, module, repo, revision, highlight query: path in the grammar repo, or ("nvim", language)
GRAMMARS = [
    ("make", "TreeSitterMakeEOF", "tree-sitter-grammars/tree-sitter-make", "70613f3d812cbabbd7f38d104d60a409c4008b43", "queries/highlights.scm"),
    ("powershell", "TreeSitterPowerShellEOF", "airbus-cert/tree-sitter-powershell", "65ea6919e816a7ac142acec7ee72757f89db8439", "queries/highlights.scm"),
    ("batch", "TreeSitterBatchEOF", "wharflab/tree-sitter-batch", "2aa22f00d7f5bbe58556b8eef0b1fc1629508603", "queries/highlights.scm"),
    ("groovy", "TreeSitterGroovyEOF", "murtaza64/tree-sitter-groovy", "2a6ddd558b6aa39c5b77d8db9fe9baf817486b2c", "queries/highlights.scm"),
    ("graphql", "TreeSitterGraphQLEOF", "bkegley/tree-sitter-graphql", "5e66e961eee421786bdda8495ed1db045e06b5fe", "queries/graphql/highlights.scm"),
    ("nginx", "TreeSitterNginxEOF", "opa-oz/tree-sitter-nginx", "7cdf006ed1addef698fc680ae31721950f85e5e9", "queries/highlights.scm"),
    ("zig", "TreeSitterZigEOF", "tree-sitter-grammars/tree-sitter-zig", "6479aa13f32f701c383083d8b28360ebd682fb7d", "queries/highlights.scm"),
    ("clojure", "TreeSitterClojureEOF", "sogaiu/tree-sitter-clojure", "e43eff80d17cf34852dcd92ca5e6986d23a7040f", ("nvim", "clojure")),
    ("gitignore", "TreeSitterGitignoreEOF", "shunsambongi/tree-sitter-gitignore", "f4685bf11ac466dd278449bcfe5fd014e94aa504", ("nvim", "gitignore")),
]

LUA_CLASSES = {"a": "A-Za-z", "d": "0-9", "l": "a-z", "u": "A-Z", "w": "A-Za-z0-9", "x": "0-9A-Fa-f", "s": r"\s", "p": r"\p{P}"}


def lua_to_regex(pattern):
    """Lua patterns as nvim-treesitter's queries use them, as ICU regular expressions."""
    out, i, in_set = [], 0, False
    while i < len(pattern):
        c = pattern[i]
        if c == "%" and i + 1 < len(pattern):
            n = pattern[i + 1]
            i += 2
            if n.lower() in LUA_CLASSES:
                body = LUA_CLASSES[n.lower()]
                if n.isupper():  # complement
                    out.append(body.upper().replace(r"\S", r"\S") if body.startswith("\\") else f"[^{body}]")
                    if body.startswith("\\"):
                        out[-1] = "\\" + body[1].upper()
                else:
                    out.append(body if in_set or body.startswith("\\") else f"[{body}]")
            else:
                out.append("\\" + n)
            continue
        if c == "[":
            in_set = True
        elif c == "]" and in_set:
            in_set = False
        elif c == "-" and not in_set and out and out[-1] not in ("^",):
            out.append("*?")  # Lua's lazy repetition
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def scm_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def strip_comments(query):
    """Drops ; comments (outside strings): lists of words in nvim-treesitter queries carry them."""
    out, in_string, i = [], False, 0
    while i < len(query):
        c = query[i]
        if in_string:
            out.append(c)
            if c == "\\":
                out.append(query[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif c == ";":
            while i < len(query) and query[i] != "\n":
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def adapt(query):
    """Rewrites any-of? and lua-match? into match?, which Runestone evaluates."""
    query = strip_comments(query)
    def any_of(m):
        capture, rest = m.group(1), m.group(2)
        words = [json.loads(w) for w in re.findall(r'"(?:[^"\\]|\\.)*"', rest)]
        return f"(#match? {capture} {scm_string('^(' + '|'.join(re.escape(w) for w in words) + ')$')})"

    query = re.sub(r"\(#any-of\?\s+(@[\w.]+)((?:\s+\"(?:[^\"\\]|\\.)*\")+)\s*\)", any_of, query, flags=re.S)

    def lua(m):
        return f"(#match? {m.group(1)} {scm_string(lua_to_regex(json.loads(m.group(2))))})"

    query = re.sub(r"\(#lua-match\?\s+(@[\w.]+)\s+(\"(?:[^\"\\]|\\.)*\")\s*\)", lua, query)
    left = set(re.findall(r"#([a-z-]+[?!])", query)) - {"eq?", "not-eq?", "match?", "not-match?", "set!"}
    if left:
        raise SystemExit(f"unsupported predicates left: {left}")
    return query


def tarball(repo, rev):
    data = subprocess.run(["gh", "api", f"repos/{repo}/tarball/{rev}"], check=True, capture_output=True).stdout
    return tarfile.open(fileobj=io.BytesIO(data))


def read(archive, path):
    for member in archive.getmembers():
        if member.isfile() and member.name.split("/", 1)[-1] == path:
            return archive.extractfile(member).read()
    return None


nvim = tarball(*NVIM)
for name, module, repo, rev, query_source in GRAMMARS:
    archive = tarball(repo, rev)
    target = ROOT / "Grammars/Sources" / module
    (target / "tree_sitter").mkdir(parents=True, exist_ok=True)
    (target / "include").mkdir(exist_ok=True)
    copied = []
    for member in archive.getmembers():
        rel = member.name.split("/", 1)[-1]
        if not member.isfile() or not rel.startswith("src/"):
            continue
        inner = rel[len("src/"):]
        if inner in ("parser.c", "scanner.c", "scanner.cc") or (inner.startswith("tree_sitter/") and inner.endswith(".h")):
            if inner == "scanner.cc":
                raise SystemExit(f"{name}: C++ scanner")
            (target / inner).write_bytes(archive.extractfile(member).read())
            copied.append(inner)
    licence = next((read(archive, p) for p in ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING.txt", "COPYING") if read(archive, p)), None)
    (target / "LICENSE").write_bytes(licence)
    symbol = re.search(rb"TSLanguage \*(tree_sitter_\w+)\(void\)", (target / "parser.c").read_bytes()).group(1).decode()
    abi = int(re.search(rb"#define LANGUAGE_VERSION (\d+)", (target / "parser.c").read_bytes()).group(1))
    assert 13 <= abi <= 15, (name, abi)
    (target / "include" / f"{module}.h").write_text(
        f"#ifndef {module.upper()}_H\n#define {module.upper()}_H\n\n"
        "typedef struct TSLanguage TSLanguage;\n\n"
        f"/// {repo} at {rev[:12]}, Tree-sitter ABI {abi}.\nconst TSLanguage *{symbol}(void);\n\n#endif\n")
    if isinstance(query_source, tuple):
        raw = read(nvim, f"runtime/queries/{query_source[1]}/highlights.scm")
        origin = f"nvim-treesitter ({NVIM[0]} at {NVIM[1][:12]}), Apache-2.0"
    else:
        raw = read(archive, query_source)
        origin = f"{repo} at {rev[:12]}"
    header = f"; Highlights for {name}, from {origin}.\n; Rewritten by Tools/grammars.py for the predicates Runestone supports.\n\n"
    (ROOT / "App/Resources/Queries" / f"{name}.scm").write_text(header + adapt(raw.decode()))
    print(f"{name:11} {symbol:24} ABI {abi}  {', '.join(sorted(copied))}")
