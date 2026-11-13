import SwiftUI

/// Every tracked stretch that was not sent to Redmine yet, for all tasks: pick the ones to send
/// and push them in one go. One Redmine time entry per stretch; one comment and activity per task.
struct PendingTimeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id: UUID            // the time entry's id
        let day: Date
        let span: String
        var hours: String
        var include = true
        var done = false
    }

    struct Group: Identifiable {
        let id: UUID            // the task's id
        let projectId: UUID
        var rows: [Row]
        var comment = ""
        var activityId: Int?
        var suggesting = false
        var source: String?
        var error: String?
    }

    @State private var groups: [Group] = []
    @State private var activities: [UUID: [RedmineClient.Activity]] = [:]
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    private func parse(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func selected(_ group: Group) -> [Row] { group.rows.filter { $0.include && !$0.done } }
    private func hours(_ rows: [Row]) -> Double { rows.compactMap { parse($0.hours) }.reduce(0, +) }

    private var allSelected: [Row] { groups.flatMap(selected) }
    private var canPush: Bool {
        !busy && !allSelected.isEmpty && allSelected.allSatisfy { (parse($0.hours) ?? 0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Time to push").font(.title3.weight(.semibold))
                Text("Tracked time that is not on Redmine yet. Each selected line becomes one time entry.")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()

            Form {
                if groups.isEmpty {
                    Text("Nothing to push: all tracked time is on Redmine.").foregroundStyle(.secondary)
                }
                ForEach($groups) { $group in
                    section($group)
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
                Button(allSelected.count == groups.flatMap(\.rows).filter { !$0.done }.count ? "Select none" : "Select all") {
                    let on = allSelected.count != groups.flatMap(\.rows).filter { !$0.done }.count
                    for g in groups.indices { for r in groups[g].rows.indices { groups[g].rows[r].include = on } }
                }
                .disabled(busy || groups.flatMap(\.rows).allSatisfy(\.done))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(allSelected.isEmpty ? "Push"
                       : String(format: "Push %d · %.2f h", allSelected.count, hours(allSelected))) {
                    Task { await push() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPush)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
        .task {
            prepare()
            await loadActivities()
            if store.autoLogComment {
                Claude.adoptLegacyKey(from: store.projects)
                if Claude.apiKey() != nil {
                    for id in groups.map(\.id) { await propose(id, auto: true) }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ group: Binding<Group>) -> some View {
        let g = group.wrappedValue
        let task = store.task(g.id)
        let project = store.project(g.projectId)
        Section {
            ForEach(group.rows) { $row in
                HStack {
                    if row.done {
                        rowLabel(row)
                    } else {
                        Toggle(isOn: $row.include) { rowLabel(row) }
                    }
                    Spacer()
                    if row.done {
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
            if !g.rows.allSatisfy(\.done) {
                HStack {
                    TextField("Comment", text: group.comment,
                              prompt: Text(g.suggesting ? "Claude is writing a proposal…" : "optional"))
                        .disabled(g.suggesting)
                    Button { Task { await propose(g.id, auto: false) } } label: {
                        HStack(spacing: 4) {
                            ZStack {
                                Image(systemName: "sparkles").opacity(g.suggesting ? 0 : 1)
                                if g.suggesting { ProgressView().controlSize(.small) }
                            }
                            Text("Generate")
                        }
                    }
                    .controlSize(.small)
                    .disabled(g.suggesting)
                    .help("Ask Claude to propose a comment")
                }
                Picker("Activity", selection: group.activityId) {
                    Text("Redmine default").tag(Int?.none)
                    ForEach(activities[g.projectId] ?? []) { Text($0.name).tag(Int?.some($0.id)) }
                }
            }
            if let error = g.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let source = g.source {
                Text("Comment proposed by Claude from \(source). Check it before you push.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Circle().fill(project?.color ?? .gray).frame(width: 8, height: 8)
                Text(task?.displayRef ?? "").foregroundStyle(Theme.accent)
                Text(task?.title ?? "").lineLimit(1)
                Spacer()
                Text(String(format: "%.2f h", hours(selected(g)))).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func rowLabel(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.day.formatted(date: .abbreviated, time: .omitted))
            Text(row.span).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func prepare() {
        let cal = Calendar.current
        groups = store.pendingLogTasks.compactMap { task in
            guard let projectId = task.projectId else { return nil }
            let rows = task.entries.filter { $0.end != nil && $0.loggedAt == nil }.sorted { $0.start < $1.start }.map { entry in
                // Never suggest 0.00 for a short stretch.
                let hours = max(0.01, (entry.duration(now: Date()) / 3600 * 100).rounded() / 100)
                let span = entry.start.formatted(date: .omitted, time: .shortened) + " – "
                    + (entry.end ?? entry.start).formatted(date: .omitted, time: .shortened)
                return Row(id: entry.id, day: cal.startOfDay(for: entry.start), span: span,
                           hours: String(format: "%.2f", hours))
            }
            return Group(id: task.id, projectId: projectId, rows: rows,
                         activityId: store.project(projectId)?.defaultActivityId)
        }
    }

    private func loadActivities() async {
        for projectId in Set(groups.map(\.projectId)) {
            guard let project = store.project(projectId), let client = RedmineClient(project: project),
                  let list = try? await client.activities() else { continue }
            activities[projectId] = list
            let fallback = list.first { $0.is_default == true }?.id
            for i in groups.indices where groups[i].projectId == projectId && groups[i].activityId == nil {
                groups[i].activityId = fallback
            }
        }
    }

    private func propose(_ id: UUID, auto: Bool) async {
        guard let i = groups.firstIndex(where: { $0.id == id }), !groups[i].suggesting,
              let task = store.task(id), let project = store.project(groups[i].projectId) else { return }
        Claude.adoptLegacyKey(from: store.projects)
        if auto && !groups[i].comment.isEmpty { return }
        let rows = selected(groups[i])
        let previous = groups[i].comment
        groups[i].suggesting = true
        groups[i].error = nil
        func update(_ change: (inout Group) -> Void) {
            if let j = groups.firstIndex(where: { $0.id == id }) { change(&groups[j]) }
        }
        do {
            let proposal = try await LogComment.propose(
                task: task, project: project, days: Set(rows.map(\.day)), hours: hours(rows),
                model: store.claudeModel, instructions: store.aiInstructions) { text in
                    update { $0.comment = text }
                }
            update {
                $0.comment = proposal.text
                $0.source = proposal.text.isEmpty ? nil : proposal.source
            }
        } catch {
            update {
                $0.comment = previous
                if !auto { $0.error = "Could not get a proposal: \(error.localizedDescription)" }
            }
        }
        update { $0.suggesting = false }
    }

    private func push() async {
        busy = true
        message = nil
        failed = false
        defer { busy = false }
        var total = 0.0, count = 0, failures = 0
        for g in groups.indices {
            groups[g].error = nil
            let group = groups[g]
            guard !selected(group).isEmpty else { continue }
            guard let task = store.task(group.id), let issueId = Int(task.ref),
                  let project = store.project(group.projectId), let client = RedmineClient(project: project) else {
                groups[g].error = "Set the project's base URL and API key in Settings → Projects."
                failures += 1
                continue
            }
            for r in groups[g].rows.indices where groups[g].rows[r].include && !groups[g].rows[r].done {
                let row = groups[g].rows[r]
                guard let hours = parse(row.hours), hours > 0 else { continue }
                do {
                    try await client.logTime(issueId: issueId, hours: hours, day: row.day,
                                             activityId: group.activityId, comments: group.comment)
                    // Mark right away: if a later entry fails, this one isn't logged twice.
                    store.markLogged(task: group.id, entries: [row.id])
                    groups[g].rows[r].done = true
                    total += hours
                    count += 1
                } catch {
                    groups[g].error = "Failed on \(row.day.formatted(date: .abbreviated, time: .omitted)) \(row.span): \(error.localizedDescription)"
                    failures += 1
                    break   // next task; the rest of this one stays selected
                }
            }
        }
        failed = failures > 0
        message = String(format: "%d %@ pushed, %.2f h.", count, count == 1 ? "entry" : "entries", total)
            + (failures > 0 ? " \(failures) task\(failures == 1 ? "" : "s") failed: see the red text above." : "")
    }
}
