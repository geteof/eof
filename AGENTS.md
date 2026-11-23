# EOF agent rules

These override the global worktree and pull-request rules for this repository.

- Commit straight to `main` and push to `origin` (private `luoling8192/eof`). Do not open pull requests; the owner said they are not needed (2026-11-20).
- Write all code on the Linux host. Use the Mac (Lody session) only for Xcode: build, simulator screenshots, archive and TestFlight upload. Send it the code as a `git bundle`, since its GitHub access is unreliable, and never let it edit sources.
- Linux checks: `swiftc -parse $(find App/Sources -name '*.swift')` and `swift test` in `EOFCore`. Lessons for iOS work are in `~/agent-docs/lessons/ios-swift.md`.
- Every TestFlight build goes to external testers too (owner, 2026-11-23): after upload, check it is in Internal Testers, add it to the external group `Public Beta`, fill in What to Test in en-US and zh-Hans, and submit it for Beta App Review. Keep the public link https://testflight.apple.com/join/uJPkDruK; do not change the review contact or the app's beta description.
- Grammars that TreeSitterLanguages lacks and that have no usable Swift package are vendored in `Grammars/` by `Tools/grammars.py` (pinned revisions; queries rewritten to Runestone's predicates: eq?, not-eq?, match?, not-match?, set!). After changing a dependency, rerun it and `Tools/acknowledgements.py`, and update `ThirdPartyNotices.md`.
