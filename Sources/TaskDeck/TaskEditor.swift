import SwiftUI

struct TaskEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let original: TaskItem
    @State private var task: TaskItem
    @State private var ticket: String
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var manualMinutes = ""

    init(task: TaskItem) {
        original = task
        _task = State(initialValue: task)
        _ticket = State(initialValue: task.ref)
    }

    private var isNew: Bool { store.task(task.id) == nil }
    private var project: Project? { store.project(task.projectId) }

    private var linkChanged: Bool {
        ticket.trimmingCharacters(in: .whitespaces) != original.ref || task.projectId != original.projectId
    }

    private var resolved: (ref: String, url: String) {
        guard linkChanged else { return (original.ref, original.url) }
        return LinkResolver.resolve(ticket, kind: project?.kind ?? .other, base: project?.baseURL ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Project", selection: $task.projectId) {
                        Text("No project").tag(UUID?.none)
                        ForEach(store.projects) { p in
                            Text("\(p.name) · \(p.kind.label)").tag(UUID?.some(p.id))
                        }
                    }
                    TextField("Ticket", text: $ticket, prompt: Text((project?.kind ?? .other).ticketHint))
                    if !resolved.url.isEmpty {
                        LabeledContent("Link") {
                            Text(resolved.url).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    } else if project != nil, project?.baseURL.isEmpty == true, !ticket.isEmpty,
                              !ticket.lowercased().hasPrefix("http") {
                        Text("Set the project's base URL (or paste the full link) to generate the link.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Title", text: $task.title, prompt: Text("Task name"))
                        if let project, project.kind != .other {
                            Button {
                                Task { await fetchTitle() }
                            } label: {
                                if fetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down.circle") }
                            }
                            .buttonStyle(.borderless)
                            .disabled(fetching || resolved.ref.isEmpty)
                            .help("Fetch title from \(project.kind.label)")
                        }
                    }
                    if let fetchError {
                        Text(fetchError).font(.caption).foregroundStyle(.red)
                    }
                    Picker("Column", selection: $task.status) {
                        ForEach(store.columns) { Text($0.displayName).tag($0.id) }
                    }
                    TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(2...5)
                }

                if !isNew {
                    Section("Time — total \(Fmt.short(task.total(now: Date())))") {
                        ForEach(task.entries.sorted { $0.start > $1.start }) { entry in
                            TimeEntryRow(entry: Binding(get: { entry }, set: { edited in
                                if let j = task.entries.firstIndex(where: { $0.id == edited.id }) { task.entries[j] = edited }
                            }), now: Date(), onDelete: { task.entries.removeAll { $0.id == entry.id } })
                        }
                        HStack {
                            TextField("Add time manually", text: $manualMinutes, prompt: Text("minutes"))
                            Button("Add") { addManual() }
                                .disabled((Double(manualMinutes.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        store.delete(task: task.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { saveAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty
                              && ticket.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 500)
        .frame(minHeight: isNew ? 330 : 480)
    }

    private func addManual() {
        guard let minutes = Double(manualMinutes.replacingOccurrences(of: ",", with: ".")), minutes > 0 else { return }
        let end = Date()
        task.entries.append(TimeEntry(start: end.addingTimeInterval(-minutes * 60), end: end))
        manualMinutes = ""
    }

    private func saveAndClose() {
        let r = resolved
        task.ref = r.ref
        task.url = r.url
        task.title = task.title.trimmingCharacters(in: .whitespaces)
        // The timer may have been started or stopped while the editor was open: start from the live
        // entries and apply only what was changed here (removed, added, start/end edited).
        if let live = store.task(task.id) {
            let before = Dictionary(uniqueKeysWithValues: original.entries.map { ($0.id, $0) })
            let draft = Dictionary(uniqueKeysWithValues: task.entries.map { ($0.id, $0) })
            let kept = live.entries.compactMap { entry -> TimeEntry? in
                guard let old = before[entry.id] else { return entry }
                guard let mine = draft[entry.id] else { return nil }
                var merged = entry
                if mine.start != old.start { merged.start = min(mine.start, entry.end ?? Date()) }
                if entry.end != nil, let end = mine.end, mine.end != old.end { merged.end = max(end, merged.start) }
                return merged
            }
            task.entries = kept + task.entries.filter { before[$0.id] == nil }
        }
        // The tracker status may have been refreshed while the editor was open; a new ticket has none yet.
        task.remoteStatus = linkChanged ? nil : (store.task(task.id)?.remoteStatus ?? task.remoteStatus)
        task.remoteAssignee = linkChanged ? nil : (store.task(task.id)?.remoteAssignee ?? task.remoteAssignee)
        task.explanation = linkChanged ? nil : (store.task(task.id)?.explanation ?? task.explanation)
        let needsStatus = task.remoteStatus == nil
        store.upsert(task)
        if needsStatus { Task { await store.refreshRemoteStatuses() } }
        dismiss()
    }

    private func fetchTitle() async {
        guard let project else { return }
        let r = resolved
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            task.title = try await TicketFetcher.fetch(project: project, ref: r.ref, url: r.url).subject
        } catch {
            fetchError = error.localizedDescription
        }
    }
}
