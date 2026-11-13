import SwiftUI

/// Logs a task's not-yet-logged time to Redmine: one Redmine entry per tracked stretch (each stop of the timer).
struct LogTimeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: UUID

    struct DayRow: Identifiable {
        let id = UUID()
        var day: Date
        /// "09:12 – 10:40" for a tracked stretch; empty for hours typed by hand.
        var span = ""
        var manual = false
        var include = true
        var hours: String
        let entryIds: Set<UUID>
        var done = false
    }

    @State private var rows: [DayRow] = []
    @State private var activities: [RedmineClient.Activity] = []
    @State private var activityId: Int?
    @State private var comment = ""
    @State private var busy = false
    @State private var suggesting = false
    @State private var suggested = false
    @State private var suggestionSource = "the ticket"
    @State private var suggestError: String?
    @State private var message: String?
    @State private var failed = false

    private var task: TaskItem? { store.task(taskId) }
    private var project: Project? { store.project(task?.projectId) }

    private func parse(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private var pending: [DayRow] { rows.filter { $0.include && !$0.done } }
    private var canSubmit: Bool {
        !busy && !pending.isEmpty && pending.allSatisfy { (parse($0.hours) ?? 0) > 0 }
            && Int(task?.ref ?? "") != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Log time to Redmine").font(.title3.weight(.semibold))
                if let task {
                    Text("\(task.displayRef) \(task.title)").foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(14)
            Divider()

            Form {
                if let task, Int(task.ref) == nil {
                    Text("Ticket “\(task.ref)” is not a Redmine issue number.")
                        .foregroundStyle(.red)
                }
                if task?.isRunning == true {
                    Text("The timer is running — the current stretch is only included after you pause it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Entries to log") {
                    if rows.isEmpty {
                        Text("No tracked time pending.").foregroundStyle(.secondary)
                    }
                    ForEach($rows) { $row in
                        HStack {
                            if row.done {
                                // Already sent: nothing left to switch on or off.
                                rowLabel(row)
                            } else {
                                Toggle(isOn: $row.include) {
                                    if row.manual {
                                        DatePicker("", selection: $row.day, in: ...Date(), displayedComponents: .date)
                                            .labelsHidden()
                                    } else {
                                        rowLabel(row)
                                    }
                                }
                            }
                            Spacer()
                            if row.done {
                                // Only the icon is green; green text reads badly on the dark form.
                                HStack(spacing: 5) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text("Logged").foregroundStyle(.secondary)
                                }
                            } else {
                                TextField("", text: $row.hours)
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 64)
                                Text("h").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button {
                    rows.append(DayRow(day: Calendar.current.startOfDay(for: Date()), manual: true, hours: "", entryIds: []))
                } label: {
                    Label("Add untracked hours", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Logs hours that weren't tracked in the app")
                Section {
                    Picker("Activity", selection: $activityId) {
                        Text("Redmine default").tag(Int?.none)
                        ForEach(activities) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    HStack {
                        TextField("Comment", text: $comment,
                                  prompt: Text(suggesting ? "Claude is writing a proposal…" : "optional"))
                            .disabled(suggesting)
                        Button { Task { await suggest(auto: false) } } label: {
                            HStack(spacing: 4) {
                                ZStack {
                                    Image(systemName: "sparkles").opacity(suggesting ? 0 : 1)
                                    if suggesting { ProgressView().controlSize(.small) }
                                }
                                Text("Generate")
                            }
                        }
                        .controlSize(.small)
                        .disabled(suggesting)
                        .help("Ask Claude to propose a comment from the ticket")
                    }
                    if let suggestError {
                        Text(suggestError).font(.caption).foregroundStyle(.red)
                    } else if suggested {
                        Text("Proposed by Claude from \(suggestionSource). Check it before you log.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? .red : .green)
                        Text(message).foregroundStyle(failed ? Color.red : Color.primary)
                    }
                    .font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Log") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(14)
        }
        .frame(width: 500)
        .frame(minHeight: 420)
        .task {
            await prepare()
            if store.autoLogComment { await suggest(auto: true) }
        }
    }

    private func rowLabel(_ row: DayRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.day.formatted(date: .abbreviated, time: .omitted))
            if !row.span.isEmpty {
                Text(row.span).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func prepare() async {
        guard let task else { return }
        let cal = Calendar.current
        rows = task.entries.filter { $0.end != nil && $0.loggedAt == nil }.sorted { $0.start < $1.start }.map { entry in
            // Never suggest 0.00 for a short stretch.
            let hours = max(0.01, (entry.duration(now: Date()) / 3600 * 100).rounded() / 100)
            let span = entry.start.formatted(date: .omitted, time: .shortened) + " – "
                + (entry.end ?? entry.start).formatted(date: .omitted, time: .shortened)
            return DayRow(day: cal.startOfDay(for: entry.start), span: span,
                          hours: String(format: "%.2f", hours), entryIds: [entry.id])
        }
        activityId = project?.defaultActivityId

        guard let project, let client = RedmineClient(project: project) else {
            failed = true
            message = "Set the project's base URL and API key in Settings → Projects."
            return
        }
        do {
            activities = try await client.activities()
            if activityId == nil {
                activityId = activities.first { $0.is_default == true }?.id
            }
        } catch {
            failed = true
            message = "Could not load activities: \(error.localizedDescription)"
        }
    }

    /// Asks Claude for a short comment for the time entry, from the ticket and my earlier log comments.
    /// Automatic when the sheet opens (only if a Claude key is set and the field is empty); the button replaces the text.
    private func suggest(auto: Bool) async {
        guard let task, let project, !suggesting else { return }
        if auto && !comment.isEmpty { return }
        Claude.adoptLegacyKey(from: store.projects)
        if auto && Claude.apiKey() == nil { return }
        suggesting = true
        suggestError = nil
        let previous = comment
        defer { suggesting = false }
        do {
            let proposal = try await LogComment.propose(
                task: task, project: project, days: Set(pending.map(\.day)),
                hours: pending.compactMap { parse($0.hours) }.reduce(0, +),
                model: store.claudeModel, instructions: store.aiInstructions) { comment = $0 }
            comment = proposal.text
            suggestionSource = proposal.source
            suggested = !comment.isEmpty
        } catch {
            comment = previous
            if !auto { suggestError = "Could not get a proposal: \(error.localizedDescription)" }
        }
    }

    private func submit() async {
        guard let task, let project, let issueId = Int(task.ref) else { return }
        guard let client = RedmineClient(project: project) else {
            failed = true
            message = "Set the project's base URL and API key in Settings → Projects."
            return
        }
        busy = true
        message = nil
        failed = false
        defer { busy = false }

        var total = 0.0
        for i in rows.indices where rows[i].include && !rows[i].done {
            guard let hours = parse(rows[i].hours), hours > 0 else { continue }
            do {
                try await client.logTime(issueId: issueId, hours: hours, day: rows[i].day,
                                         activityId: activityId, comments: comment)
                // Mark right away: if a later entry fails, this one isn't logged twice.
                store.markLogged(task: taskId, entries: rows[i].entryIds)
                rows[i].done = true
                total += hours
            } catch {
                failed = true
                message = "Failed on \(rows[i].day.formatted(date: .abbreviated, time: .omitted)): \(error.localizedDescription)"
                return
            }
        }
        message = String(format: "%.2f h logged to issue #%d.", total, issueId)
    }
}
