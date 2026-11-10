import SwiftUI

/// One tracked stretch of a task: editable start (and end, once stopped), its state and a delete button.
/// An entry that was already sent to the tracker is read-only.
struct TimeEntryRow: View {
    @Binding var entry: TimeEntry
    let now: Date
    let onDelete: () -> Void

    private var logged: Bool { entry.loggedAt != nil }

    var body: some View {
        HStack(spacing: 6) {
            if logged {
                Text(entry.start.formatted(date: .abbreviated, time: .shortened))
                Text("→").foregroundStyle(.secondary)
                Text((entry.end ?? now).formatted(date: .omitted, time: .shortened))
            } else {
                DatePicker("Start", selection: $entry.start, in: ...(entry.end ?? now),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .fixedSize()
                    .help("When this stretch started")
                Text("→").foregroundStyle(.secondary)
                if entry.end == nil {
                    Text("running").foregroundStyle(Theme.accent)
                } else {
                    DatePicker("End", selection: Binding(get: { entry.end ?? now }, set: { entry.end = $0 }),
                               in: entry.start..., displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .fixedSize()
                        .help("When this stretch ended")
                }
            }
            Spacer(minLength: 8)
            if logged {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .help("Already logged to the tracker")
            } else if entry.end != nil {
                Text("to log").font(.caption).foregroundStyle(.orange)
            }
            Text(Fmt.short(entry.duration(now: now))).monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(logged ? "Remove from this app (the time stays on the tracker)"
                      : entry.end == nil ? "Stop the timer and discard this stretch" : "Remove this entry")
        }
        .font(.callout)
    }
}

/// The task's time entries, newest first, edited live in the store.
struct TimeEntriesList: View {
    @Environment(AppStore.self) private var store
    let taskId: UUID
    @State private var deleting: TimeEntry?

    var body: some View {
        let entries = (store.task(taskId)?.entries ?? []).sorted { $0.start > $1.start }
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No time tracked yet.").foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                TimeEntryRow(entry: Binding(get: { entry }, set: { store.updateEntry(task: taskId, $0) }),
                             now: store.now,
                             onDelete: { deleting = entry })
                    .padding(.vertical, 4)
                Divider()
            }
        }
        .confirmationDialog("Delete this time entry?", isPresented: Binding(get: { deleting != nil },
                                                                          set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { entry in
            Button("Delete", role: .destructive) { store.deleteEntry(task: taskId, entry: entry.id) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\(entry.start.formatted(date: .abbreviated, time: .shortened)) · \(Fmt.short(entry.duration(now: store.now)))"
                 + (entry.loggedAt != nil ? "\nIt was already logged; the time stays on the tracker." : ""))
        }
    }
}
