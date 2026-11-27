import Foundation
import SwiftUI

enum TrackerKind: String, Codable, CaseIterable, Identifiable {
    case redmine, jira, github, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .redmine: return "Redmine"
        case .jira: return "Jira"
        case .github: return "GitHub"
        case .other: return "Other"
        }
    }

    var urlHint: String {
        switch self {
        case .redmine: return "https://redmine.company.com"
        case .jira: return "https://company.atlassian.net"
        case .github: return "https://github.com/org  or  https://github.com/org/repo"
        case .other: return "https://…"
        }
    }

    var ticketHint: String {
        switch self {
        case .redmine: return "12345 or link"
        case .jira: return "PROJ-123 or link"
        case .github: return "123, repo#123 or link"
        case .other: return "reference or link"
        }
    }
}

/// What a board column means for timers, archiving and the menu bar suggestions.
enum ColumnRole: String, Codable, CaseIterable, Identifiable {
    case backlog, agents, inProgress, normal, watching, done
    var id: String { rawValue }

    var label: String {
        switch self {
        case .backlog: return "Not started"
        case .agents: return "For agents"
        case .inProgress: return "In progress"
        case .normal: return "Other work"
        case .watching: return "Watching"
        case .done: return "Done"
        }
    }

    var hint: String {
        switch self {
        case .backlog: return "Starting a timer moves the task to the In progress column."
        case .agents: return "A task dragged here is started as an agent session, a few at a time, and then moves to In progress."
        case .inProgress: return "Where tasks go when you start a timer on a not-started or done task."
        case .normal: return "A normal work step, such as review or testing."
        case .watching: return "Tasks you only follow. Not suggested in the menu bar; timers leave them here."
        case .done: return "Moving a task here stops its timer. Tasks here can be archived."
        }
    }
}

/// One column of the board. Tasks point at a column by its id.
struct BoardColumn: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var role: ColumnRole = .normal

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// The original fixed columns. Their ids match the status values saved by earlier versions.
    static let defaults = [
        BoardColumn(id: "todo", name: "To Do", role: .backlog),
        BoardColumn(id: "inProgress", name: "In Progress", role: .inProgress),
        BoardColumn(id: "review", name: "Review", role: .normal),
        BoardColumn(id: "done", name: "Done", role: .done),
    ]
}

/// Called a "space" everywhere the user can see. The type and the saved keys keep the older name so
/// existing data files load unchanged.
struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var kind: TrackerKind = .redmine
    var baseURL = ""
    var colorIndex = 0
    var defaultActivityId: Int?
    /// Jira Cloud: account e-mail (empty = Bearer token, for Server/Data Center).
    var username: String?
    /// Redmine: "textile" (default) or "markdown", matching the instance's setting.
    var textFormat: String?
    /// Orca repository last used to start a session for this space; preselected next time.
    var orcaRepoId: String?
    /// The Orca repositories that belong to this space. Nil in files saved before a space could have
    /// more than one; `repoIds` covers both.
    var orcaRepoIds: [String]?
    /// Claude Code's home directory for this project's agent sessions (e.g. "~/.claude-work"), as typed.
    /// Empty or nil means Claude's own default.
    var claudeHome: String?
    /// The first message for this space's agent sessions, with placeholders such as "{ref}" (see
    /// `Sessions.placeholders`). Empty or nil means the app's standard message.
    var sessionPrompt: String?
    /// The first message for a code review session started in this space (see
    /// `CodeReview.placeholders`). Empty or nil means the app's own, from Settings.
    var codeReviewPrompt: String?
    /// The browser this space's links open in ("chrome", "edge"); nil for the system default.
    var browser: String?
    /// The browser profile's folder ("Default", "Profile 1"); nil for the browser's last used profile.
    var browserProfile: String?
    /// A GitHub organisation whose Orca repositories all belong to this space, besides the ticked ones.
    var githubOrg: String?
    /// The `gh` account this project's agent sessions use. Empty or nil means gh's active account.
    var githubAccount: String?
    /// Where the last ticket created from the app went in this space's tracker: a Redmine project
    /// id, a Jira project key or a GitHub "owner/repo", and the type chosen there. Preselected next time.
    var createTarget: String?
    var createType: String?
    /// The space's daily standup; nil for a space that has none set up.
    var standup: StandupSettings?
    /// Hours aimed at per working day (Monday to Friday) in this space; nil for no target.
    var dailyTargetHours: Double?
    /// How much of this space the review may send to Claude: a `ReviewDetail`. Nil is status only.
    var reviewDetail: String?
    /// The `SessionRunner.id` this space's sessions start in; nil follows the app's default.
    var sessionRunner: String?
    /// The `AgentKind.id` preselected for this space's sessions and used by the agent queue; nil
    /// follows the app's default.
    var sessionAgent: String?
    /// The repositories ticked for this space in runners other than Orca, by `SessionRunner.id`.
    /// Orca's stay in `orcaRepoIds`, where files from before there was a choice keep them.
    var runnerRepoIds: [String: [String]]?

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]
    var color: Color { Project.palette[abs(colorIndex) % Project.palette.count] }
    var keychainAccount: String { "apikey-\(id.uuidString)" }
    /// The Orca repositories ticked for this space. Each runner has ids of its own, so these mean
    /// nothing to another one; `repoIds(on:)` asks for a runner's.
    var repoIds: [String] { orcaRepoIds ?? [orcaRepoId].compactMap { $0 } }

    /// The repositories ticked for this space in the given runner.
    func repoIds(on runner: String) -> [String] {
        runner == OrcaRunner.id ? repoIds : runnerRepoIds?[runner] ?? []
    }

    mutating func setRepoIds(_ ids: [String], on runner: String) {
        if runner == OrcaRunner.id {
            orcaRepoIds = ids
        } else {
            var all = runnerRepoIds ?? [:]
            all[runner] = ids.isEmpty ? nil : ids
            runnerRepoIds = all.isEmpty ? nil : all
        }
    }

    /// Whether the space has repositories ticked in any runner.
    var hasRepositories: Bool { !repoIds.isEmpty || !(runnerRepoIds ?? [:]).values.allSatisfy(\.isEmpty) }

    /// The space's repositories among those a runner has: the ticked ones plus every repository of
    /// its GitHub organisation, so one added later belongs to the space without another step.
    func owns(_ repo: SessionRepo) -> Bool {
        if repoIds(on: repo.runner).contains(repo.id) { return true }
        guard let org = githubOrg, !org.isEmpty, let owner = repo.owner else { return false }
        return owner.caseInsensitiveCompare(org) == .orderedSame
    }
}

/// When and how often a space holds its daily standup, and how its update should read.
struct StandupSettings: Codable, Hashable {
    var enabled = false
    /// Meeting time, local.
    var hour = 10
    var minute = 0
    /// `Calendar` weekday numbers (1 = Sunday); Monday to Friday unless changed.
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    /// How long before the meeting the reminder comes; 0 for none.
    var remindMinutes = 10
    /// The space's own style for the update: language, format, length.
    var instructions = ""

    /// An update written this soon after a meeting is still about that meeting, not the next one,
    /// so the period it covers starts at the meeting before.
    static let lateWriting: TimeInterval = 3 * 3600

    init() {}

    // Each field on its own: a field added later must not make a saved space lose its standup.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 10
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? [2, 3, 4, 5, 6]
        remindMinutes = try c.decodeIfPresent(Int.self, forKey: .remindMinutes) ?? 10
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    }

    /// The meeting on that day, or nil when the day has none.
    func meeting(on day: Date, calendar: Calendar = .current) -> Date? {
        guard weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// The first meeting at or after `date`; nil when no weekday is ticked.
    func nextMeeting(after date: Date, calendar: Calendar = .current) -> Date? {
        for ahead in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: date),
                  let meeting = meeting(on: day, calendar: calendar), meeting >= date else { continue }
            return meeting
        }
        return nil
    }

    /// The meeting to remind of at `now`: today's, when `now` is inside the reminder's window before
    /// it and no reminder was sent for it yet. Nil otherwise.
    func reminderDue(now: Date, lastReminded: Date?, calendar: Calendar = .current) -> Date? {
        guard enabled, remindMinutes > 0, let meeting = meeting(on: now, calendar: calendar),
              now >= meeting.addingTimeInterval(-TimeInterval(remindMinutes) * 60), now < meeting else { return nil }
        if let lastReminded, calendar.isDate(lastReminded, inSameDayAs: meeting) { return nil }
        return meeting
    }

    /// Where an update written at `date` starts: the meeting before the one it is for. On a Monday
    /// that is Friday's. With no weekday ticked, the same time a day earlier.
    func periodStart(for date: Date, calendar: Calendar = .current) -> Date {
        let cutoff = date.addingTimeInterval(-Self.lateWriting)
        for back in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: cutoff),
                  let meeting = meeting(on: day, calendar: calendar), meeting <= cutoff else { continue }
            return meeting
        }
        return calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-86_400)
    }
}

/// The last standup update written for a space.
struct StandupNote: Codable, Hashable {
    var text: String
    var at: Date
    /// The start of the period it covered.
    var since: Date
}

/// A task arriving in a board column. Kept so a standup can tell what moved and when; the board
/// itself only knows where a task is now.
struct ColumnMove: Codable, Hashable {
    var column: String
    var at: Date
}

struct TimeEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var start: Date
    var end: Date?
    var loggedAt: Date?
    /// `Machine.id` of the Mac that started it, for a running entry; nil in entries from before
    /// there was more than one Mac, which are this Mac's. Only that Mac stops it by itself.
    var machine: String?

    var isLocal: Bool { machine == nil || machine == Machine.id }

    func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// Something the user wrote down about a task. Kept on this Mac and never posted to the tracker;
/// the review and the standup read it, no other AI feature does.
struct TaskNote: Identifiable, Codable, Hashable {
    var id = UUID()
    var text = ""
    var at = Date()
}

/// A moment the user asked to be told about a task. Kept on this Mac only: the note is not
/// posted to the tracker and no AI feature reads it.
struct TaskReminder: Identifiable, Codable, Hashable {
    var id = UUID()
    var at: Date
    var note = ""
    /// When it came due and was said. A fired reminder stays, in the bell's list, until it is
    /// opened, cleared or snoozed.
    var firedAt: Date?
}

struct TaskItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectId: UUID?
    var ref = ""
    var title = ""
    var url = ""
    /// Id of the board column the task is in.
    var status: String = "todo"
    var entries: [TimeEntry] = []
    /// The single note a task had before it could hold several. Still read from old files and
    /// emptied once the notes are changed; use `noteList`.
    var notes = ""
    /// The task's notes, oldest first. Nil in a file saved before there could be several.
    var noteItems: [TaskNote]?
    /// The ticket description written for a task that has no ticket yet (Markdown). Unlike the
    /// notes it goes to the tracker when the ticket is created, and to every AI feature. Cleared once the task has a ticket, whose own description then counts.
    var draft: String?
    var createdAt = Date()
    var archived = false
    /// The ticket's own status in its tracker (e.g. "Assigned", "In Review", "merged"), when known.
    var remoteStatus: String?
    /// The kind of ticket in its tracker (Bug, Story, Pull request…), when known.
    var remoteType: String?
    /// Which estimate the ticket lacks in its tracker ("Estimate", "Dev estimate" or both), as
    /// last seen. Nil when none is missing, or for a tracker without estimates.
    var estimateGap: String?
    /// Who the ticket is assigned to in its tracker, when known.
    var remoteAssignee: String?
    /// The due date set here. It is kept in TaskDeck only and wins over the tracker's.
    var dueDate: Date?
    /// The ticket's own due date in its tracker, as last seen.
    var remoteDue: Date?
    var due: Date? { dueDate ?? remoteDue }
    /// Reminders set for this task. Optional so older files still load; use `reminderList`.
    var reminders: [TaskReminder]?
    /// The reminders, earliest first.
    var reminderList: [TaskReminder] { (reminders ?? []).sorted { $0.at < $1.at } }
    /// Last plain-language explanation of the ticket written by Claude (Markdown).
    var explanation: String?
    /// Agent sessions started in Orca for this task, oldest first. Optional so older files still load.
    var sessions: [AgentSession]?
    /// Every pull request seen for this task, in the order found. Optional so older files still
    /// load; use `pullRequestList`.
    var pullRequests: [TaskPullRequest]?
    /// The task's pull requests, newest first, without the ones taken off the list by hand.
    var pullRequestList: [TaskPullRequest] {
        (pullRequests ?? []).filter { $0.hidden != true }.sorted { $0.openedAt > $1.openedAt }
    }
    /// The Orca repository chosen for this task when the queue could not tell which one it is about.
    var queueRepoId: String?
    /// Why the agent queue is not starting this task: `needsRepository`, or the error it met.
    /// Nil while the task simply waits its turn.
    var queueNote: String?
    static let needsRepository = "repository"
    /// The goal this task belongs to; a task is in one goal at most, so totals never count twice.
    var goalId: UUID?
    /// `Machine.id` of the Mac whose agent queue starts this task, set when it enters the queue.
    /// Only that Mac starts it, so a task synced to several Macs starts once. Synced.
    var runOn: String?
    var order: Double = 0
    /// The latest column changes, oldest first. Only moves made since this was added are known.
    var moves: [ColumnMove]?
    static let movesKept = 10

    var isRunning: Bool { entries.contains { $0.end == nil } }

    /// The notes, oldest first. A note from an old file counts as one, written when the task was made.
    var noteList: [TaskNote] {
        get {
            if let noteItems { return noteItems }
            let old = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            // The task's own id, so the row keeps its identity until the list is first saved.
            return old.isEmpty ? [] : [TaskNote(id: id, text: old, at: createdAt)]
        }
        set {
            noteItems = newValue
            notes = ""
        }
    }

    /// Every note as one text, newest first: for the search and the card.
    var notesText: String { noteList.reversed().map(\.text).joined(separator: "\n") }

    /// The notes as facts for Claude, oldest first and dated, so it can tell which are recent.
    /// Only the review and the standup send them; the caller decides whether the space allows it.
    func noteFacts(limit: Int = 8, length: Int = 600) -> [String] {
        noteList.suffix(limit).compactMap { note in
            // On one line: a note's own lists would read as part of the facts around it.
            let body = note.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !body.isEmpty else { return nil }
            let clipped = body.count > length ? String(body.prefix(length)) + " […]" : body
            return "\(note.at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())): \(clipped)"
        }
    }

    mutating func noteMove(to column: String, at date: Date = Date()) {
        moves = Array(((moves ?? []) + [ColumnMove(column: column, at: date)]).suffix(Self.movesKept))
    }

    func moves(in period: DateInterval) -> [ColumnMove] {
        (moves ?? []).filter { period.contains($0.at) }
    }

    /// How long the running timer has been going since it was last started; 0 when none runs.
    func currentStretch(now: Date) -> TimeInterval {
        entries.first { $0.end == nil }?.duration(now: now) ?? 0
    }

    func total(now: Date) -> TimeInterval {
        entries.reduce(0) { $0 + $1.duration(now: now) }
    }

    /// The part of this task's time that falls inside a period; a running timer counts up to `now`.
    func tracked(in period: DateInterval, now: Date) -> TimeInterval {
        entries.reduce(0) { sum, entry in
            let start = max(entry.start, period.start)
            let end = min(entry.end ?? now, period.end)
            return end > start ? sum + end.timeIntervalSince(start) : sum
        }
    }

    /// Time already stopped and not yet logged to the tracker.
    var unloggedSeconds: TimeInterval {
        entries.filter { $0.end != nil && $0.loggedAt == nil }
            .reduce(0) { $0 + $1.duration(now: Date()) }
    }

    var displayRef: String {
        guard !ref.isEmpty else { return "" }
        return ref.allSatisfy(\.isNumber) ? "#\(ref)" : ref
    }
}

enum GoalStatus: String, Codable, CaseIterable, Identifiable {
    case active, paused, done
    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: return "Active"
        case .paused: return "Paused"
        case .done: return "Done"
        }
    }
}

/// Something kept with a goal that is not a task: a note, or a pointer to a page, mail or file.
/// Mails and files are only pointed at; nothing is copied into the app.
struct GoalItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case note, link, mail, document

        var icon: String {
            switch self {
            case .note: return "note.text"
            case .link: return "link"
            case .mail: return "envelope"
            case .document: return "doc"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .note
    var title = ""
    var url = ""
    var text = ""
    var createdAt = Date()

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? url : title }

    /// What was typed, pasted or dropped: a single address becomes a link, mail or document by
    /// where it points, and anything else is a note.
    static func from(_ raw: String) -> GoalItem? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "message", "mailto"].contains(scheme) {
            return from(url)
        }
        return GoalItem(kind: .note, text: text)
    }

    static func from(_ url: URL) -> GoalItem {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = (url.host ?? "").lowercased()
        if url.isFileURL {
            return GoalItem(kind: .document, title: url.lastPathComponent, url: url.absoluteString)
        }
        if scheme == "message" || scheme == "mailto" {
            return GoalItem(kind: .mail, title: scheme == "mailto" ? String(url.absoluteString.dropFirst(7)) : "Mail message",
                            url: url.absoluteString)
        }
        let kind: Kind
        if host == "mail.google.com" || host.hasPrefix("outlook.") {
            kind = .mail
        } else if ["docs.google.com", "drive.google.com"].contains(host) || host.hasSuffix("sharepoint.com")
                    || host.hasSuffix("dropbox.com") {
            kind = .document
        } else {
            kind = .link
        }
        // No request is made for the page's own title: the address is tidied up and the user renames it.
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path == "/" ? "" : url.path
        return GoalItem(kind: kind, title: name + path, url: url.absoluteString)
    }
}

struct GoalSource: Codable, Hashable {
    var projectId: UUID
    var ref: String
    var url: String
}

/// Something the user looks after that spans several tasks, in any space, with the notes and
/// links that go with it. Fields added later must be optional so saved files still load.
struct Goal: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var summary = ""
    var status: GoalStatus = .active
    var due: Date?
    var items: [GoalItem] = []
    var createdAt = Date()
    /// The tracker ticket the goal was imported from (epic, parent issue or milestone), so it can
    /// be read again for children added since.
    var source: GoalSource?
    /// Claude's last account of where the goal stands (Markdown), and when it was written.
    var standing: String?
    var standingAt: Date?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled goal" : trimmed
    }
}

enum LinkResolver {
    /// Accepts a ticket number/key or a full link and returns (ref, url).
    static func resolve(_ raw: String, kind: TrackerKind, base rawBase: String) -> (ref: String, url: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !input.isEmpty else { return ("", "") }

        if input.lowercased().hasPrefix("http") {
            let parts = (URLComponents(string: input)?.path ?? "")
                .split(separator: "/").map(String.init)
            func after(_ names: [String]) -> String? {
                guard let i = parts.firstIndex(where: { names.contains($0) }), i + 1 < parts.count else { return nil }
                return parts[i + 1]
            }
            let ref: String
            switch kind {
            case .redmine:
                ref = after(["issues"]) ?? parts.last ?? input
            case .jira:
                ref = after(["browse", "issues"]) ?? parts.last ?? input
            case .github:
                if let n = after(["issues", "pull"]), parts.count >= 2 {
                    ref = "\(parts[1])#\(n)"
                } else {
                    ref = parts.last ?? input
                }
            case .other:
                ref = parts.last ?? input
            }
            return (ref, input)
        }

        let ref = input.hasPrefix("#") ? String(input.dropFirst()) : input
        guard !base.isEmpty else { return (ref, "") }
        switch kind {
        case .redmine:
            return (ref, "\(base)/issues/\(ref)")
        case .jira:
            return (ref.uppercased(), "\(base)/browse/\(ref.uppercased())")
        case .github:
            if let hash = ref.firstIndex(of: "#") {
                let repo = ref[..<hash]
                let number = ref[ref.index(after: hash)...]
                return (ref, "\(base)/\(repo)/issues/\(number)")
            }
            return (ref, "\(base)/issues/\(ref)")
        case .other:
            return (ref, "")
        }
    }
}

enum Fmt {
    /// "1:23:45" — for running timers.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "1h 23m" — for totals.
    static func short(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m == 0 { return seconds > 0 ? "<1m" : "0m" }
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    /// "1:23" (h:mm) — for the menu bar.
    static func hm(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func hours(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds / 3600)
    }
}

/// A pull request that belongs to a task. Found through an agent session's worktree or added by
/// its link, and kept after the worktree is gone. What GitHub last said about it is saved with
/// it, so the list has something to show before GitHub answers again. Every field added later
/// must be optional so saved files still load.
struct TaskPullRequest: Identifiable, Codable, Hashable {
    /// "owner/name" on github.com.
    var slug: String
    var number: Int
    /// The Orca worktree it was found in; nil for one added by its link.
    var worktreeId: String?
    /// The `gh` account of the session it was found in; nil for the space's.
    var account: String?
    var firstSeen = Date()
    /// Taken off the list by hand. Kept, so the next look at Orca does not add it again.
    var hidden: Bool?

    // What GitHub said at `checkedAt`; nil until it answered.
    var title: String?
    /// "open", "merged" or "closed". Orca's word for it until GitHub answers.
    var state: String?
    var draft: Bool?
    var createdAt: Date?
    var mergedAt: Date?
    var closedAt: Date?
    var approved: Bool?
    var changesRequested: Bool?
    /// Reviews and comments by other people since my last push or reply.
    var waiting: Int?
    /// "passing", "failing" or "pending"; nil when the last commit has no checks.
    var checks: String?
    var conflict: Bool?
    /// The last commit, to say "checks failed" once per push.
    var headSha: String?
    var checkedAt: Date?

    /// When the newest review or comment already announced was written.
    var feedbackSeenAt: Date?
    /// What was already announced besides reviews and comments: "merged", "closed", "checks:<sha>", "conflict:<sha>".
    var announced: [String]?

    var id: String { "\(slug.lowercased())#\(number)" }
    var url: URL? { URL(string: "https://github.com/\(slug)/pull/\(number)") }
    var openedAt: Date { createdAt ?? firstSeen }
    var isOpen: Bool { state == "open" }

    /// Why an open pull request needs a look, in a few words; nil when nothing waits for me.
    var attention: String? {
        guard isOpen else { return nil }
        var reasons: [String] = []
        if let waiting, waiting > 0 {
            reasons.append(changesRequested == true ? "changes requested"
                           : waiting == 1 ? "1 review or comment to answer" : "\(waiting) reviews or comments to answer")
        }
        if checks == "failing" { reasons.append("checks failed") }
        if conflict == true { reasons.append("merge conflict") }
        return reasons.isEmpty ? nil : reasons.joined(separator: ", ")
    }

    /// "PR #12", "Draft PR #12", "Merged #12", "Closed #12".
    var label: String {
        switch state {
        case "merged": return "Merged #\(number)"
        case "closed": return "Closed #\(number)"
        default: return (draft == true ? "Draft " : "") + "PR #\(number)"
        }
    }
}
