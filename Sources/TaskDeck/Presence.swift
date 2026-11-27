import AppKit
import SwiftUI

/// Choices offered right after a timer starts, for when the work began before the click.
struct BackdateOffer: Equatable {
    struct Option: Identifiable, Equatable {
        let date: Date
        let label: String
        var id: Date { date }
    }
    let taskId: UUID
    let entryId: UUID
    let options: [Option]
    let made: Date
}

/// Whether the user is at this Mac, readable from anywhere: the notifier asks it off the main actor.
enum UserActivity {
    /// Seconds since the last key press or pointer movement, in any app. Needs no permission.
    static var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Screen locked, display off or the Mac going to sleep. Kept by the store from its away reasons.
    nonisolated(unsafe) static var screenAway = false

    /// Away: the screen is locked or off, or nothing was touched for `idleMinutes`.
    static func isAway(idleMinutes: Int) -> Bool {
        screenAway || idleSeconds >= TimeInterval(idleMinutes * 60)
    }
}

/// Forgetting to start the timer: knowing when the user is at the Mac, reminding when no timer
/// runs, and letting a late start count from when the work really began.
extension AppStore {
    private static var idleSeconds: TimeInterval { UserActivity.idleSeconds }

    /// Called every few seconds: five quiet minutes, a locked screen or sleep end a sitting, and
    /// the next sign of life starts a new one.
    func trackPresence() {
        if isAway || Self.idleSeconds >= 300 {
            if activeSince != nil { activeSince = nil }
        } else if activeSince == nil {
            activeSince = Date()
        }
        if let offer = backdateOffer, Date().timeIntervalSince(offer.made) > 90 { backdateOffer = nil }
    }

    private var lastTimerStop: Date? { tasks.flatMap(\.entries).compactMap(\.end).max() }

    /// Since when the user has been at the Mac with nothing being tracked. Nil while a timer
    /// runs or nobody is there.
    var untrackedSince: Date? {
        guard runningTasks.isEmpty, let active = activeSince else { return nil }
        return max(active, lastTimerStop ?? .distantPast)
    }

    private func inWorkingHours(_ date: Date) -> Bool {
        let calendar = Calendar.current
        if !notify.noTimerWeekends, calendar.isDateInWeekend(date) { return false }
        let hour = calendar.component(.hour, from: date)
        return hour >= notify.workFrom && hour < notify.workTo
    }

    /// True when it looks like work is going on untracked: what the reminder and the menu bar's
    /// icon go by.
    var forgotTimer: Bool {
        guard notify.noTimer, let since = untrackedSince, inWorkingHours(now) else { return false }
        guard tasks.contains(where: { !$0.archived && role(of: $0.status) != .done }) else { return false }
        return now.timeIntervalSince(since) >= TimeInterval(max(1, notify.noTimerMinutes)) * 60
    }

    /// The card the user is most likely on, going by the agents: one working, or waiting for them.
    private var likelyTask: TaskItem? {
        var waiting: TaskItem?
        for task in tasks where !task.archived && role(of: task.status) != .done {
            for session in sessions(of: task) {
                switch status(of: session)?.kind {
                case .working: return task
                case .yourTurn: if waiting == nil { waiting = task }
                default: break
                }
            }
        }
        return waiting
    }

    /// Once per sitting without a timer, and again every half hour while it lasts.
    func noticeNoTimer() {
        guard forgotTimer, let since = untrackedSince else { return }
        let now = Date()
        if let last = noTimerRemindedAt, last >= since, now.timeIntervalSince(last) < 1800 { return }
        noTimerRemindedAt = now
        let spent = Fmt.short(now.timeIntervalSince(since))
        if let task = likelyTask {
            let name = "\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces)
            Notifier.send(kind: .time, title: "No timer running",
                          body: "You have been at the Mac for \(spent). An agent is active on \(name).",
                          startTask: task.id, since: since)
        } else {
            Notifier.send(kind: .time, title: "No timer running",
                          body: "You have been at the Mac for \(spent) with nothing being tracked.")
        }
    }

    /// What a start could be moved back to, worked out before the timer starts: the moment the
    /// user sat down, or the moment the last timer stopped. Only gaps worth the question.
    func backdateOptions() -> [BackdateOffer.Option] {
        // Another timer was running until now: there is no untracked gap to give back.
        guard runningTasks.isEmpty else { return [] }
        let now = Date()
        func worth(_ date: Date) -> Bool {
            let gap = now.timeIntervalSince(date)
            return gap >= 120 && gap <= 4 * 3600
        }
        func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        var options: [BackdateOffer.Option] = []
        let stop = lastTimerStop
        // Earlier than the last stop it would overlap time already tracked.
        if let active = activeSince, worth(active), active > (stop ?? .distantPast) {
            options.append(.init(date: active, label: "\(clock(active)), when you sat down"))
        }
        if let stop, worth(stop), Calendar.current.isDateInToday(stop) {
            options.append(.init(date: stop, label: "\(clock(stop)), when the last timer stopped"))
        }
        return options.sorted { $0.date > $1.date }
    }

    func applyBackdate(_ option: BackdateOffer.Option) {
        guard let offer = backdateOffer, let task = task(offer.taskId),
              var entry = task.entries.first(where: { $0.id == offer.entryId && $0.end == nil }) else {
            backdateOffer = nil
            return
        }
        entry.start = option.date
        updateEntry(task: offer.taskId, entry)
        backdateOffer = nil
    }

    /// Starts a task's timer from an earlier moment: the "Start Timer" button of the reminder.
    func startTimer(_ id: UUID, from since: Date) {
        guard let task = task(id), !task.isRunning else { return }
        let start = max(since, lastTimerStop ?? .distantPast)
        toggleTimer(id)
        backdateOffer = nil
        if var entry = self.task(id)?.entries.first(where: { $0.end == nil }) {
            entry.start = start
            updateEntry(task: id, entry)
        }
    }
}

/// "Timer started. Count from …?" Shown for a short while after a start that came late.
struct BackdateBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let offer = store.backdateOffer, let task = store.task(offer.taskId), task.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
                    Text("Timer started on \(task.displayRef.isEmpty ? task.title : task.displayRef). Did you start earlier?")
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { store.backdateOffer = nil } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Keep the start as it is")
                }
                HStack(spacing: 6) {
                    ForEach(offer.options) { option in
                        Button("From \(option.label)") { store.applyBackdate(option) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }
}
