# EOF agent rules

These override the global worktree and pull-request rules for this repository.

- Commit straight to `main` and push to `origin` (private `luoling8192/eof`). Do not open pull requests; the owner said they are not needed (2026-11-20).
- Write all code on the Linux host. Use the Mac (Lody session) only for Xcode: build, simulator screenshots, archive and TestFlight upload. Send it the code as a `git bundle`, since its GitHub access is unreliable, and never let it edit sources.
- Linux checks: `swiftc -parse $(find App/Sources -name '*.swift')` and `swift test` in `EOFCore`. Lessons for iOS work are in `~/agent-docs/lessons/ios-swift.md`.
