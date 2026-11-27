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
- `--install` refuses when the branch is behind `origin/main`: an older app saves `data.json`
  without the fields it does not know, so it silently drops newer settings. Merge or rebase on
  main first; `ALLOW_BEHIND_MAIN=1` overrides only when losing those fields is acceptable.
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
- Records sync between Macs one by one (`Sync.swift`, `SyncRecords.swift`): tasks, spaces, goals,
  standup notes, columns and `SyncedSettings`. A new field is synced unless it names something on
  one Mac (a path, a Claude home, a runner, a browser, a session): then add it to `synced` and
  `keepingMachineFields` there, and keep it out of `SyncedSettings`. Raise `SyncSchema.current`
  whenever a saved field is added or changes meaning: a build never saves over a file from a newer
  version, and merging refuses copies of another version.
- Save stamps each synced record that changed since the last save (`SyncMerge.stamp`), so code
  that edits data needs no stamping of its own; it only has to call `save()`.
- A running timer belongs to the Mac that started it (`TimeEntry.machine`): stopping all, quitting
  and the away cut-off touch only this Mac's.
- Macs sync over Tailscale (`PeerSync.swift`, `PeerNetwork.swift`, `PeerProtocol.swift`): one
  signed round trip per sync, on port 47621 of this Mac's Tailscale address only. Every request
  and answer is signed with the pairing secret (Keychain `sync-secret`), with a time window, a
  random value per request and a replay check; keep all of that on any new route. The listener
  uses BSD sockets: a Network framework listener on the Tailscale address never completed its
  connections. Merged-in records are saved with the sender's stamps (`mergeIn`), never as local
  edits. `TaskDeck serve <file> [port]` and `TaskDeck sync <file> <peer>` are a data-file peer for
  testing on one Mac; run them from the installed app (`/Applications/TaskDeck.app/Contents/MacOS/TaskDeck`),
  since the firewall drops an unsigned debug build.
- Each Mac publishes its own sessions as the record `host:<Machine.id>` (`Hosts.swift`), which
  only that Mac writes; `applying` never takes this Mac's own from another. Other Macs' sessions
  come back as `AgentSession` with `host` set (`isRemote`): `Runners.of` returns nil for them, so
  nothing opens, stops or removes them here, and notifications skip them. A queued task carries
  `runOn`, set when it enters the queue; only that Mac's queue starts it. `TASKDECK_MACHINE_ID`
  gives a test peer on the same Mac its own identity.
- `swift test` runs the tests in `Tests/TaskDeckTests`.
- The user sees "spaces"; in code and in `data.json` a space is still a `Project` (`projects`,
  `projectId`). Keep the old names in code so existing files load, and write "space" in UI text.
- A task's pull requests are saved on it (`TaskItem.pullRequests`). `recordPullRequests` adds what
  Orca and the branch lookup report and never removes one; `refreshPullRequestStatuses` reads each
  from GitHub through `gh`. Cards, the detail tab, the bell and the notifications read that saved
  list, not `SessionStatus`, which knows one pull request per worktree and only while its runner answers.
- Agent sessions run through a `SessionRunner` (`Sessions.swift`); Orca is `OrcaRunner` (`Orca.swift`).
  Views and the store go through the runner or `Runners`, never a runner type directly, and hide what
  a runner's `capabilities` lack. The runner and the agent resolve session, then space
  (`Project.sessionRunner` / `sessionAgent`), then app default. `gh` and `git` calls live in
  `GitHub.swift`, not in a runner. `Project.orcaRepoIds` are Orca's own ids and mean nothing to
  another runner; other runners' ticked repositories are in `Project.runnerRepoIds`.
- `ClaudeCodeRunner` runs `claude --bg --worktree <name>` in the repository and reads
  `claude agents --json --all` (per Claude home) for status; never parse `~/.claude/jobs` or the
  daemon's files, which Claude Code calls internal. Its worktree ids are `claude-code:<short id>`
  (plus `@<home>` for a non-default Claude home). The folders and homes it knows are in
  `claude-code.json` beside `data.json`. A repository Claude Code has not been trusted in refuses
  to start a session: the user runs `claude` there once.
- `claude --bg` hands the session to a background service that keeps the environment it started
  with, so environment variables set when starting a session do not reach it (only
  `CLAUDE_CONFIG_DIR` works, because each home has its own service). The GitHub account goes in a
  `--settings` SessionStart hook that writes `export GH_TOKEN="$(gh auth token --user …)"` to the
  session's env file: the command, never the token, since that file stays on disk world-readable.
- Secrets go in the Keychain (service `local.taskdeck`), never in `data.json` or the repository.
- Every notification goes through `Notifier.send(kind:…)`: a banner on this Mac, and the same text
  to each `NotificationChannel` (`NotificationChannels.swift`) that is on and takes that kind
  (`NotificationSettings.channels`). A new service is one type in `Notifier.channels`; its keys go
  in the Keychain, and its settings text says what leaves the Mac. Buttons (Snooze, Start Timer)
  exist only on the Mac banner.
- macOS 26 Liquid Glass (`GlassEffectContainer`, `.buttonStyle(.glass)`, `.glassEffect`,
  `ToolbarSpacer`) is always behind `if #available(macOS 26, *)` with a pre-26 fallback. Shared
  helpers live in `Glass.swift`.
- Colours come from `Theme`; `Theme.accent` (red) is the app tint. Neutral controls pass
  `.tint(nil)`.
- A task's notes (`TaskItem.noteList`) go to Claude in two places only: the review, where the
  space's `reviewDetail` is above status only, and the standup update. No other AI feature gets
  them (explain, estimate, ticket drafts, goals, agent sessions), and a goal's own notes are never
  sent at all. The UI says exactly this (`NotesEditor`, the review and standup captions) — keep
  the text and the code in step.
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
