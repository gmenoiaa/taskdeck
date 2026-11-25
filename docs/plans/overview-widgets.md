# Plan: overview widgets, period navigation and charts

## What it does

The overview becomes a set of **widgets** the user arranges: reorder them, hide the ones they do
not want, bring them back later. The time widgets stop being fixed on "this week": a period bar
moves back and forward through days, weeks and months, and a calendar jumps to any day. The
hand-drawn bars are replaced with real charts.

Decided with the user:

- One layout for the whole app, not one per space.
- A daily hours target, set per space. "All spaces" uses the sum of the spaces' targets.
- "This week by space" and "Most time this week" stay as widgets of their own. Once the chart
  and the breakdown exist (phase 3) they are hidden by default, and can be shown again.

## Where it stands today

- `OverviewView.swift` is one view with a fixed `VStack`: standup, time, agent sessions, goals,
  "This week by space", "Most time this week", "On the board". Each is a private function.
- Everything is computed for `now`: `today` and `week` are derived in `body`, and nothing else
  can be looked at.
- The week bars are `RoundedRectangle`s sized by hand. No chart framework is used anywhere.
- `store.now` ticks every second, so the whole overview is recomputed every second. Today that
  is 7 days x all tasks; a month view with per-space breakdown would be about 30x that.
- This branch is one merge behind `main` (the daily standup, PR #16). **Rebase first**: the
  standup section is one of the widgets.

## Phase 1 — Widgets: reorder, hide, show

**Done**, with two differences from what follows: the widgets are still functions inside
`OverviewView.swift` (the split into one view per widget waits for phase 2, which rewrites the
time widgets anyway), and the layout model lives in `OverviewLayout.swift`. The widgets so far
are `standup`, `time`, `chart`, `sessions`, `goals`, `bySpace`, `topTasks`, `board`.

`Models.swift`

- `enum OverviewWidget: String, Codable, CaseIterable, Identifiable` — `standup`, `time`,
  `chart`, `calendar`, `breakdown`, `sessions`, `goals`, `bySpace`, `topTasks`, `due`, `unlogged`, `board`. Each has a
  `title` and a `symbol` for the customise list.
- `struct OverviewSlot: Codable, Hashable { var id: String; var hidden: Bool }`. The id is a
  string, not the enum, so a file written by a newer build with a widget this build does not
  know still loads; unknown ids are skipped when reading.
- `static let defaultLayout: [OverviewSlot]` — today's order, with the new widgets placed where
  they make sense and `calendar`, `due`, `unlogged` hidden to start with.

`Store.swift`

- `var overviewLayout: [OverviewSlot]`, optional in `Snapshot` (`overviewLayout:
  [OverviewSlot]?`), added to `load()` and `save()`.
- `resolvedLayout`: the saved slots that are still known, followed by any widget missing from
  the file (a widget added in a later version appears at its default place instead of being
  lost).
- `moveWidget(from:to:)`, `setWidget(_:hidden:)`, `resetOverviewLayout()`.

`OverviewView.swift` → split into `Overview/`

- One small `View` struct per widget (`OverviewTimeWidget`, `OverviewChartWidget`, …) instead of
  private functions, so each only observes what it reads.
- `OverviewView` becomes `ForEach(store.resolvedLayout.filter { !$0.hidden })` with a `switch`
  over the widget.
- A widget with nothing to show still collapses, as today (no goals → no Goals section).
  In customise mode it shows as an empty placeholder so it can still be moved.

Customising

- A **Customise** button at the top right of the overview (glass on macOS 26, plain before).
- In customise mode every widget gets a header strip with a drag handle and an eye button; the
  content is dimmed and does not take clicks. Drag to reorder with `.draggable` /
  `.dropDestination`, the same mechanism the board cards use.
- Hidden widgets are listed at the bottom under "Hidden", each with an **Add** button.
- **Reset to default** and **Done**.
- Outside customise mode, a right-click on a widget title offers Hide, Move up, Move down — also
  the keyboard-reachable path, since drag is mouse-only.

"This week by space" and "Most time this week" become the `bySpace` and `topTasks` widgets,
unchanged. They follow the selected period once phase 2 adds it.

## Phase 2 — Period navigation and charts

**Done**, with these differences from what follows:

- The period steps with ⌘[ and ⌘], not the plain arrow keys, which text fields need.
- The widgets are still functions in `OverviewView.swift`; only the chart is its own view
  (`OverviewChart.swift`). The period and the aggregation are in `OverviewPeriod.swift`.
- No legend under the chart: the "By space" widget stays and carries the same figures.
- A period that is over is still recomputed every second with the rest of the overview. The
  single pass over the entries makes that cheap; rounding `now` to the minute is left for when
  it shows up as a cost.
- The tiles are Today (while the current week or month is shown), the period's total, the
  average per worked day, and the unlogged time.

`OverviewPeriod` (new, in `Overview/`)

- `enum Scale { day, week, month }` and an anchor `Date`; gives the `DateInterval`, a label
  ("Today", "Mon 23 Nov", "16–22 Nov", "November 2026") and `previous` / `next`.
- Held as `@State` in `OverviewView`, not persisted: the overview opens on the current week
  every time, which is what it is for.

Period bar (top of the overview, beside Customise)

- `‹` `›` buttons, a **Today** button that appears once you have moved away, and a
  Day / Week / Month segmented control. Left and right arrow keys step the period.
- Widgets that follow the period: `time`, `chart`, `breakdown`, and the time column of `goals`.
- Widgets that are always "now": `standup`, `sessions`, `due`, `unlogged`, `board`. Their titles
  do not change when the period does.

`time` widget

- Tiles become: total for the period, average per worked day, and "Stopped, not logged yet"
  (always now, kept orange). In week and month scale the total carries a small "vs previous
  period" delta.

`chart` widget — Swift Charts (`import Charts`, a system framework: no package dependency, and
the target is already macOS 14)

- Week and month: one stacked `BarMark` per day, stacked by space in the space's colour. This
  replaces "This week by space"; the legend under the chart carries each space's total. With a
  single space selected the bars are plain, in `Theme.accent`.
- Day: a timeline of the day — one bar per time entry from start to end on an hour axis, so you
  see *when* you worked, not only how much.
- Hover shows the day's figure (`chartXSelection`); a click on a day's bar switches to Day scale
  on that day.
- A `RuleMark` at the daily target, when one is set.

Daily target

- `Project.dailyTargetHours: Double?` (optional, like every newer `Project` field), edited in the
  space's settings. Empty means no target.
- It counts on Monday to Friday. With "All spaces" the target is the sum of the spaces that have
  one; with no target anywhere, the line and the "left today" figure are not shown.
- The `time` widget gains "left today" (or "over by") beside the period total, and in week and
  month scale the total reads against the target for the period (for example 17h 27m of 40h).

Aggregation (`Store.swift`)

- `trackedByDay(in:project:now:) -> [Date: [UUID?: TimeInterval]]`: one pass over the entries,
  bucketed by day and space, instead of calling `tracked(in:)` once per day per space.
- Past periods do not change with the clock. The widgets take a `now` rounded to the minute, and
  only when the period contains today; a past week is computed once.

## Phase 3 — Calendar and breakdown

**Done**, with these differences from what follows:

- The calendar is shown by default, after the chart; it was going to start hidden.
- It marks due dates only. A standup happens every working day, so marking it would put the
  same dot on every cell.
- `bySpace` and `topTasks` are hidden by default. A saved layout that lists them keeps them as
  they were.

`calendar` widget

- A month grid (`LazyVGrid`, 7 columns, weeks start as `Calendar.current` says). Each day cell is
  shaded by hours tracked, with the figure under the day number; today is ringed in
  `Theme.accent`.
- Small markers on days where something is due (`TaskItem.due`, `Goal.due`) and on days with a
  standup meeting.
- A click on a day sets the period to that day; the month's own `‹ ›` move the calendar without
  changing the period, so you can look ahead while staying on this week.

`breakdown` widget — replaces "Most time this week"

- "Where the time went" for the selected period: tasks ordered by time, with the space dot, the
  figure and a thin proportional bar. Six rows, then "Show all".
- A By task / By space / By goal switch. By space is the list the old section had; By goal is
  new and comes for free from `store.tasks(of:)`.

## Phase 4 — More widgets (each small, each optional)

**Done**: `due` (shown by default), `unlogged` (hidden by default, it repeats the toolbar's
time-to-push button) and the clickable board pills. The board shows every column at once, so a
pill opens the board rather than one column.

## Phase 5 — Columns

**Done.** Each widget takes the whole width or sits in the left or right column
(`OverviewSlot.column`, optional). Widgets with a column that follow each other form a block of
two columns, and each column piles its own widgets in their order, so a short widget can sit
under another beside a tall one. `OverviewGrid`, a custom `Layout`, does this. A block with
widgets on one side only spreads over the whole width, except while customising, where a card
shows the column it was given. A widget dragged onto a card takes that card's column. With any
widget in a column the overview may grow to 1280 points instead of 860.
