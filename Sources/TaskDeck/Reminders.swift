import SwiftUI

/// A task's reminders: a notification at a time the user picked. They are sent by the app's own
/// loop like every other notification, so one that comes due while the app is closed is sent at
/// the next launch.
enum Reminders {
    /// "14:30" today, otherwise "Tomorrow 09:00", "Fri 09:00", "27 Nov 09:00".
    static func label(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Due.daysLeft(date) == 0 ? time : "\(Due.label(date)) \(time)"
    }

    /// The reminder a card shows: one that came due and was not answered, or else the next one.
    static func shown(_ task: TaskItem) -> TaskReminder? {
        let list = task.reminderList
        return list.first { $0.firedAt != nil } ?? list.first
    }

    static func help(_ task: TaskItem) -> String {
        task.reminderList.map { reminder in
            let when = reminder.at.formatted(date: .complete, time: .shortened)
            let text = reminder.firedAt == nil ? "Reminder on \(when)" : "Reminder was due \(when)"
            return reminder.note.isEmpty ? text : "\(text): \(reminder.note)"
        }.joined(separator: "\n")
    }

    /// A day's morning: the hour the working day starts in the settings.
    static func morning(_ day: Date, hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    static func tomorrowMorning(hour: Int, now: Date = Date()) -> Date {
        let cal = Calendar.current
        return morning(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now, hour: hour)
    }

    /// The quick choices of the menu. The board redraws every second (the toolbar's total for
    /// today), and SwiftUI rebuilds an open submenu when what its buttons hold is not bit for bit
    /// what it was: a time worked out from "now", or a title put together on the spot. So a
    /// button holds only its case, and works the time out when it is picked.
    enum Shortcut: String, CaseIterable, Identifiable {
        case hour = "In 1 hour", afternoon = "This afternoon", tomorrow = "Tomorrow morning"
        case monday = "Next Monday", dueDay = "On the due day"
        var id: String { rawValue }

        func date(due: Date?, morningHour: Int, now: Date = Date()) -> Date? {
            let cal = Calendar.current
            let today = cal.startOfDay(for: now)
            switch self {
            case .hour: return now.addingTimeInterval(3600)
            case .afternoon: return cal.date(bySettingHour: 15, minute: 0, second: 0, of: today)
            case .tomorrow: return Reminders.tomorrowMorning(hour: morningHour, now: now)
            case .monday:
                return cal.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)
                    .map { Reminders.morning($0, hour: morningHour) }
            case .dueDay: return due.map { Reminders.morning($0, hour: morningHour) }
            }
        }

        /// The time is left out of "In 1 hour": it would change the item every minute.
        func title(_ date: Date) -> String { self == .hour ? rawValue : "\(rawValue) — \(Reminders.label(date))" }
    }

    /// The choices worth offering now: only times still ahead, and no two at the same moment.
    static func shortcuts(due: Date?, morningHour: Int, now: Date = Date()) -> [Shortcut] {
        var taken: Set<Date> = []
        return Shortcut.allCases.compactMap { shortcut in
            guard let date = shortcut.date(due: due, morningHour: morningHour, now: now),
                  // "This afternoon" needs to be a little way off to be worth a line.
                  date.timeIntervalSince(now) > (shortcut == .afternoon ? 30 * 60 : 0),
                  taken.insert(date).inserted else { return nil }
            return shortcut
        }
    }
}

extension AppStore {
    func addReminder(_ id: UUID, at date: Date, note: String = "") {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        // Whole minutes: the picker and "in 1 hour" both carry the seconds of the moment they were made.
        let whole = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
        tasks[i].reminders = (tasks[i].reminders ?? []) +
            [TaskReminder(at: whole, note: note.trimmingCharacters(in: .whitespacesAndNewlines))]
        save()
    }

    func removeReminder(task id: UUID, _ reminderId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].reminders?.removeAll { $0.id == reminderId }
        // No empty list left in the file of a task that has no reminders.
        if tasks[i].reminders?.isEmpty == true { tasks[i].reminders = nil }
        save()
    }

    /// Puts a reminder off: it counts as not said yet and comes again at `date`.
    func snoozeReminder(task id: UUID, _ reminderId: UUID, until date: Date) {
        guard let i = tasks.firstIndex(where: { $0.id == id }),
              let r = tasks[i].reminders?.firstIndex(where: { $0.id == reminderId }) else { return }
        tasks[i].reminders?[r].at = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
        tasks[i].reminders?[r].firedAt = nil
        save()
    }

    /// What a reminder's banner was answered with: one of its snooze buttons, or a click, which
    /// opens the task and ends the reminder.
    func answerReminder(task id: UUID, id reminderId: UUID, snooze: Notifier.Snooze?) {
        switch snooze {
        case .hour: snoozeReminder(task: id, reminderId, until: Date().addingTimeInterval(3600))
        case .tomorrow: snoozeReminder(task: id, reminderId, until: Reminders.tomorrowMorning(hour: notify.workFrom))
        case nil:
            removeReminder(task: id, reminderId)
            openTask = id
        }
    }

    /// Sends the reminders that came due. Called every few seconds; each is sent once.
    func noticeReminders() {
        // Asleep or locked, a banner would go unseen: it is held until the user is back.
        guard !isAway else { return }
        let now = Date()
        var sent = false
        // Archived tasks keep their reminders but say nothing while off the board.
        for i in tasks.indices where !tasks[i].archived {
            for r in (tasks[i].reminders ?? []).indices
            where tasks[i].reminders?[r].firedAt == nil && (tasks[i].reminders?[r].at ?? now) <= now {
                tasks[i].reminders?[r].firedAt = now
                sent = true
                // With the notification off it still counts as due, and shows in the bell's list.
                guard notify.reminders, let reminder = tasks[i].reminders?[r] else { continue }
                let task = tasks[i]
                if reminder.note.isEmpty {
                    Notifier.send(kind: .reminders, title: "Reminder", body: label(task), reminder: (task.id, reminder.id))
                } else {
                    Notifier.send(kind: .reminders, title: "Reminder", subtitle: label(task), body: reminder.note,
                                  reminder: (task.id, reminder.id))
                }
            }
        }
        if sent { save() }
    }
}

/// The bell on a card: when the next reminder comes, in orange once it came due.
struct ReminderChip: View {
    let reminder: TaskReminder
    var body: some View {
        let color: Color = reminder.firedAt == nil ? .secondary : .orange
        HStack(spacing: 3) {
            Image(systemName: reminder.firedAt == nil ? "bell" : "bell.badge.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(Reminders.label(reminder.at)).font(.caption.weight(.medium)).monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
    }
}

/// The items of a "Remind me" menu.
struct ReminderMenuItems: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    let pick: () -> Void

    var body: some View {
        ForEach(Reminders.shortcuts(due: task.due, morningHour: store.notify.workFrom)) { shortcut in
            Button(title(shortcut)) { add(shortcut) }
        }
        Button("Pick a date and time…", action: pick)
        let list = task.reminderList
        if !list.isEmpty {
            Divider()
            ForEach(list) { reminder in
                // Only the id goes into the button, for the same reason as above.
                let id = reminder.id
                Button("Remove \(Reminders.label(reminder.at))" + (reminder.note.isEmpty ? "" : " — \(reminder.note)")) {
                    store.removeReminder(task: task.id, id)
                }
            }
        }
    }
}

extension ReminderMenuItems {
    private func title(_ shortcut: Reminders.Shortcut) -> String {
        shortcut.date(due: task.due, morningHour: store.notify.workFrom).map(shortcut.title) ?? shortcut.rawValue
    }

    private func add(_ shortcut: Reminders.Shortcut) {
        guard let date = shortcut.date(due: task.due, morningHour: store.notify.workFrom) else { return }
        store.addReminder(task.id, at: date)
    }
}

/// The task's reminders, and a date, a time and a note to add another.
struct ReminderPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: UUID
    @State private var date = Date().addingTimeInterval(3600)
    @State private var note = ""

    var body: some View {
        let list = store.task(taskId)?.reminderList ?? []
        VStack(alignment: .leading, spacing: 10) {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(list) { reminder in
                        HStack(spacing: 6) {
                            Image(systemName: reminder.firedAt == nil ? "bell" : "bell.badge.fill")
                                .foregroundStyle(reminder.firedAt == nil ? Color.secondary : Color.orange)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(Reminders.label(reminder.at)).font(.callout)
                                if !reminder.note.isEmpty {
                                    Text(reminder.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            Button { store.removeReminder(task: taskId, reminder.id) } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove this reminder")
                        }
                    }
                }
                Divider()
            }
            DatePicker("Remind me on", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            TextField("Note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Text("Kept in TaskDeck only. The note is shown in the notification and is not sent to Claude or the tracker.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(list.isEmpty ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(date <= Date())
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func add() {
        guard date > Date() else { return }
        store.addReminder(taskId, at: date, note: note)
        dismiss()
    }
}
