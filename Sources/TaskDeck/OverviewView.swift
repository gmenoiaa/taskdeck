import SwiftUI

/// What happened in a space and what needs the user: time, agent sessions, pull requests and the board.
/// With no space it covers all of them.
struct OverviewView: View {
    @Environment(AppStore.self) private var store
    let spaceId: UUID?
    /// Opens a task's ticket view; the window owns that sheet.
    let onDetails: (TaskItem) -> Void
    /// Opens a goal in the Goals tab.
    var onGoal: (UUID) -> Void = { _ in }
    /// Opens the sheet that logs one task's time, and the one that logs everything pending.
    var onLog: (TaskItem) -> Void = { _ in }
    var onLogAll: () -> Void = {}
    /// Shows the board.
    var onBoard: () -> Void = {}

    private var tasks: [TaskItem] { store.tasks.filter { spaceId == nil || $0.projectId == spaceId } }

    private struct SessionRow: Identifiable {
        let task: TaskItem
        let session: AgentSession
        let status: SessionStatus
        var id: UUID { session.id }
    }

    /// Sessions of tasks still on the board, with what Orca says about each.
    private var sessionRows: [SessionRow] {
        tasks.filter { !$0.archived }.flatMap { task in
            store.sessions(of: task).compactMap { session in
                store.status(of: session).map { SessionRow(task: task, session: session, status: $0) }
            }
        }
    }

    /// While true the widgets show their handles and can be dragged, hidden and shown.
    @State private var customising = false
    /// The widget a dragged one is over.
    @State private var dropTarget: OverviewWidget?

    /// The moment the figures are for, worked out once per pass.
    private struct Moment {
        let now: Date
        let today: DateInterval
        /// The period the time widgets cover, and its time day by day.
        let period: OverviewPeriod
        let days: [OverviewDay]
        var span: DateInterval { period.interval }
    }

    @State private var scale: OverviewPeriod.Scale = .week
    /// A date in the period shown; nil follows the clock, so the overview left open overnight
    /// moves on to the new day by itself. Not saved: it opens on now every time.
    @State private var anchor: Date?

    /// Widgets that can show something here: agent sessions need a runner.
    private var placements: [OverviewPlacement] {
        store.overviewPlacements.filter { $0.widget != .sessions || Runners.anyAvailable }
    }

    var body: some View {
        let now = store.now
        let calendar = Calendar.current
        let today = DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let period = OverviewPeriod(scale: scale, anchor: anchor ?? now)
        let moment = Moment(now: now, today: today, period: period,
                            days: store.trackedByDay(in: period, project: spaceId, now: now))
        let placements = placements
        let shown = placements.filter { !$0.hidden }.map(\.widget)
        let widths = Dictionary(uniqueKeysWithValues: placements.map { ($0.widget, $0.width) })
        let columns = placements.contains { !$0.hidden && $0.width != .full }
        ScrollView {
            OverviewGrid(spacing: customising ? 12 : 22, expandsLone: !customising) {
                if customising {
                    customiseBar
                    ForEach(shown) { widget in
                        card(widget, moment, shown: shown, width: widths[widget] ?? .full)
                            .layoutValue(key: OverviewGrid.Column.self, value: widths[widget] ?? .full)
                    }
                    let hidden = placements.filter(\.hidden).map(\.widget)
                    if !hidden.isEmpty {
                        Text("Hidden").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(hidden) { widget in hiddenRow(widget) }
                    }
                } else {
                    periodBar(moment)
                    if shown.isEmpty { Text("Every widget is hidden.").foregroundStyle(.secondary) }
                    ForEach(shown) { widget in
                        content(widget, moment)
                            .contextMenu { menu(widget, shown: shown, width: widths[widget] ?? .full) }
                            .layoutValue(key: OverviewGrid.Column.self, value: widths[widget] ?? .full)
                    }
                }
            }
            .padding(20)
            // Wider than this, the figures drift apart and rows become hard to follow across.
            // Two widgets side by side need the room of two.
            .frame(maxWidth: columns ? 1280 : 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges()
        .task { await store.refreshSessionStatuses() }
    }

    @ViewBuilder
    private func content(_ widget: OverviewWidget, _ moment: Moment) -> some View {
        switch widget {
        case .standup: standup(now: moment.now)
        case .time: time(moment)
        // Draws its own title, which carries its buttons.
        case .review: ReviewSection(spaceId: spaceId, onDetails: onDetails)
        case .chart: chart(moment)
        case .calendar:
            section(.calendar) {
                OverviewCalendar(period: moment.period, spaceId: spaceId, now: moment.now) { open(day: $0) }
            }
        case .breakdown:
            section(.breakdown) {
                OverviewBreakdown(period: moment.period, days: moment.days, spaceId: spaceId, now: moment.now,
                                  onDetails: onDetails, onGoal: onGoal)
            }
        case .sessions: sessions
        case .goals: goals(span: moment.span, now: moment.now)
        case .due: due(now: moment.now)
        case .unlogged: unlogged
        case .bySpace:
            if spaceId == nil {
                bySpace(moment)
            } else if customising {
                Text("Shown with All spaces.").foregroundStyle(.secondary)
            }
        case .topTasks: topTasks(moment)
        case .board: board
        }
    }

    // MARK: Period

    /// Moves the time widgets back and forward, and switches between a day, a week and a month.
    private func periodBar(_ moment: Moment) -> some View {
        let period = moment.period
        return HStack(spacing: 8) {
            quiet(Button { show(period.stepped(-1)) } label: { Image(systemName: "chevron.left") })
                .keyboardShortcut("[", modifiers: .command)
                .help("Previous \(scale.rawValue) (⌘[)")
                .accessibilityLabel("Previous \(scale.rawValue)")
            quiet(Button { show(period.stepped(1)) } label: { Image(systemName: "chevron.right") })
                .keyboardShortcut("]", modifiers: .command)
                .help("Next \(scale.rawValue) (⌘])")
                .accessibilityLabel("Next \(scale.rawValue)")
            Text(period.title(now: moment.now)).font(.headline)
            if period.phrase(now: moment.now) != nil {
                Text(period.dates).foregroundStyle(.secondary)
            }
            if !period.contains(moment.now) {
                quiet(Button("Today") { withAnimation { anchor = nil } })
                    .help("Back to the \(scale == .day ? "current day" : "current \(scale.rawValue)")")
            }
            Spacer(minLength: 12)
            Picker("Period", selection: $scale) {
                ForEach(OverviewPeriod.Scale.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            quiet(Button("Customise") { withAnimation { customising = true } })
                .help("Reorder, hide and show the overview's widgets")
        }
    }

    /// Shows one day, from a click on the chart or the calendar.
    private func open(day: Date) {
        withAnimation {
            scale = .day
            anchor = Calendar.current.isDate(day, inSameDayAs: store.now) ? nil : day
        }
    }

    private func show(_ date: Date) {
        withAnimation { anchor = OverviewPeriod(scale: scale, anchor: date).contains(store.now) ? nil : date }
    }

    // MARK: Customising

    /// A small neutral button: glass on macOS 26, bordered before.
    @ViewBuilder
    private func quiet(_ button: some View) -> some View {
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass).tint(nil).controlSize(.small)
        } else {
            button.buttonStyle(.bordered).tint(nil).controlSize(.small)
        }
    }

    private var customiseBar: some View {
        HStack(spacing: 8) {
            Text("Drag a widget to move it. Widgets in the left and right columns pile up side by side.").foregroundStyle(.secondary)
            Spacer(minLength: 12)
            quiet(Button("Reset to default") { withAnimation { store.resetOverviewLayout() } })
                .disabled(store.overviewLayout.isEmpty)
            quiet(Button("Done") { withAnimation { customising = false } })
                .keyboardShortcut(.defaultAction)
        }
    }

    /// A shown widget while customising: a strip to grab and act on, over its content, which is
    /// dimmed and takes no clicks so a drag never presses a button inside it.
    private func card(_ widget: OverviewWidget, _ moment: Moment, shown: [OverviewWidget], width: OverviewWidth) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                Text(widget.title).font(.headline).foregroundStyle(.primary)
                Spacer(minLength: 12)
                step(widget, -1, "chevron.up", "Move up", shown: shown)
                step(widget, 1, "chevron.down", "Move down", shown: shown)
                Picker("Width of \(widget.title)", selection: Binding(
                    get: { width }, set: { new in withAnimation { store.setOverviewWidget(widget, width: new) } })) {
                    ForEach(OverviewWidth.allCases) { Image(systemName: $0.symbol).help($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("Full width, or the left or right column. Widgets in a column pile up in their order.")
                Button { withAnimation { store.setOverviewWidget(widget, hidden: true) } } label: {
                    Image(systemName: "eye.slash")
                }
                .help("Hide this widget")
                .accessibilityLabel("Hide \(widget.title)")
            }
            .buttonStyle(.borderless)
            // Neutral: with the app's red tint the arrows read as warnings.
            .tint(nil).foregroundStyle(.secondary)
            content(widget, moment).opacity(0.45).allowsHitTesting(false)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(dropTarget == widget ? Theme.accent : Color.primary.opacity(0.12),
                              lineWidth: dropTarget == widget ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .draggable(widget.dragToken)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(OverviewWidget.init(dragToken:)), dragged != widget else { return false }
            withAnimation { store.moveOverviewWidget(dragged, to: widget, takingColumn: true) }
            return true
        } isTargeted: { over in
            if over { dropTarget = widget } else if dropTarget == widget { dropTarget = nil }
        }
    }

    private func step(_ widget: OverviewWidget, _ by: Int, _ symbol: String, _ label: String,
                      shown: [OverviewWidget]) -> some View {
        let neighbour = store.overviewNeighbour(of: widget, by: by, among: shown)
        return Button {
            if let neighbour { withAnimation { store.moveOverviewWidget(widget, to: neighbour) } }
        } label: { Image(systemName: symbol) }
            .disabled(neighbour == nil)
            .help(label)
            .accessibilityLabel("\(label): \(widget.title)")
    }

    private func hiddenRow(_ widget: OverviewWidget) -> some View {
        HStack(spacing: 8) {
            Text(widget.title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Add") { withAnimation { store.setOverviewWidget(widget, hidden: false) } }
                .controlSize(.small)
                .accessibilityLabel("Show \(widget.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The right-click menu of a widget outside customising; also the way to reorder without a drag.
    @ViewBuilder
    private func menu(_ widget: OverviewWidget, shown: [OverviewWidget], width: OverviewWidth) -> some View {
        Button("Hide \(widget.title)") { withAnimation { store.setOverviewWidget(widget, hidden: true) } }
        Picker("Width", selection: Binding(
            get: { width }, set: { new in withAnimation { store.setOverviewWidget(widget, width: new) } })) {
            ForEach(OverviewWidth.allCases) { Text($0.label).tag($0) }
        }
        let up = store.overviewNeighbour(of: widget, by: -1, among: shown)
        let down = store.overviewNeighbour(of: widget, by: 1, among: shown)
        Button("Move Up") { if let up { withAnimation { store.moveOverviewWidget(widget, to: up) } } }
            .disabled(up == nil)
        Button("Move Down") { if let down { withAnimation { store.moveOverviewWidget(widget, to: down) } } }
            .disabled(down == nil)
        Divider()
        Button("Customise Overview…") { withAnimation { customising = true } }
    }

    // MARK: Standup

    /// The daily standup of the space shown, or one row per space that has one with "All spaces".
    @ViewBuilder
    private func standup(now: Date) -> some View {
        let spaces = store.standupSpaces.filter { spaceId == nil || $0.id == spaceId }
        if !spaces.isEmpty {
            section(.standup) {
                ForEach(spaces) { space in
                    standupRow(space, now: now, preview: spaceId != nil)
                }
            }
        }
    }

    private func standupRow(_ space: Project, now: Date, preview: Bool) -> some View {
        let note = store.currentStandup(space, now: now)
        let meeting = space.standup?.meetingFor(now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(space.color).frame(width: 8, height: 8)
                if spaceId == nil { Text(space.name).lineLimit(1) }
                if let meeting {
                    Text("Meeting \(StandupSettings.label(meeting, now: now))")
                        .foregroundStyle(spaceId == nil ? .secondary : .primary)
                }
                if note != nil {
                    Label("Written", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                        .help("An update for this meeting is saved. Open it to copy or write it again.")
                }
                Spacer(minLength: 12)
                Button(note == nil ? "Write update" : "Open update") { store.openStandup = space.id }
                    .controlSize(.small)
            }
            if preview, let note {
                Text(note.text).font(.callout).foregroundStyle(.secondary).lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Time

    private func time(_ moment: Moment) -> some View {
        let now = moment.now, period = moment.period
        // Only what can be sent, as the time-to-push button counts it: stopped time on a Jira or
        // GitHub task can never be logged from here and would keep the figure up for good.
        let unlogged = store.pendingLogTasks.filter { spaceId == nil || $0.projectId == spaceId }
            .reduce(0) { $0 + $1.unloggedSeconds }
        let total = moment.days.reduce(0) { $0 + $1.total }
        let daily = store.dailyTarget(project: spaceId)
        let current = period.contains(now)
        // The target counts Monday to Friday: at the weekend there is nothing left to do.
        let todayTarget = Calendar.current.isDateInWeekend(now) ? 0 : daily
        let worked = moment.days.filter { $0.total >= 60 }.count
        return section(.time) {
            HStack(alignment: .top, spacing: 10) {
                if current && period.scale != .day {
                    let today = store.tracked(in: moment.today, now: now, project: spaceId)
                    tile(Fmt.short(today), "Today", notes: [left(today, of: todayTarget)])
                }
                tile(Fmt.short(total), period.title(now: now), notes: periodNotes(moment, total: total, daily: daily))
                if period.scale != .day {
                    tile(worked > 0 ? Fmt.short(total / Double(worked)) : "—", "Average per worked day")
                }
                // Orange is the app's "needs you" colour, as on the time-to-push button.
                tile(Fmt.short(unlogged), "Stopped, not on Redmine yet", color: unlogged >= 60 ? .orange : .primary)
            }
            // The tiles take the height of the tallest, so one with a note does not stand out.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "2h 10m left of 8h 00m", or that the target is reached; nil with no target.
    private func left(_ tracked: TimeInterval, of target: TimeInterval) -> String? {
        guard target > 0 else { return nil }
        let rest = target - tracked
        return rest >= 60 ? "\(Fmt.short(rest)) left of \(Fmt.short(target))" : "Target of \(Fmt.short(target)) reached"
    }

    /// What goes under the period's total: how it stands against the target, and against the
    /// period before.
    private func periodNotes(_ moment: Moment, total: TimeInterval, daily: TimeInterval) -> [String?] {
        let now = moment.now, period = moment.period
        let current = period.contains(now)
        let target = daily * Double(period.workdays)
        var notes: [String?] = []
        if period.scale == .day && current {
            notes.append(left(total, of: target))
        } else if target > 0 {
            notes.append("of \(Fmt.short(target))")
        }
        if period.scale != .day {
            let before = OverviewPeriod(scale: period.scale, anchor: period.stepped(-1)).interval
            // A week in progress is compared with the same part of the one before, not with all of it.
            let elapsed = current ? now.timeIntervalSince(period.interval.start) : before.duration
            let compared = DateInterval(start: before.start, duration: min(before.duration, max(0, elapsed)))
            let earlier = store.tracked(in: compared, now: now, project: spaceId)
            if earlier >= 60 {
                let difference = total - earlier
                let unit = period.scale.rawValue
                notes.append("\(difference >= 0 ? "+" : "−")\(Fmt.short(abs(difference))) "
                             + (current ? "on last \(unit) at this point" : "on the \(unit) before"))
            }
        }
        return notes
    }

    private func chart(_ moment: Moment) -> some View {
        section(.chart, title: moment.period.scale == .day ? "Timeline" : "Hours per day") {
            OverviewChart(period: moment.period, days: moment.days, spaceId: spaceId, now: moment.now,
                          dailyTarget: store.dailyTarget(project: spaceId)) { open(day: $0) }
        }
    }

    private func tile(_ value: String, _ label: String, color: Color = .primary, notes: [String?] = []) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
            ForEach(notes.compactMap { $0 }, id: \.self) { note in
                Text(note).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.card))
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessions: some View {
        let rows = sessionRows
        let waiting = rows.filter { $0.status.kind == .yourTurn }
        let working = rows.filter { $0.status.kind == .working }
        // A session that is working or waiting is listed there, even when it also has an open pull request.
        let open = rows.filter { $0.status.kind == .prOpen }
        section(.sessions) {
            if store.sessionStatuses == nil {
                Text("\(store.runner(for: nil).label) is not answering, so session status is unknown.").foregroundStyle(.secondary)
            } else if waiting.isEmpty && working.isEmpty && open.isEmpty {
                Text(rows.isEmpty ? "No task on the board has a session." : "Nothing is waiting for you, working, or open for review.")
                    .foregroundStyle(.secondary)
            } else {
                group("Waiting for you", waiting)
                group("Working", working)
                group("Open pull requests", open)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [SessionRow]) -> some View {
        if !rows.isEmpty {
            Text("\(title) · \(rows.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        taskButton(row.task)
                        Text("\(row.session.repoName) · \(row.session.name)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    // The same pills as on a board card, and like there they are the links: the pull
                    // request's opens it, the session's opens it in its runner.
                    SessionBadges(session: row.session, status: row.status,
                                  space: store.project(row.task.projectId), count: 1)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Goals

    /// Active goals with how far each is and the time it took in the period shown. Paused and finished
    /// goals stay in the Goals tab. A goal's figures cover all its tasks, in every space: a goal
    /// is one piece of work wherever its tickets live.
    @ViewBuilder
    private func goals(span: DateInterval, now: Date) -> some View {
        let rows = store.goals(in: spaceId).filter { $0.status == .active }.map { goal in
            let tasks = store.tasks(of: goal.id)
            return (goal: goal, done: tasks.filter(store.isDone).count, total: tasks.count,
                    spent: tasks.reduce(0) { $0 + $1.tracked(in: span, now: now) })
        }
        // What is due comes first, soonest at the top; then where the time went.
        .sorted { a, b in
            switch (a.goal.due, b.goal.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.spent > b.spent
            }
        }
        if !rows.isEmpty {
            section(.goals) {
                ForEach(rows, id: \.goal.id) { row in
                    HStack(spacing: 12) {
                        Button { onGoal(row.goal.id) } label: {
                            Text(row.goal.displayName).lineLimit(1).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open the goal")
                        if let due = row.goal.due {
                            Text("Due " + Due.label(due)).font(.caption.weight(.medium)).foregroundStyle(Due.color(due))
                        }
                        Spacer(minLength: 12)
                        if row.total > 0 {
                            ProgressView(value: Double(row.done), total: Double(row.total))
                                .tint(Theme.accent).frame(width: 90)
                            Text("\(row.done)/\(row.total)").monospacedDigit().foregroundStyle(.secondary)
                                .frame(minWidth: 34, alignment: .trailing)
                        } else {
                            Text("No tasks").foregroundStyle(.secondary)
                        }
                        Text(row.spent >= 60 ? Fmt.short(row.spent) : "—").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .trailing)
                            .help("Time tracked on the goal's tasks in the period shown")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: Lists

    @ViewBuilder
    private func bySpace(_ moment: Moment) -> some View {
        let rows = store.projects
            .map { space in (space: space, seconds: moment.days.reduce(0) { $0 + ($1.bySpace[space.id] ?? 0) }) }
            .filter { $0.seconds >= 60 }
            .sorted { $0.seconds > $1.seconds }
        if !rows.isEmpty {
            section(.bySpace, title: moment.period.phrase(now: moment.now).map { "\($0.prefix(1).uppercased() + $0.dropFirst()) by space" }) {
                ForEach(rows, id: \.space.id) { row in
                    line(dot: row.space.color, row.space.name, Fmt.short(row.seconds))
                }
            }
        }
    }

    @ViewBuilder
    private func topTasks(_ moment: Moment) -> some View {
        let rows = tasks.map { (task: $0, seconds: $0.tracked(in: moment.span, now: moment.now)) }
            .filter { $0.seconds >= 60 }
            .sorted { $0.seconds > $1.seconds }
            .prefix(6)
        if !rows.isEmpty {
            section(.topTasks, title: moment.period.phrase(now: moment.now).map { "Most time \($0)" }) {
                ForEach(Array(rows), id: \.task.id) { row in
                    HStack(spacing: 8) {
                        Circle().fill(store.project(row.task.projectId)?.color ?? .gray).frame(width: 8, height: 8)
                        taskButton(row.task)
                        Spacer(minLength: 16)
                        Text(Fmt.short(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var board: some View {
        section(.board) {
            HStack(spacing: 8) {
                ForEach(store.columns) { column in
                    let count = store.tasks(in: column.id, project: spaceId).count
                    Button(action: onBoard) {
                        HStack(spacing: 5) {
                            Text(column.displayName).foregroundStyle(.secondary)
                            Text("\(count)").fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show the board")
                }
            }
        }
    }

    // MARK: Due and to log

    /// Open tasks and active goals that are overdue or due within a week, soonest first.
    @ViewBuilder
    private func due(now: Date) -> some View {
        let soon: (Date) -> Bool = { Due.daysLeft($0, now: now) <= 7 }
        let dueTasks = tasks.filter { !store.isDone($0) }
            .compactMap { task in task.due.map { (date: $0, task: Optional(task), goal: Goal?.none) } }
        let dueGoals = store.goals(in: spaceId).filter { $0.status == .active }
            .compactMap { goal in goal.due.map { (date: $0, task: TaskItem?.none, goal: Optional(goal)) } }
        let rows = (dueTasks + dueGoals).filter { soon($0.date) }.sorted { $0.date < $1.date }
        if !rows.isEmpty {
            section(.due) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        if let task = row.task {
                            Circle().fill(store.project(task.projectId)?.color ?? .gray).frame(width: 8, height: 8)
                            taskButton(task)
                        } else if let goal = row.goal {
                            Image(systemName: "target").font(.caption).foregroundStyle(.secondary).frame(width: 8)
                            Button { onGoal(goal.id) } label: {
                                Text(goal.displayName).lineLimit(1).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open the goal")
                        }
                        Spacer(minLength: 16)
                        DueChip(date: row.date)
                    }
                }
            }
        }
    }

    /// The tasks behind the orange tile: stopped time that can be sent to Redmine, most first.
    @ViewBuilder
    private var unlogged: some View {
        let rows = store.pendingLogTasks.filter { (spaceId == nil || $0.projectId == spaceId) && $0.unloggedSeconds >= 60 }
        if !rows.isEmpty {
            section(.unlogged) {
                ForEach(rows.prefix(6)) { task in
                    HStack(spacing: 8) {
                        Circle().fill(store.project(task.projectId)?.color ?? .gray).frame(width: 8, height: 8)
                        taskButton(task)
                        Spacer(minLength: 16)
                        Text(Fmt.short(task.unloggedSeconds)).monospacedDigit().foregroundStyle(.orange)
                        Button("Log time") { onLog(task) }.controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    if rows.count > 6 { Text("and \(rows.count - 6) more").foregroundStyle(.secondary) }
                    Button("Log all…", action: onLogAll).controlSize(.small)
                        .help("Review everything pending and send it in one go")
                }
            }
        }
    }

    // MARK: Pieces

    /// A widget's title over its content. While customising the card's strip carries the title.
    /// The time widgets pass a title that names the period.
    private func section<Content: View>(_ widget: OverviewWidget, title: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !customising { Text(title ?? widget.title).font(.headline) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A task's reference and title; a click opens its ticket view.
    private func taskButton(_ task: TaskItem) -> some View {
        Button { onDetails(task) } label: {
            Text("\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces))
                .lineLimit(1).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the ticket")
    }

    private func line(dot: Color, _ text: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text).lineLimit(1)
            Spacer(minLength: 16)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
