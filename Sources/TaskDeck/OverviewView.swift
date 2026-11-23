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

    var body: some View {
        let now = store.now
        let calendar = Calendar.current
        let today = DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? today
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                time(now: now, today: today, week: week)
                if Orca.isInstalled { sessions }
                goals(week: week, now: now)
                if spaceId == nil { bySpace(week: week, now: now) }
                topTasks(week: week, now: now)
                board
            }
            .padding(20)
            // Wider than this, the figures drift apart and rows become hard to follow across.
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges()
        .task { await store.refreshSessionStatuses() }
    }

    // MARK: Time

    private func time(now: Date, today: DateInterval, week: DateInterval) -> some View {
        let unlogged = tasks.reduce(0) { $0 + $1.unloggedSeconds }
        let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: week.start) }
            .map { start -> (start: Date, seconds: TimeInterval) in
                (start, store.tracked(in: DateInterval(start: start, duration: 86_400), now: now, project: spaceId))
            }
        let most = max(days.map(\.seconds).max() ?? 0, 1)
        return section("Time") {
            HStack(spacing: 10) {
                tile(Fmt.short(store.tracked(in: today, now: now, project: spaceId)), "Today")
                tile(Fmt.short(store.tracked(in: week, now: now, project: spaceId)), "This week")
                // Orange is the app's "needs you" colour, as on the time-to-push button.
                tile(Fmt.short(unlogged), "Stopped, not logged yet", color: unlogged >= 60 ? .orange : .primary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days, id: \.start) { day in
                    let isToday = today.contains(day.start)
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
            .padding(.top, 4)
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
        section("Agent sessions") {
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
            section("Goals") {
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
            section("This week by space") {
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
            section("Most time this week") {
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
        section("On the board") {
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
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
