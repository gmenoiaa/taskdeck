# TaskDeck — notes for Claude

Native macOS app (SwiftUI, Swift Package Manager). There is **no Xcode project**: do not create
one, and do not run `xcodebuild`.

## Build and install locally

```bash
./build.sh --install --open
```

That is the only command needed: it builds the release binary, bundles `TaskDeck.app` in
`build/`, stamps the real SDK version (without it macOS runs the app in compatibility mode and
the Liquid Glass design is lost), signs it, copies it to `/Applications` and relaunches it.
`./build.sh` alone only produces `build/TaskDeck.app`.

Things to know:

- `--install` ends the running app with `pkill`, which skips the quit handler, so **a running
  timer keeps running** across the install and counts the few seconds the app was closed. Only a
  normal Quit stops timers (`willTerminate` calls `stopAll`).
- Signing uses the first "Apple Development" or "Developer ID Application" certificate found, so
  the Keychain's "Always Allow" survives rebuilds. Without a certificate it falls back to ad-hoc
  and macOS asks for the Keychain password after every build. Override with `CODESIGN_IDENTITY`.
- `./scripts/make-icon.sh` regenerates the app icon.
- There is no release, notarisation or distribution step. "Publish" here means installing in
  `/Applications` on this machine.
- `swift build` alone is enough to check that the code compiles, but the app in `/Applications`
  is only updated by `./build.sh --install`.

## Verifying

Always build before saying something works. You cannot see the screen: the user sends
screenshots. State plainly which parts you did not verify visually, and never claim that a
Redmine, Jira, GitHub or Claude API call succeeded unless it actually ran.

## Code conventions

- `@Observable @MainActor AppStore` holds everything; views read it from the environment.
- Persistence: `~/Library/Application Support/TaskDeck/data.json` via `AppStore.Snapshot`. Every
  new persisted field is **optional in `Snapshot`** with a default, so old files still load, and
  must be added to both `load()` and `save()`.
- The user sees "spaces"; in code and in `data.json` a space is still a `Project` (`projects`,
  `projectId`). Keep the old names in code so existing files load, and write "space" in UI text.
- Secrets go in the Keychain (service `local.taskdeck`), never in `data.json` or the repository.
- macOS 26 Liquid Glass (`GlassEffectContainer`, `.buttonStyle(.glass)`, `.glassEffect`,
  `ToolbarSpacer`) is always behind `if #available(macOS 26, *)` with a pre-26 fallback. Shared
  helpers live in `Glass.swift`.
- Colours come from `Theme`; `Theme.accent` (red) is the app tint. Neutral controls pass
  `.tint(nil)`.
- Private notes are never sent to the AI — the UI promises this, keep it true.
- The review (`Review.swift`) runs on one Claude Code login for every space, so each space's data
  goes out only at that space's `reviewDetail` level; anything new it sends must respect the level.
- Comments explain *why*, not *what*. User-facing text is plain English, no marketing tone.

## Memory and identity files

This file is the project's own instructions and lives in the repository — it is the first thing
to read and the right place for anything about *this app*: how to build it, its conventions, its
structure.

Claude's memory is somewhere else: `~/.claude/projects/<this-project>/memory/`, outside the
repository and not shared with anyone. One file per fact, with an index in `MEMORY.md`. That is
the place for what the repository cannot show — a preference the user expressed, a correction
they made and why, a link to a dashboard or ticket, an ongoing goal. It is currently empty.

Which file gets what:

- A rule about the code or the build, true for anyone working here → **CLAUDE.md**, committed.
- Something about how the user wants to be worked with, or context that only exists in our
  conversations → **memory**, not committed.
- Never put personal details, API keys or anything about the user's accounts in CLAUDE.md: it is
  public in this repository.

Do not save to memory what the repository already records (file layout, past fixes, git history,
what this file says), or what only matters to one conversation. A memory that names a file or a
flag was true when written — check it still exists before acting on it.

Identity files (`SOUL.md`, `IDENTITY.md`, `USER.md`, `MEMORY.md` at the Alan workspace root) and
the `.alan/` workspace belong to a separate setup and are **not** part of this project. If they
are not there, do not create them here.

## Git

Commit or push only when the user asks for it. Commit messages end with the Co-Authored-By line
from the session's attribution reminder.
