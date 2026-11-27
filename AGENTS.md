# EOF agent rules

These override the global worktree and pull-request rules for this repository.

- Commit straight to `main` and push to `origin` (private `luoling8192/eof`). Do not open pull requests; the owner said they are not needed (2026-11-20).
- Work in a worktree (`.worktrees/<branch>`) even so, and push with `git push origin HEAD:main`: other sessions use the main checkout, and Claude Code auto mode blocks edits there and asks the owner to approve each push to `main`.
- `swiftc -parse` does not resolve names. Several sessions push to `main`, so send every pushed commit to a Mac Debug build at once, and before deleting a symbol as unused, fetch and grep `origin/main` again right before pushing.
- Verify a UI change by doing the gesture or command a user would (select all, scroll a short file, open each sample type), not only by launching into a state.
- Write all code on the Linux host. Use the Mac (Lody session) only for Xcode: Debug builds and simulator screenshots. Send it the code as a `git bundle`, since its GitHub access is unreliable, and never let it edit sources.
- Linux checks: `swiftc -parse $(find App/Sources -name '*.swift')` and `swift test` in `EOFCore`. Lessons for iOS work are in `~/agent-docs/lessons/ios-swift.md`.
- Release through GitHub Actions (`.github/workflows/release.yml`, owner 2026-11-27): write What to Test in `Release/notes.json` (en-US and zh-Hans), push it to `main`, then push a tag `v<MARKETING_VERSION>-<build number>`. The workflow archives on the `xcode-27` runner, uploads, adds the build to the external group `Public Beta`, sets What to Test, submits it for Beta App Review and creates the GitHub release. Every TestFlight build goes to external testers too (owner, 2026-11-23). Keep the public link https://testflight.apple.com/join/uJPkDruK; do not change the review contact or the app's beta description.
- Grammars that TreeSitterLanguages lacks and that have no usable Swift package are vendored in `Grammars/` by `Tools/grammars.py` (pinned revisions; queries rewritten to Runestone's predicates: eq?, not-eq?, match?, not-match?, set!). After changing a dependency, rerun it and `Tools/acknowledgements.py`, and update `ThirdPartyNotices.md`.
