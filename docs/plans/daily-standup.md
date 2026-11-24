# Plan: daily standup updates per space

## What it does

Each space that has a daily standup gets its own update: **Yesterday / Today / Blockers**,
written by Claude from what TaskDeck already knows about that space, shown in an editable box
with a **Copy** button so it can be pasted into Slack, Teams or the meeting chat. Nothing is
posted anywhere by the app.

Decided with the user:

- Destination: copy to paste. No Slack/Teams integration.
- Writer: Claude, from facts the app gathers. Without an API key, a plain list built from the
  same facts.
- Per space: on/off, meeting time, which weekdays, a reminder before the meeting, and the
  space's own instructions (language, format, length).
- Period: "since the last workday" — from the previous scheduled standup of that space until now
  (Monday covers Friday onward).

## What the app knows today, and the gap

| Standup part | Source already in the app |
| --- | --- |
| Yesterday | `TimeEntry`s inside the period (`TaskItem.tracked(in:now:)`), agent sessions (`AgentSession.startedAt`, Orca status: PR open/merged), tracker status (`remoteStatus`), cached ticket comments (`TicketCache`) |
| Today | Running timer, tasks in `.inProgress` / `.normal` columns, top of `.backlog`, `due` today/tomorrow, newly assigned tickets (`assignedTickets`) |
| Blockers | Sessions in `.yourTurn`, tasks in `.watching`, tracker statuses that read as waiting/blocked/feedback, overdue tasks |

**Gap:** the board keeps no history of column moves. `move(_:to:)` overwrites `status`, so
"finished X yesterday" or "moved Y to review" cannot be told apart from older work. Phase 1
adds a small move log. It only knows moves made after the feature ships; time entries cover
most of the rest.

## Phase 1 — Data model and persistence

`Models.swift`

- `struct StandupSettings: Codable, Hashable` with a custom `init(from:)` using
  `decodeIfPresent` for every field (same pattern as `NotificationSettings`), so fields added
  later do not drop the whole value:
  - `enabled = false`
  - `hour = 10`, `minute = 0` — meeting time, local
  - `weekdays: [Int] = [2, 3, 4, 5, 6]` — `Calendar` weekday numbers, Mon–Fri
  - `remindMinutes = 10` — 0 means no reminder
  - `instructions = ""` — this space's style
- `Project.standup: StandupSettings?` — optional, like every newer `Project` field.
- `struct ColumnMove: Codable, Hashable { var column: String; var at: Date }` and
  `TaskItem.moves: [ColumnMove]?`, capped at the last 10.
- `struct StandupNote: Codable, Hashable { var text: String; var at: Date; var since: Date }` —
  the last update written for a space.
- Helper on `StandupSettings`: `previousOccurrence(before:)` and `nextOccurrence(after:)`,
  walking days back/forward until a day in `weekdays`. With no weekdays ticked, fall back to the
  previous calendar day at the meeting time.

`Store.swift`

- `var standups: [UUID: StandupNote] = [:]` (by space id) and
  `@ObservationIgnored var standupRemindedAt: [UUID: Date] = [:]`.
- `Snapshot`: `standups: [String: StandupNote]?` and `standupRemindedAt: [String: Date]?` (UUID
  keys as strings, so the JSON stays an object). Add both to `load()` and `save()`.
- Record a `ColumnMove` in `move(_:to:)` and anywhere else `status` changes column (starting a
  timer from the backlog, the agent queue moving a card to In progress). Find them with
  `grep -n "\.status = " Sources/TaskDeck/*.swift`.
- `func setStandup(_ spaceId: UUID, _ note: StandupNote)`.

## Phase 2 — Space settings

`ProjectsView.swift` → `ProjectEditor`: new `Section("Daily standup")`

- Toggle "This space has a daily standup".
- When on: time picker (hour and minute), seven small weekday toggles (M T W T F S S, starting
  from the locale's first weekday), "Remind me" picker (Off, 5, 10, 15, 30 minutes before).
- "Instructions for this space's standup" `TextEditor`, prompt text:
  "e.g. In Portuguese. Three bullets per part at most. No time figures."
- Footer: "Added to the instructions in Settings → AI. Where they disagree, these win."

`SettingsView.swift` → Notifications tab: one toggle "Standup reminders" backed by
`NotificationSettings.standup = true` (decoded with `decodeIfPresent`). The per-space reminder
minutes still apply; this is the global off switch.

## Phase 3 — Facts and the Claude prompt

`Claude.swift`

- `static let standupSystem` — first person, plain English (or the language the instructions
  ask for), short. Use only the facts given; never invent work. Three parts in this order:
  **Yesterday**, **Today**, **Blockers** (write "None" rather than leave Blockers out). Bullets,
  no headings above level of bold labels, so the text pastes cleanly into chat. No time figures
  unless the instructions ask for them. Ticket numbers as written. Start with the first label.
- `@MainActor static func standupText(space:period:store:) -> String`, modelled on `goalText`:
  - Header: space name, tracker kind, today's date, the period ("since Friday 10:00").
  - The space's previous standup's text (`store.standups[space.id]`) as context, so "Today"
    from last time can become "Yesterday" now.
  - Per task, only tasks of this space: ref, title, column (and role), tracker status, type,
    assignee, due, time tracked **in the period**, moves in the period, agent session states,
    the last 2 cached comments dated inside the period.
  - Grouped as "Worked on in the period", "On the board now", "Waiting or blocked".
  - **Never** `task.notes`, the goal's notes, or anything from other spaces. A task's `draft` is
    left out too: a standup is not where it should leave the app first.
- Instructions layering: `Claude.system(standupSystem, custom: store.aiInstructions)` and then a
  second block `<space_instructions>` for the space's own text, stated to win over both. Add an
  overload `system(_:custom:space:)` rather than concatenating strings at the call site.
- `enum StandupPlain { static func text(space:period:store:) -> String }` — the no-key fallback:
  the same facts, as three bullet lists, no AI. Lives next to the facts builder so both read the
  same data.

`stream()` already sets effort low and handles refusals; no change there.

## Phase 4 — Standup view and entry points

New `StandupView.swift` (sheet):

- Title "Standup — <space>", a line "Since Fri 10:00" with a small date picker to widen or narrow
  the period, then regenerate.
- The text: streams into view, then becomes an editable `TextEditor`. Shows the last saved note
  first if it was written today, instead of calling Claude again.
- Buttons: **Copy** (plain text to `NSPasteboard`; saves the note), **Write again**, **Close**
  (saves edits). If there is no key: the plain fallback plus "Set a Claude API key in
  Settings → AI to have Claude write it."
- Footer, as on the goal box: "Sent to Claude: this space's tasks, their tracker status, time and
  recent comments as last read. Notes are not sent."

Entry points:

- **Overview tab** (`OverviewView`), top of the page:
  - One space selected and its standup on → a box like `standingBox` in `GoalsView`: next
    meeting time, last update's first lines, "Write standup" button.
  - "All spaces" → one compact row per space with a standup: name, colour dot, next time
    ("today 10:00", "Mon 09:30"), button. Hidden when no space has one.
- **Menu bar** (`MenuBarView`): from 30 minutes before a space's standup until 30 minutes after,
  a row "Standup at 10:00 — <space>" that opens the sheet.
- **Command**: `AppCommands` item "Write Standup…" (⌘⇧S if free) for the space being shown;
  disabled with "All spaces" or when the space has no standup.

Opening the sheet from outside the board (menu bar, notification) goes through one store
property, `var openStandup: UUID?`. `BoardView` watches it: brings the main window forward
(`openWindow(id: "main")` if it was closed), sets `filter` to the space, `tab = "overview"`,
presents the sheet, and clears the property.

## Phase 5 — Reminder

`Notifications.swift`

- In `noticeTimers()`, **before** the unlogged block: that block ends with
  `guard seconds >= 60 else { return }`, which would skip anything after it.
- For each space with `standup.enabled`, `remindMinutes > 0`, `notify.standup` on: if today is in
  `weekdays` and `now` is in `[meeting − remindMinutes, meeting)` and `standupRemindedAt[space]`
  is not today → send "Standup at 10:00 — <space>", body "Your update is ready to write.", record
  the date, `save()`.
- Skip while `awaySince != nil` (the Mac is asleep or locked; a late banner is noise).
- `Notifier.send` gets an optional `standup: UUID?` that goes into `userInfo`; the `didReceive`
  handler sets `store.openStandup` through a new `Notifier.onStandup` closure, the same way
  `onStart` works. Clicking the banner body (default action) opens it; no extra button needed.

Open choice for the user (default in brackets): pre-write the update when the reminder fires, so
it is ready when the banner is clicked [no — write on open; it streams in a few seconds and avoids
a daily API call on days the user skips the meeting].

## Phase 6 — Build and check

1. `swift build` after each phase.
2. `./build.sh --install --open`.
3. Load an existing `data.json` (no `standup`, `moves`, `standups` keys) and confirm everything
   still loads — back it up first.
4. Ask the user for screenshots of: the space editor section, the Overview box and the "All
   spaces" rows, the sheet with a generated update, the menu bar row.
5. A real Claude call needs the user's API key; only claim it works after it actually ran. The
   notification can be tested by setting a space's meeting to a few minutes ahead.

Not covered by the plan, on purpose: posting to Slack/Teams, a history of past standups (only the
last one per space is kept), standups that combine several spaces.

## Files touched

- `Models.swift` — `StandupSettings`, `ColumnMove`, `StandupNote`, new optional fields
- `Store.swift` — `standups`, `standupRemindedAt`, `openStandup`, Snapshot, move log
- `Claude.swift` — `standupSystem`, `standupText`, `system(_:custom:space:)`
- `StandupView.swift` — new
- `StandupPlain` — in `StandupView.swift` or a small `Standup.swift` with the period helpers
- `OverviewView.swift`, `MenuBarView.swift`, `BoardView.swift`, `App.swift` (command)
- `ProjectsView.swift`, `SettingsView.swift`, `Notifications.swift`
- `README.md` — one bullet
