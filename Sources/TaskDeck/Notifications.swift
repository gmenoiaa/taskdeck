import Foundation
import AppKit
import UserNotifications

/// Which notifications the app sends. Every field has a default, so a file saved before a field
/// existed still loads.
struct NotificationSettings: Codable, Equatable {
    /// An agent stopped, opened a pull request, or the queue could not start one.
    var sessions = true
    /// A pull request of one of the board's sessions was merged or closed.
    var pullRequests = true
    /// A ticket was assigned to me in a tracker.
    var assigned = true
    /// Time stopped and not logged yet, once a day from `unloggedHour` on.
    var unlogged = true
    var unloggedHour = 18
    /// A timer that has been running for `longTimerHours`, and again each time that passes.
    var longTimer = true
    var longTimerHours = 2

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
    }
}

extension AppStore {
    /// Orca is only asked in the background when a notification depends on the answer.
    var watchesSessionsInBackground: Bool {
        queueNeedsAttention || notify.sessions || notify.pullRequests
    }

    private func label(_ task: TaskItem) -> String {
        let text = "\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "(untitled)" : text
    }

    /// Compares each session with the last look: an agent that stopped working, and a pull request
    /// that was merged or closed. The first look after launch only takes note.
    func noticeSessionChanges() {
        // No answer from Orca says nothing about the sessions, so the last look is kept.
        guard sessionStatuses != nil else { return }
        var seen: [String: Orca.Status.Kind] = [:]
        for task in tasks where !task.archived {
            for session in sessions(of: task) {
                guard let id = session.worktreeId, let status = status(of: session) else { continue }
                seen[id] = status.kind
                guard let before = sessionKinds[id], before != status.kind else { continue }
                switch status.kind {
                case .prMerged:
                    if notify.pullRequests { Notifier.send(title: "Pull request merged", body: label(task)) }
                case .prClosed:
                    if notify.pullRequests { Notifier.send(title: "Pull request closed", body: label(task)) }
                case .yourTurn, .prOpen, .idle:
                    guard before == .working, notify.sessions else { break }
                    let title = status.kind == .prOpen ? "Pull request opened"
                        : status.kind == .yourTurn ? "Your turn" : "Agent stopped"
                    let tail = status.lastMessage.map { "\n\(String($0.suffix(160)))" } ?? ""
                    Notifier.send(title: title, body: label(task) + tail)
                case .working, .gone:
                    break
                }
            }
        }
        sessionKinds = seen
    }

    /// The two reminders about time: stopped time not logged at the end of the day, and a timer that
    /// has been running for hours. Called every few seconds; each sends at most once per occasion.
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

    /// Looks at what is assigned to me in every tracker and reports tickets not seen before.
    /// The very first look only takes note, so turning this on does not report the whole backlog.
    func noticeNewAssignments() async {
        guard notify.assigned else { return }
        var current: [RemoteTicket] = []
        for project in projects where project.kind != .other {
            // A tracker that cannot be read now is simply looked at again next time.
            if let list = try? await TicketFetcher.assigned(project: project) { current += list }
        }
        guard !current.isEmpty else { return }
        let ids = Set(current.map(\.id))
        guard let known = knownAssigned else {
            knownAssigned = ids
            save()
            return
        }
        let onBoard = Set(tasks.map { "\($0.projectId?.uuidString ?? "")|\($0.ref.lowercased())" })
        let fresh = current.filter { !known.contains($0.id) && !onBoard.contains($0.id) }
        guard !ids.isSubset(of: known) else { return }
        knownAssigned = known.union(ids)
        save()
        if fresh.count > 3 {
            Notifier.send(title: "\(fresh.count) tickets assigned to you",
                          body: fresh.prefix(3).map { "\($0.displayRef) \($0.title)" }.joined(separator: "\n"))
        } else {
            for ticket in fresh {
                let space = project(ticket.projectId)?.name ?? ""
                Notifier.send(title: "Ticket assigned to you",
                              body: "\(ticket.displayRef) \(ticket.title)" + (space.isEmpty ? "" : "\n\(space)"))
            }
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
    }

    static func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        // .badge is needed for the Dock badge too: once an app asks for notifications, macOS hides
        // its Dock badge unless badges were part of the request.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func send(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
