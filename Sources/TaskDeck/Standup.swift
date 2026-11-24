import Foundation

/// What the app knows about one space's work for a standup update, sorted into what was done in
/// the period, what is on the board now, and what waits. Only this space's tasks, and never their
/// private notes or unsent ticket drafts.
@MainActor
struct StandupFacts {
    struct Line {
        let task: TaskItem
        /// "PROJ-12 Fix the login" — the ticket reference and title.
        let label: String
        /// Plain facts about the task, one per line, for Claude.
        var details: [String] = []
        /// A short note for the plain list: "moved to Done", "due 25 Nov".
        var note: String?
        /// The tracker says the ticket waits on someone: a blocker in the plain list.
        var blocked = false
    }

    let space: Project
    let period: DateInterval
    /// The meeting the update is for.
    let meeting: Date?
    var workedOn: [Line] = []
    var onBoard: [Line] = []
    var nextUp: [Line] = []
    var waiting: [Line] = []
    var newlyAssigned: [RemoteTicket] = []
    /// The update written for the previous meeting, when there is one: its "Today" is what was planned.
    var previous: StandupNote?

    /// Tracker statuses that say the ticket waits on someone, in the trackers' usual wordings.
    static let waitingWords = ["block", "waiting", "on hold", "feedback", "need info", "needs info", "pending", "paused"]
    static let boardLimit = 10
    static let nextUpLimit = 3
    static let assignedLimit = 5

    init(space: Project, since: Date, store: AppStore, now: Date = Date()) {
        self.space = space
        period = DateInterval(start: min(since, now), end: now)
        // Written just after a meeting, the update is still that meeting's, as in `periodStart`.
        meeting = space.standup?.meetingFor(now)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today) ?? today

        let tasks = store.tasks.filter { $0.projectId == space.id }
        func label(_ task: TaskItem) -> String {
            [task.displayRef.isEmpty ? nil : task.displayRef, task.title.isEmpty ? "(untitled)" : task.title]
                .compactMap { $0 }.joined(separator: " ")
        }
        func columnName(_ id: String) -> String { store.column(id)?.displayName ?? id }
        func when(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }

        // Facts every section shares; the period-specific ones are added where they matter.
        func baseFacts(_ task: TaskItem) -> [String] {
            var facts = ["Board column now: " + (task.archived ? "archived" : columnName(task.status))
                         + (store.isDone(task) ? " (finished)" : "")]
            if let status = task.remoteStatus { facts.append("Tracker status: \(status)") }
            if let type = task.remoteType { facts.append("Type: \(type)") }
            if let assignee = task.remoteAssignee { facts.append("Assigned to: \(assignee)") }
            if let due = task.due { facts.append("Due: \(due.formatted(date: .abbreviated, time: .omitted))") }
            if let goal = task.goalId.flatMap({ id in store.goals.first { $0.id == id } }) {
                facts.append("Part of the goal: \(goal.displayName)")
            }
            for session in store.sessions(of: task) {
                guard let status = store.status(of: session) else { continue }
                let started = period.contains(session.startedAt) ? ", started \(when(session.startedAt))" : ""
                facts.append("Agent session: \(Claude.sessionState(status.kind))\(started)")
            }
            return facts
        }
        // Only what was already read from the tracker; nothing is fetched for a standup. Comment
        // dates are kept as display text, so Claude is told the period and judges which are recent.
        func comments(_ task: TaskItem) -> [String] {
            guard let detail = TicketCache.load(task.id)?.detail else { return [] }
            return detail.comments.suffix(2).compactMap { comment in
                // On one line: the comment's own headings and lists would read as part of the facts.
                let body = comment.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !body.isEmpty else { return nil }
                let clipped = body.count > 400 ? String(body.prefix(400)) + " […]" : body
                return "Comment by \(comment.author), \(comment.date): \(clipped)"
            }
        }

        var seen = Set<UUID>()

        // Worked on: time tracked, a column change or an agent session started in the period.
        let worked = tasks.compactMap { task -> (TaskItem, TimeInterval, [ColumnMove], Bool)? in
            let tracked = task.tracked(in: period, now: now)
            let moves = task.moves(in: period)
            let agent = store.sessions(of: task).contains { period.contains($0.startedAt) }
            guard tracked >= 60 || !moves.isEmpty || agent else { return nil }
            return (task, tracked, moves, agent)
        }
        .sorted { $0.1 > $1.1 }
        for (task, tracked, moves, _) in worked {
            var line = Line(task: task, label: label(task))
            if tracked >= 60 {
                line.details.append("Time tracked in the period: \(Fmt.short(tracked))" + (task.isRunning ? " (timer running now)" : ""))
            }
            if !moves.isEmpty {
                line.details.append("Moved: " + moves.map { "to \(columnName($0.column)) (\(when($0.at)))" }.joined(separator: ", "))
            }
            line.details += baseFacts(task) + comments(task)
            if store.isDone(task) {
                line.note = "done"
            } else if let last = moves.last {
                line.note = "moved to \(columnName(last.column))"
            }
            workedOn.append(line)
            seen.insert(task.id)
        }

        let open = tasks.filter { !$0.archived && !store.isDone($0) }

        // Waiting or needing attention. A task can be here and in "worked on" too: both are true.
        // Watched tasks are left out: following someone else's ticket is not being held up by it.
        for task in open where store.role(of: task.status) != .watching {
            var reasons: [String] = []
            let blocked = task.remoteStatus.map { status in
                Self.waitingWords.contains { status.lowercased().contains($0) }
            } ?? false
            if blocked, let status = task.remoteStatus { reasons.append("tracker status is \(status)") }
            if store.sessions(of: task).contains(where: { store.status(of: $0)?.kind == .yourTurn }) {
                reasons.append("an agent session waits for the developer")
            }
            if let due = task.due, due < today { reasons.append("overdue since \(due.formatted(date: .abbreviated, time: .omitted))") }
            guard !reasons.isEmpty else { continue }
            var line = Line(task: task, label: label(task), note: reasons.joined(separator: "; "), blocked: blocked)
            line.details = ["Why it is listed: " + reasons.joined(separator: "; ")] + baseFacts(task)
            if !seen.contains(task.id) { line.details += comments(task) }
            waiting.append(line)
        }

        // On the board now: what today is likely about. The running timer first, then work in
        // progress, then anything due by tomorrow.
        func rank(_ task: TaskItem) -> Int {
            if task.isRunning { return 0 }
            switch store.role(of: task.status) {
            case .inProgress: return 1
            case .agents: return 2
            case .normal: return 3
            default: return 4
            }
        }
        let candidates = open.filter { task in
            let role = store.role(of: task.status)
            return task.isRunning || [.inProgress, .agents, .normal].contains(role)
                || (task.due.map { $0 < dayAfterTomorrow } ?? false && role != .watching)
        }
        .sorted { (rank($0), $0.order) < (rank($1), $1.order) }
        for task in candidates.prefix(Self.boardLimit) {
            var line = Line(task: task, label: label(task))
            if task.isRunning { line.details.append("Timer running now") }
            line.details += baseFacts(task)
            if let due = task.due, due < dayAfterTomorrow { line.note = "due \(due.formatted(date: .abbreviated, time: .omitted))" }
            onBoard.append(line)
        }

        let backlog = open.filter { store.role(of: $0.status) == .backlog && !candidates.contains($0) }
            .sorted { $0.order < $1.order }
        nextUp = backlog.prefix(Self.nextUpLimit).map { Line(task: $0, label: label($0), details: baseFacts($0)) }

        newlyAssigned = Array((store.assignedTickets[space.id] ?? [])
            .filter { store.task(project: space.id, ref: $0.ref) == nil && !store.ignoredAssigned.contains($0.id) }
            .prefix(Self.assignedLimit))

        // The update for the previous meeting, not an earlier draft of this one: written before
        // the period started or just after (late writing), and not from a week ago.
        if let note = store.standups[space.id],
           note.at < period.start.addingTimeInterval(StandupSettings.lateWriting),
           note.at > period.start.addingTimeInterval(-4 * 86_400) {
            previous = note
        }
    }

    var isEmpty: Bool { workedOn.isEmpty && onBoard.isEmpty && nextUp.isEmpty && waiting.isEmpty && newlyAssigned.isEmpty }

    static func periodLabel(_ start: Date) -> String {
        start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute())
    }

    /// The facts as plain text for Claude.
    var text: String {
        let now = period.end
        var out = "Space: \(space.name) (\(space.kind.label))\n"
        out += "Now: \(now.formatted(date: .complete, time: .shortened))\n"
        out += "The update covers the time since: \(Self.periodLabel(period.start))\n"
        if let meeting { out += "The standup meeting it is for: \(meeting.formatted(.dateTime.weekday(.wide).hour().minute()))\n" }

        func section(_ title: String, _ lines: [Line]) {
            out += "\n## \(title)\n"
            if lines.isEmpty { out += "(nothing)\n"; return }
            for line in lines {
                out += "\n### \(line.label)\n" + line.details.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
        }
        section("Worked on in the period", workedOn)
        section("On the board now, not finished", onBoard)
        section("Not started, next in line", nextUp)
        section("Waiting or needing attention", waiting)
        out += "\n## Newly assigned in the tracker, not on the board yet\n"
        out += newlyAssigned.isEmpty ? "(nothing)\n"
            : newlyAssigned.map { "- \($0.displayRef) \($0.title) (status: \($0.status))" }.joined(separator: "\n") + "\n"
        if let previous {
            out += "\n## The developer's previous standup update, written \(previous.at.formatted(.dateTime.weekday(.wide).hour().minute()))\n"
            out += "<previous_update>\n\(previous.text)\n</previous_update>\n"
        }
        return out
    }

    /// The update without Claude: the same facts as three short lists.
    var plain: String {
        func bullets(_ lines: [Line], empty: String) -> String {
            guard !lines.isEmpty else { return "- \(empty)" }
            return lines.map { line in "- " + line.label + (line.note.map { " (\($0))" } ?? "") }.joined(separator: "\n")
        }
        // Today: work on the board, else the next in line; what was finished is not today's.
        let today = onBoard.isEmpty ? nextUp : onBoard
        return """
        Yesterday:
        \(bullets(workedOn, empty: "Nothing tracked in \(space.name) since \(Self.periodLabel(period.start))"))

        Today:
        \(bullets(today, empty: "Nothing on the board yet"))

        Blockers:
        \(bullets(waiting.filter(\.blocked), empty: "None"))
        """
    }
}

extension StandupFacts {
    /// The system prompt and the message for Claude, with the space's own instructions last.
    func request(instructions: String) -> (system: String, user: String) {
        (Claude.system(Claude.standupSystem, custom: instructions, space: space.standup?.instructions ?? ""), text)
    }
}

extension StandupSettings {
    /// "today 10:00", "tomorrow 9:30", "Wed 10:00".
    static func label(_ meeting: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = meeting.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(meeting, inSameDayAs: now) { return "today \(time)" }
        if calendar.isDateInTomorrow(meeting) { return "tomorrow \(time)" }
        return meeting.formatted(.dateTime.weekday(.abbreviated)) + " \(time)"
    }

    /// The meeting an update written at `date` is for, matching `periodStart`.
    func meetingFor(_ date: Date) -> Date? {
        nextMeeting(after: date.addingTimeInterval(-Self.lateWriting))
    }
}

extension AppStore {
    /// Spaces with a daily standup turned on, in the order of the space list.
    var standupSpaces: [Project] { projects.filter { $0.standup?.enabled == true } }

    /// The update already written for the meeting coming up, if there is one. An update written
    /// before the period started, or just after (late), was for the meeting before.
    func currentStandup(_ space: Project, now: Date = Date()) -> StandupNote? {
        guard let settings = space.standup, let note = standups[space.id] else { return nil }
        return note.at >= settings.periodStart(for: now).addingTimeInterval(StandupSettings.lateWriting) ? note : nil
    }
}
