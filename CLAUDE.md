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

- `--install` kills the running app first, so **any running timer is stopped** (quitting calls
  `stopAll`). Say so when you install while the user may have a timer on.
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
- Secrets go in the Keychain (service `local.taskdeck`), never in `data.json` or the repository.
- macOS 26 Liquid Glass (`GlassEffectContainer`, `.buttonStyle(.glass)`, `.glassEffect`,
  `ToolbarSpacer`) is always behind `if #available(macOS 26, *)` with a pre-26 fallback. Shared
  helpers live in `Glass.swift`.
- Colours come from `Theme`; `Theme.accent` (red) is the app tint. Neutral controls pass
  `.tint(nil)`.
- Private notes are never sent to the AI — the UI promises this, keep it true.
- Comments explain *why*, not *what*. User-facing text is plain English, no marketing tone.

## Git

Commit or push only when the user asks for it. Commit messages end with the Co-Authored-By line
from the session's attribution reminder.
