import SwiftUI

/// A task's due date: the one set here, or else the ticket's own in its tracker. Setting one here
/// changes nothing in the tracker.
enum Due {
    /// A tracker's day ("2026-11-27") as the start of that day here.
    static func day(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: String(text.prefix(10))).map { Calendar.current.startOfDay(for: $0) }
    }

    /// Whole days from today: negative when overdue.
    static func daysLeft(_ date: Date, now: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
    }

    /// "Today", "Tomorrow", "Fri" within the week, otherwise "27 Nov".
    static func label(_ date: Date) -> String {
        switch daysLeft(date) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    static func color(_ date: Date) -> Color {
        let left = daysLeft(date)
        return left < 0 ? .red : left <= 1 ? .orange : .secondary
    }

    static func help(_ task: TaskItem) -> String {
        guard let date = task.due else { return "" }
        let left = daysLeft(date)
        let day = date.formatted(date: .complete, time: .omitted)
        let when = left < 0 ? "Overdue by \(-left) day\(left == -1 ? "" : "s")" : left == 0 ? "Due today" : "Due in \(left) day\(left == 1 ? "" : "s")"
        return "\(when): \(day)" + (task.dueDate == nil ? " (from the ticket)" : "")
    }

    /// The quick choices of the card menu.
    static var shortcuts: [(String, Date)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func plus(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: today) ?? today }
        // The coming Friday and Monday; today does not count as "this Friday" once it is Friday.
        func next(_ weekday: Int) -> Date {
            cal.nextDate(after: today, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? today
        }
        return [("Today", today), ("Tomorrow", plus(1)), ("Friday", next(6)), ("Next Monday", next(2)), ("In two weeks", plus(14))]
    }
}

/// The date on a card or in the details.
struct DueChip: View {
    let date: Date
    /// Icon only, in the date's colour, for a card row with no room for the word.
    var compact = false
    var body: some View {
        if compact {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Due.color(date))
                .frame(width: 20, height: 20)
                .background(Due.color(date).opacity(0.14), in: Circle())
        } else {
            HStack(spacing: 3) {
                Image(systemName: "calendar").font(.system(size: 9, weight: .semibold))
                Text(Due.label(date)).font(.caption.weight(.medium))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(Due.color(date))
            .background(Due.color(date).opacity(0.14), in: Capsule())
        }
    }
}

/// The items of a "Due date" menu.
struct DueMenuItems: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    let pick: () -> Void

    var body: some View {
        ForEach(Due.shortcuts, id: \.0) { item in
            Button("\(item.0) — \(item.1.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))") {
                store.setDue(task.id, item.1)
            }
        }
        Button("Pick a date…", action: pick)
        if task.dueDate != nil {
            Divider()
            // With a date in the tracker, removing mine falls back to that one.
            Button(task.remoteDue == nil ? "Remove due date" : "Use the ticket's date") { store.setDue(task.id, nil) }
        }
    }
}

/// A calendar to pick the date from.
struct DuePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: UUID
    @State private var date = Calendar.current.startOfDay(for: Date())

    var body: some View {
        let task = store.task(taskId)
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Due date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            if let remote = task?.remoteDue {
                Text("The ticket itself is due \(remote.formatted(date: .abbreviated, time: .omitted)). A date set here is only kept in TaskDeck.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if task?.dueDate != nil {
                    Button(task?.remoteDue == nil ? "Remove" : "Use the ticket's date") {
                        store.setDue(taskId, nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") {
                    store.setDue(taskId, date)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { if let due = task?.due { date = due } }
    }
}
