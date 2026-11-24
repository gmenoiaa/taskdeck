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

    private var tasks: [TaskItem] { store.tasks.filter { spaceId == nil || $0.projectId == spaceId } }

    private struct SessionRow: Identifiable {
        let task: TaskItem
        let session: AgentSession
        let status: Orca.Status
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
        let week: DateInterval
    }

    /// Widgets that can show something here: agent sessions need Orca.
    private var placements: [OverviewPlacement] {
        store.overviewPlacements.filter { $0.widget != .sessions || Orca.isInstalled }
    }

    var body: some View {
        let now = store.now
        let calendar = Calendar.current
        let today = DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let moment = Moment(now: now, today: today, week: calendar.dateInterval(of: .weekOfYear, for: now) ?? today)
        let placements = placements
        let shown = placements.filter { !$0.hidden }.map(\.widget)
        ScrollView {
            VStack(alignment: .leading, spacing: customising ? 12 : 22) {
                if customising {
                    customiseBar
                    ForEach(shown) { widget in card(widget, moment, shown: shown) }
                    let hidden = placements.filter(\.hidden).map(\.widget)
                    if !hidden.isEmpty {
                        Text("Hidden").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(hidden) { widget in hiddenRow(widget) }
                    }
                } else if shown.isEmpty {
                    Text("Every widget is hidden.").foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { widget in
                        content(widget, moment).contextMenu { menu(widget, shown: shown) }
                    }
                }
            }
            .padding(20)
            // Wider than this, the figures drift apart and rows become hard to follow across.
            .frame(maxWidth: 860, alignment: .leading)
            // The first row of a widget is its title, at the left: the button sits in the free
            // space beside it instead of taking a row of its own.
            .overlay(alignment: .topTrailing) {
                if !customising {
                    quiet(Button("Customise") { withAnimation { customising = true } })
                        .help("Reorder, hide and show the overview's widgets")
                        .padding(.top, 16).padding(.trailing, 20)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges()
        .task { await store.refreshSessionStatuses() }
    }

    @ViewBuilder
    private func content(_ widget: OverviewWidget, _ moment: Moment) -> some View {
        switch widget {
        case .standup: standup(now: moment.now)
        case .time: time(now: moment.now, today: moment.today, week: moment.week)
        case .chart: chart(now: moment.now, today: moment.today, week: moment.week)
        case .sessions: sessions
        case .goals: goals(week: moment.week, now: moment.now)
        case .bySpace:
            if spaceId == nil {
                bySpace(week: moment.week, now: moment.now)
            } else if customising {
                Text("Shown with All spaces.").foregroundStyle(.secondary)
            }
        case .topTasks: topTasks(week: moment.week, now: moment.now)
        case .board: board
        }
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
            Text("Drag a widget to move it. Hidden ones stay at the bottom.").foregroundStyle(.secondary)
            Spacer(minLength: 12)
            quiet(Button("Reset to default") { withAnimation { store.resetOverviewLayout() } })
                .disabled(store.overviewLayout.isEmpty)
            quiet(Button("Done") { withAnimation { customising = false } })
                .keyboardShortcut(.defaultAction)
        }
    }

    /// A shown widget while customising: a strip to grab and act on, over its content, which is
    /// dimmed and takes no clicks so a drag never presses a button inside it.
    private func card(_ widget: OverviewWidget, _ moment: Moment, shown: [OverviewWidget]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                Text(widget.title).font(.headline).foregroundStyle(.primary)
                Spacer(minLength: 12)
                step(widget, -1, "chevron.up", "Move up", shown: shown)
                step(widget, 1, "chevron.down", "Move down", shown: shown)
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
            withAnimation { store.moveOverviewWidget(dragged, to: widget) }
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
    private func menu(_ widget: OverviewWidget, shown: [OverviewWidget]) -> some View {
        Button("Hide \(widget.title)") { withAnimation { store.setOverviewWidget(widget, hidden: true) } }
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

    private func time(now: Date, today: DateInterval, week: DateInterval) -> some View {
        let unlogged = tasks.reduce(0) { $0 + $1.unloggedSeconds }
        return section(.time) {
            HStack(spacing: 10) {
                tile(Fmt.short(store.tracked(in: today, now: now, project: spaceId)), "Today")
                tile(Fmt.short(store.tracked(in: week, now: now, project: spaceId)), "This week")
                // Orange is the app's "needs you" colour, as on the time-to-push button.
                tile(Fmt.short(unlogged), "Stopped, not logged yet", color: unlogged >= 60 ? .orange : .primary)
            }
        }
    }

    private func chart(now: Date, today: DateInterval, week: DateInterval) -> some View {
        let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: week.start) }
            .map { start -> (start: Date, seconds: TimeInterval) in
                (start, store.tracked(in: DateInterval(start: start, duration: 86_400), now: now, project: spaceId))
            }
        let most = max(days.map(\.seconds).max() ?? 0, 1)
        return section(.chart) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days, id: \.start) { day in
                    // Not `today.contains`: a DateInterval includes its end, which is tomorrow's start.
                    let isToday = day.start == today.start
                    VStack(spacing: 4) {
                        Text(day.seconds >= 60 ? Fmt.short(day.seconds) : " ")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isToday ? Theme.accent : Color.primary.opacity(0.25))
                            // A day with no time keeps a thin line, so the week still reads as seven days.
                            .frame(height: max(2, 56 * day.seconds / most))
                        Text(day.start.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption).foregroundStyle(isToday ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 100, alignment: .bottom)
        }
    }

    private func tile(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Orca is not answering, so session status is unknown.").foregroundStyle(.secondary)
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
                    SessionBadge(status: row.status, count: 1)
                    if let pr = row.status.prURL {
                        Button("Open PR") { Browser.open(pr, space: store.project(row.task.projectId)) }
                            .controlSize(.small)
                    }
                    Button("Open in Orca") { Task { await Orca.reveal(row.session) } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Goals

    /// Active goals with how far each is and the time it took this week. Paused and finished
    /// goals stay in the Goals tab. A goal's figures cover all its tasks, in every space: a goal
    /// is one piece of work wherever its tickets live.
    @ViewBuilder
    private func goals(week: DateInterval, now: Date) -> some View {
        let rows = store.goals(in: spaceId).filter { $0.status == .active }.map { goal in
            let tasks = store.tasks(of: goal.id)
            return (goal: goal, done: tasks.filter(store.isDone).count, total: tasks.count,
                    week: tasks.reduce(0) { $0 + $1.tracked(in: week, now: now) })
        }
        // What is due comes first, soonest at the top; then where the time went this week.
        .sorted { a, b in
            switch (a.goal.due, b.goal.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.week > b.week
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
                        Text(row.week >= 60 ? Fmt.short(row.week) : "—").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .trailing)
                            .help("Time tracked on the goal's tasks this week")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: Lists

    @ViewBuilder
    private func bySpace(week: DateInterval, now: Date) -> some View {
        let rows = store.projects
            .map { (space: $0, seconds: store.tracked(in: week, now: now, project: $0.id)) }
            .filter { $0.seconds >= 60 }
            .sorted { $0.seconds > $1.seconds }
        if !rows.isEmpty {
            section(.bySpace) {
                ForEach(rows, id: \.space.id) { row in
                    line(dot: row.space.color, row.space.name, Fmt.short(row.seconds))
                }
            }
        }
    }

    @ViewBuilder
    private func topTasks(week: DateInterval, now: Date) -> some View {
        let rows = tasks.map { (task: $0, seconds: $0.tracked(in: week, now: now)) }
            .filter { $0.seconds >= 60 }
            .sorted { $0.seconds > $1.seconds }
            .prefix(6)
        if !rows.isEmpty {
            section(.topTasks) {
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
                    HStack(spacing: 5) {
                        Text(column.displayName).foregroundStyle(.secondary)
                        Text("\(count)").fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
        }
    }

    // MARK: Pieces

    /// A widget's title over its content. While customising the card's strip carries the title.
    private func section<Content: View>(_ widget: OverviewWidget, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !customising { Text(widget.title).font(.headline) }
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
