# TaskDeck

A native macOS app (SwiftUI) to manage the tasks I work on across several trackers.

- Kanban board with configurable columns
- Per-task timers, with a menu bar item showing what is running
- Redmine, Jira and GitHub: ticket details, comments, status and assignee, "Assigned to me" import
- Redmine: log tracked time to the issue
- Private notes per task
- Goals: group tasks from any space with the notes, links and files that go with them
- "Explain" a ticket in simple words with the Claude API

## Build

Requires Xcode (Swift 5.9+) on macOS 14 or later.

```bash
./build.sh --install --open
```

This builds a release binary, bundles `TaskDeck.app`, signs it and installs it in `/Applications`.
`./scripts/make-icon.sh` regenerates the app icon.

## Data

Tasks and settings live in `~/Library/Application Support/TaskDeck/data.json`.
API keys and tokens are stored in the macOS Keychain, never in that file or in this repository.
