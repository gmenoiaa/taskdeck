import Foundation
import AppKit
import UserNotifications

/// Which notifications the app sends. Every field has a default, so a file saved before a field
/// existed still loads.
struct NotificationSettings: Codable, Equatable {
    /// An agent stopped, opened a pull request, or the queue could not start one.
    var sessions = true
    /// A pull request of one of the board's tasks was merged or closed, approved, someone
    /// reviewed or commented on it, its checks failed or it cannot be merged for a conflict.
    var pullRequests = true
    /// A ticket was assigned to me in a tracker.
    var assigned = true
    /// Time stopped and not logged yet, once a day from `unloggedHour` on.
    var unlogged = true
    var unloggedHour = 18
    /// A timer that has been running for `longTimerHours`, and again each time that passes.
    var longTimer = true
    var longTimerHours = 2
    /// What the Dock badge shows.
    var badge = DockBadge.waiting
    /// Extra things the waiting count includes, off unless asked for.
    var badgeAssigned = false
    var badgePullRequests = false
    /// At the Mac for `noTimerMinutes` during working hours with no timer running.
    var noTimer = true
    var noTimerMinutes = 10
    var workFrom = 9
    var workTo = 19
    var noTimerWeekends = false
    /// Moving a card to an In progress column starts its timer.
    var autoStartInProgress = true
    /// The banner's sound: empty for the macOS default, `none` for silence, otherwise the name
    /// of one of the system sounds bundled with the app ("Glass", "Submarine"…).
    var sound = ""
    /// Before a space's daily standup, by the minutes set on that space.
    var standup = true
    /// A task's reminder came due.
    var reminders = true

    enum DockBadge: String, Codable { case waiting, timer, none }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent(Bool.self, forKey: .sessions) ?? true
        pullRequests = try c.decodeIfPresent(Bool.self, forKey: .pullRequests) ?? true
        assigned = try c.decodeIfPresent(Bool.self, forKey: .assigned) ?? true
        unlogged = try c.decodeIfPresent(Bool.self, forKey: .unlogged) ?? true
        unloggedHour = try c.decodeIfPresent(Int.self, forKey: .unloggedHour) ?? 18
        longTimer = try c.decodeIfPresent(Bool.self, forKey: .longTimer) ?? true
        longTimerHours = try c.decodeIfPresent(Int.self, forKey: .longTimerHours) ?? 2
        badge = try c.decodeIfPresent(DockBadge.self, forKey: .badge) ?? .waiting
        badgeAssigned = try c.decodeIfPresent(Bool.self, forKey: .badgeAssigned) ?? false
        badgePullRequests = try c.decodeIfPresent(Bool.self, forKey: .badgePullRequests) ?? false
        noTimer = try c.decodeIfPresent(Bool.self, forKey: .noTimer) ?? true
        noTimerMinutes = try c.decodeIfPresent(Int.self, forKey: .noTimerMinutes) ?? 10
        workFrom = try c.decodeIfPresent(Int.self, forKey: .workFrom) ?? 9
        workTo = try c.decodeIfPresent(Int.self, forKey: .workTo) ?? 19
        noTimerWeekends = try c.decodeIfPresent(Bool.self, forKey: .noTimerWeekends) ?? false
        autoStartInProgress = try c.decodeIfPresent(Bool.self, forKey: .autoStartInProgress) ?? true
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? ""
        standup = try c.decodeIfPresent(Bool.self, forKey: .standup) ?? true
        reminders = try c.decodeIfPresent(Bool.self, forKey: .reminders) ?? true
    }
}

extension AppStore {
    /// Orca is only asked in the background when a notification depends on the answer.
    var watchesSessionsInBackground: Bool {
        queueNeedsAttention || notify.sessions || notify.pullRequests || notify.badge == .waiting
    }

    /// One thing waiting for me: what the Dock badge counts and the toolbar's list shows.
    struct WaitingItem: Identifiable {
        enum Kind { case yourTurn, pullRequest, repository, notStarted, assigned, reminder }
        let id: String
        let kind: Kind
        /// Nil for a ticket assigned to me that is not on the board: it has no task yet.
        var task: TaskItem?
        /// What to show in the task's place when there is none: the ticket's reference and title.
        var title: String?
        var session: AgentSession?
        var detail: String
        /// What the session asks for or last said, under the detail.
        var note: String?
        /// The page a pull request's item opens.
        var link: URL?
    }

    /// What the bell and the Dock badge show: everything waiting, less what was cleared by hand.
    var waitingItems: [WaitingItem] { everythingWaiting.filter { !clearedWaiting.contains($0.id) } }

    /// Takes items off the list without dealing with them. Each comes back the next time it
    /// happens: a session that works again and stops again, a queue start that fails again.
    func clearWaiting(_ ids: [String]) {
        // A reminder does not happen again, so clearing one removes it rather than noting it.
        let reminders = Set(ids.filter { $0.hasPrefix(Self.reminderPrefix) }.map { String($0.dropFirst(Self.reminderPrefix.count)) })
        if !reminders.isEmpty {
            for i in tasks.indices where tasks[i].reminders != nil {
                tasks[i].reminders?.removeAll { reminders.contains($0.id.uuidString) }
            }
        }
        clearedWaiting.formUnion(ids.filter { !$0.hasPrefix(Self.reminderPrefix) })
        save()
    }

    /// Drops the note of a cleared item once the thing itself is gone, so the next occurrence shows.
    func forgetCleared() {
        // Without Orca's answer the sessions are unknown, not gone.
        guard !clearedWaiting.isEmpty, sessionStatuses != nil else { return }
        let still = clearedWaiting.intersection(everythingWaiting.map(\.id))
        if still != clearedWaiting {
            clearedWaiting = still
            save()
        }
    }

    /// Everything waiting for me, most pressing first: each one is cleared by acting on it.
    private var everythingWaiting: [WaitingItem] {
        var items: [WaitingItem] = []
        let queue = queueColumn?.id
        for task in tasks where !task.archived {
            if task.status == queue, let note = task.queueNote {
                // A queued task that needs a repository or could not be started.
                items.append(note == TaskItem.needsRepository
                    ? WaitingItem(id: "repo-\(task.id)", kind: .repository, task: task, detail: "Pick a repository")
                    : WaitingItem(id: "queue-\(task.id)", kind: .notStarted, task: task, detail: "Agent not started: \(note)"))
            }
            for reminder in task.reminderList where reminder.firedAt != nil {
                items.append(WaitingItem(id: Self.reminderPrefix + reminder.id.uuidString, kind: .reminder, task: task,
                                         detail: "Reminder from \(Reminders.label(reminder.at))",
                                         note: reminder.note.isEmpty ? nil : reminder.note))
            }
            for session in sessions(of: task) {
                guard let status = status(of: session) else { continue }
                let key = session.worktreeId ?? session.id.uuidString
                if status.kind == .yourTurn {
                    items.append(WaitingItem(id: "turn-\(key)", kind: .yourTurn, task: task, session: session,
                                             detail: "Your turn in \(session.name)", note: status.summary))
                }
            }
            for pr in task.pullRequestList {
                guard let attention = pr.attention else { continue }
                items.append(WaitingItem(id: "pr-\(pr.id)", kind: .pullRequest, task: task,
                                         detail: "\(pr.label): \(attention)", note: pr.title, link: pr.url))
            }
        }
        // One line per ticket, whatever the Dock badge counts: these are what "ticket assigned to
        // you" notifications are about, so they have to be findable here afterwards.
        for ticket in assignedPending {
            items.append(WaitingItem(id: "assigned-\(ticket.id)", kind: .assigned,
                                     title: "\(ticket.displayRef) \(ticket.title)",
                                     detail: "Assigned to you, not on the board"))
        }
        return items
    }

    /// The Dock badge's number. Assigned tickets and pull requests count only when the setting
    /// asks for them; the bell lists them either way.
    var waitingCount: Int {
        waitingItems.filter {
            ($0.kind != .assigned || notify.badgeAssigned) && ($0.kind != .pullRequest || notify.badgePullRequests)
        }.count
    }

    static let reminderPrefix = "reminder-"

    func label(_ task: TaskItem) -> String {
        let text = "\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "(untitled)" : text
    }

    /// Compares each session with the last look: an agent that stopped working. The first look
    /// after launch only takes note. What happens to a pull request is noticed from GitHub's
    /// answers instead, in `noticePullRequest`.
    func noticeSessionChanges() {
        // No answer from Orca says nothing about the sessions, so the last look is kept.
        guard sessionStatuses != nil else { return }
        var seen: [String: SessionStatus.Kind] = [:]
        var stopped = false
        for task in tasks where !task.archived {
            for session in sessions(of: task) {
                guard let id = session.worktreeId, let status = status(of: session) else { continue }
                seen[id] = status.kind
                guard let before = sessionKinds[id], before != status.kind, before == .working else { continue }
                switch status.kind {
                case .yourTurn, .prOpen, .idle:
                    stopped = true
                    guard notify.sessions else { break }
                    let title = status.kind == .prOpen ? "Pull request opened"
                        : status.kind == .yourTurn ? "Your turn" : "Agent stopped"
                    // The banner says what the agent wants, so the session need not be opened
                    // to find out whether it can wait. A click goes to where it is answered: the
                    // pull request once there is one, otherwise the session in its runner.
                    let link = status.kind == .prOpen ? status.prURL : nil
                    let session = link == nil ? id : nil
                    if let summary = status.summary {
                        Notifier.send(title: title, subtitle: label(task), body: summary, session: session, link: link)
                    } else {
                        Notifier.send(title: title, body: label(task), session: session, link: link)
                    }
                case .working, .gone, .prMerged, .prClosed:
                    break
                }
            }
        }
        sessionKinds = seen
        if stopped { reviewAfterSessionStopped() }
    }

    /// Works out what is news in GitHub's answer about a pull request, marks it on `pr` as said,
    /// and sends it when `announce`. The first answer only takes note of what is already there,
    /// except an end: a pull request Orca reported as open and GitHub now says is merged is news.
    func noticePullRequest(_ report: GitHub.PullRequestReport, old: TaskPullRequest, new pr: inout TaskPullRequest,
                           task: TaskItem, announce: Bool) {
        let tell = announce && notify.pullRequests
        var said = Set(old.announced ?? [])

        if let seen = old.feedbackSeenAt {
            let fresh = report.feedback.items.filter { $0.at > seen }
            if let newest = fresh.last {
                if tell, let page = pr.url { announceFeedback(fresh, on: report.feedback, task: task, page: page) }
                pr.feedbackSeenAt = newest.at
            }
        } else {
            pr.feedbackSeenAt = report.feedback.items.last?.at ?? .distantPast
        }

        if let state = pr.state, state == "merged" || state == "closed" {
            if said.insert(state).inserted, tell, old.state == "open" {
                Notifier.send(title: "Pull request #\(pr.number) \(state == "merged" ? "merged" : "closed without merging")",
                              body: label(task), link: pr.url)
            }
        } else {
            // Reopened: its next end is news again.
            said.subtract(["merged", "closed"])
        }

        // Once per push: a failure that is still there five minutes later is the same failure.
        if pr.isOpen, let sha = pr.headSha {
            said = said.filter { !$0.contains(":") || $0.hasSuffix(":" + sha) }
            let first = old.checkedAt == nil
            if pr.checks == "failing", said.insert("checks:" + sha).inserted, tell, !first {
                Notifier.send(title: "Checks failed on pull request #\(pr.number)", body: label(task), link: pr.url)
            }
            if pr.conflict == true, said.insert("conflict:" + sha).inserted, tell, !first {
                Notifier.send(title: "Pull request #\(pr.number) has a merge conflict", body: label(task), link: pr.url)
            }
        }
        pr.announced = said.isEmpty ? nil : said.sorted()
    }

    /// New reviews or comments on a session's pull request, in one banner: the weightiest first
    /// (changes asked for, then an approval, then a comment), with who wrote it and how it starts.
    func announceFeedback(_ fresh: [GitHub.PullRequestFeedback.Item], on feedback: GitHub.PullRequestFeedback,
                          task: TaskItem, page: URL) {
        guard notify.pullRequests, !fresh.isEmpty else { return }
        let lead = fresh.last { $0.kind == .changesRequested } ?? fresh.last { $0.kind == .approved } ?? fresh.last!
        let title: String
        switch lead.kind {
        case .changesRequested: title = "Changes requested on #\(feedback.number)"
        case .approved: title = "Pull request #\(feedback.number) approved"
        case .comment: title = "New comment on #\(feedback.number)"
        }
        // HTML comments are what review apps hide their markers in; the rest is read as plain text.
        let text = lead.body.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*|__|`|(?m)^#+\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var body = text.isEmpty ? lead.author : "\(lead.author): \(text.count > 200 ? String(text.prefix(199)) + "…" : text)"
        if fresh.count > 1 { body += " (and \(fresh.count - 1) more)" }
        Notifier.send(title: title, subtitle: label(task), body: body, link: page)
    }

    /// The two reminders about time: stopped time not logged at the end of the day, and a timer that
    /// has been running for hours. Called every few seconds; each sends at most once per occasion.
    /// A reminder shortly before each space's standup, once a day.
    func noticeStandups() {
        // Asleep or locked, a banner would arrive late or unseen; the menu bar still offers the update.
        guard notify.standup, !isAway else { return }
        let now = Date()
        for space in standupSpaces {
            guard let meeting = space.standup?.reminderDue(now: now, lastReminded: standupRemindedAt[space.id]) else { continue }
            standupRemindedAt[space.id] = now
            save()
            let time = meeting.formatted(date: .omitted, time: .shortened)
            Notifier.send(title: "Standup at \(time) · \(space.name)",
                          body: currentStandup(space, now: now) == nil
                              ? "Click to have the update written."
                              : "Your update is written. Click to open and copy it.",
                          standup: space.id)
        }
    }

    func noticeTimers() {
        let now = Date()
        // Away from the Mac, the question asked on return covers the running timer.
        if notify.longTimer, awaySince == nil {
            let step = TimeInterval(max(1, notify.longTimerHours)) * 3600
            for task in tasks where task.isRunning {
                for entry in task.entries where entry.end == nil {
                    let times = Int(entry.duration(now: now) / step)
                    guard times >= 1, times > (longTimerReminders[entry.id] ?? 0) else { continue }
                    longTimerReminders[entry.id] = times
                    Notifier.send(title: "Timer still running",
                                  body: "\(label(task)) has been running for \(Fmt.short(entry.duration(now: now))).")
                }
            }
        }
        if notify.unlogged, Calendar.current.component(.hour, from: now) >= notify.unloggedHour,
           !(unloggedRemindedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false) {
            let pending = pendingLogTasks
            let seconds = pending.reduce(0) { $0 + $1.unloggedSeconds }
            guard seconds >= 60 else { return }
            unloggedRemindedAt = now
            save()
            let where_ = pending.count == 1 ? label(pending[0]) : "\(pending.count) tasks"
            Notifier.send(title: "Time not logged yet", body: "\(Fmt.short(seconds)) on \(where_) is not on Redmine yet.")
        }
    }
}

/// Notification Centre banners. They need the signed app bundle; a bare binary has none to send from.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }
    private static let delegate = Presenter()

    /// macOS shows no banner for the app in front unless it is told to, and the app is often in
    /// front when something it watches changes.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let info = response.notification.request.content.userInfo
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                if let id = (info["standup"] as? String).flatMap(UUID.init(uuidString:)) {
                    Task { @MainActor in Notifier.onStandup?(id) }
                } else if let id = info["session"] as? String {
                    Task { @MainActor in Notifier.onSession?(id) }
                } else if let link = (info["link"] as? String).flatMap(URL.init(string:)) {
                    Task { @MainActor in NSWorkspace.shared.open(link) }
                }
            }
            if let task = (info["reminderTask"] as? String).flatMap(UUID.init(uuidString:)),
               let id = (info["reminder"] as? String).flatMap(UUID.init(uuidString:)) {
                let snooze: Notifier.Snooze?
                switch response.actionIdentifier {
                case UNNotificationDefaultActionIdentifier: snooze = nil
                case Notifier.snoozeHourAction: snooze = .hour
                case Notifier.snoozeTomorrowAction: snooze = .tomorrow
                // Dismissed: it stays in the bell's list.
                default: completionHandler(); return
                }
                Task { @MainActor in Notifier.onReminder?(task, id, snooze) }
            }
            if response.actionIdentifier == Notifier.startAction,
               let id = (info["task"] as? String).flatMap(UUID.init(uuidString:)), let since = info["since"] as? Double {
                Task { @MainActor in Notifier.onStart?(id, Date(timeIntervalSince1970: since)) }
            }
            completionHandler()
        }
    }

    /// Set by the store from `NotificationSettings.sound`.
    static var sound = ""

    /// The sounds that can be picked: the system's alert sounds that build.sh copied into the
    /// bundle. Empty when running without the bundle.
    static var sounds: [String] {
        (Bundle.main.urls(forResourcesWithExtension: "aiff", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private static var notificationSound: UNNotificationSound? {
        switch sound {
        case "": return .default
        case "none": return nil
        // A sound no longer in the bundle would play nothing at all; the default is better.
        case let name where sounds.contains(name): return UNNotificationSound(named: UNNotificationSoundName(name + ".aiff"))
        default: return .default
        }
    }

    static let startAction = "start-timer"
    private static let startCategory = "no-timer"
    /// Set by the store: the reminder's "Start Timer" button.
    @MainActor static var onStart: ((UUID, Date) -> Void)?
    enum Snooze { case hour, tomorrow }
    static let snoozeHourAction = "snooze-hour"
    static let snoozeTomorrowAction = "snooze-tomorrow"
    private static let reminderCategory = "reminder"
    /// Set by the store: a task reminder was clicked (no snooze) or put off with one of its buttons.
    @MainActor static var onReminder: ((UUID, UUID, Snooze?) -> Void)?
    /// Set by the store: a click on a standup reminder opens that space's update.
    @MainActor static var onStandup: ((UUID) -> Void)?
    /// Set by the store: a click on a session's banner opens it in Orca, by its worktree id.
    @MainActor static var onSession: ((String) -> Void)?

    static func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        // .badge is needed for the Dock badge too: once an app asks for notifications, macOS hides
        // its Dock badge unless badges were part of the request.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let start = UNNotificationAction(identifier: startAction, title: "Start Timer", options: [])
        let hour = UNNotificationAction(identifier: snoozeHourAction, title: "Snooze 1 Hour", options: [])
        let tomorrow = UNNotificationAction(identifier: snoozeTomorrowAction, title: "Tomorrow Morning", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: startCategory, actions: [start], intentIdentifiers: []),
            UNNotificationCategory(identifier: reminderCategory, actions: [hour, tomorrow], intentIdentifiers: [])])
    }

    /// With `reminder`, it carries the snooze buttons and a click opens that task.
    /// With `startTask`, the notification carries a "Start Timer" button for that task, counting
    /// from `since`. A click opens the standup, else the agent session (a worktree id) in Orca,
    /// else the link; with none of them it only brings the app forward.
    static func send(title: String, subtitle: String? = nil, body: String, startTask: UUID? = nil,
                     since: Date? = nil, standup: UUID? = nil, session: String? = nil, link: URL? = nil,
                     reminder: (task: UUID, id: UUID)? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        // The list of what was sent has one text per notification.
        let body = [subtitle, body].compactMap { $0 }.joined(separator: "\n")
        content.sound = notificationSound
        var info: [String: Any] = [:]
        if let startTask, let since {
            content.categoryIdentifier = startCategory
            info["task"] = startTask.uuidString
            info["since"] = since.timeIntervalSince1970
        }
        if let standup { info["standup"] = standup.uuidString }
        if let session { info["session"] = session }
        if let link { info["link"] = link.absoluteString }
        if let reminder {
            content.categoryIdentifier = reminderCategory
            info["reminderTask"] = reminder.task.uuidString
            info["reminder"] = reminder.id.uuidString
        }
        content.userInfo = info
        record(title: title, body: body, problem: nil)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { record(title: title, body: body, problem: error.localizedDescription) }
            }
    }

    // MARK: What was sent

    /// The last notifications the app handed to macOS. Whether macOS showed them is not ours to
    /// know, so this is how to tell "never sent" from "sent and not shown".
    struct Sent: Identifiable {
        let id = UUID()
        let date: Date
        let title: String
        let body: String
        let problem: String?
    }

    private static let logKey = "sentNotifications"

    private static func record(title: String, body: String, problem: String?) {
        var list = UserDefaults.standard.array(forKey: logKey) as? [[String: Any]] ?? []
        var entry: [String: Any] = ["date": Date().timeIntervalSince1970, "title": title, "body": body]
        if let problem { entry["problem"] = problem }
        list.append(entry)
        UserDefaults.standard.set(Array(list.suffix(30)), forKey: logKey)
    }

    static func recent() -> [Sent] {
        (UserDefaults.standard.array(forKey: logKey) as? [[String: Any]] ?? []).reversed().compactMap { entry in
            guard let date = entry["date"] as? Double, let title = entry["title"] as? String else { return nil }
            return Sent(date: Date(timeIntervalSince1970: date), title: title,
                        body: entry["body"] as? String ?? "", problem: entry["problem"] as? String)
        }
    }

    /// What macOS allows this app to show, in words. Nil when everything is allowed.
    static func blocked() async -> String? {
        guard available else { return nil }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .denied: return "macOS is blocking TaskDeck's notifications."
        case .notDetermined: return "macOS has not been asked to allow TaskDeck's notifications yet."
        default: break
        }
        if settings.alertSetting != .enabled || settings.alertStyle == .none {
            return "TaskDeck's notifications are allowed, but their style is set to None, so nothing appears on screen."
        }
        return nil
    }
}
