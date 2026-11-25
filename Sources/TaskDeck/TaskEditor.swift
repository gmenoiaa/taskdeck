import SwiftUI

struct TaskEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let original: TaskItem
    @State private var task: TaskItem
    @State private var ticket: String
    /// On: the task follows a ticket that already exists. Off: the ticket does not exist yet, so
    /// the task gets a description of its own and can create the ticket later.
    @State private var existingTicket: Bool
    @State private var fetching = false
    /// The last title filled in from the ticket. A title that still equals it was not typed by the
    /// user, so another ticket number may replace it.
    @State private var fetchedTitle: String?
    @State private var fetchError: String?
    @State private var manualMinutes = ""
    @State private var confirmDelete = false
    @State private var description: String
    @State private var sendingToTracker = false

    /// `ticket` is a link pasted on the board for a new task: it goes in the ticket field as if
    /// typed, so the reference, the link and the title are worked out from it.
    init(task: TaskItem, ticket: String? = nil) {
        original = task
        _task = State(initialValue: task)
        _ticket = State(initialValue: ticket ?? task.ref)
        // A blank new task starts on "existing", the common case; a task saved without a ticket
        // was a new one.
        _existingTicket = State(initialValue: !task.ref.isEmpty || (task.title.isEmpty && task.draft == nil))
        _description = State(initialValue: task.draft ?? "")
    }

    /// The task lives in the app, with a description of its own that can later become a ticket in
    /// the space's tracker.
    private var isLocal: Bool { !existingTicket }
    /// The ticket typed, or none while the switch says there is no ticket yet. What was typed is
    /// kept, so switching back does not lose it.
    private var ticketInput: String { existingTicket ? ticket.trimmingCharacters(in: .whitespaces) : "" }
    private var tracked: Bool { project.map { $0.kind != .other } ?? false }
    /// Only for a task already saved without a ticket: creating one is a step of its own, taken
    /// when the user wants it, never on the way out of this sheet.
    private var canSend: Bool { !isNew && original.ref.isEmpty && isLocal && tracked }

    private var isNew: Bool { store.task(task.id) == nil }
    private var project: Project? { store.project(task.projectId) }
    /// A task with a ticket has the details sheet, where its notes and time already live.
    /// Showing them here too made two places to edit the same thing.
    private var hasDetails: Bool {
        !isNew && TicketFetcher.canFetch(project: store.project(original.projectId), task: original)
    }

    private var linkChanged: Bool {
        ticketInput != original.ref || task.projectId != original.projectId
    }

    private var resolved: (ref: String, url: String) {
        guard linkChanged else { return (original.ref, original.url) }
        return LinkResolver.resolve(ticketInput, kind: project?.kind ?? .other, base: project?.baseURL ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Space", selection: $task.projectId) {
                        Text("No space").tag(UUID?.none)
                        ForEach(store.projects) { p in
                            Text("\(p.name) · \(p.kind.label)").tag(UUID?.some(p.id))
                        }
                    }
                    Toggle("Existing ticket", isOn: $existingTicket)
                        .help("Off when the ticket does not exist yet: write its description here and create it in the tracker later.")
                    if existingTicket {
                        TextField("Ticket", text: $ticket, prompt: Text((project?.kind ?? .other).ticketHint))
                    }
                    if !resolved.url.isEmpty {
                        LabeledContent("Link") {
                            Text(resolved.url).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    } else if project != nil, project?.baseURL.isEmpty == true, !ticketInput.isEmpty,
                              !ticketInput.lowercased().hasPrefix("http") {
                        Text("Set the space's base URL (or paste the full link) to generate the link.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Title", text: $task.title, prompt: Text(tracked && !isLocal ? "Fetched from the ticket if left empty" : "Task name"))
                        if let project, project.kind != .other, !isLocal {
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
                    // Finished goals are left out, except the one the task is already in.
                    let goals = store.goals.filter { $0.status != .done || $0.id == task.goalId }
                    if !goals.isEmpty {
                        Picker("Goal", selection: $task.goalId) {
                            Text("No goal").tag(UUID?.none)
                            ForEach(goals) { goal in
                                Text(goal.displayName).tag(UUID?.some(goal.id))
                            }
                        }
                    }
                    // No column: a card is placed and moved on the board. No notes on a new task
                    // either: creating one is a ticket and a name, the rest comes after.
                    if !isNew && !hasDetails {
                        TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(2...5)
                    }
                }

                if isLocal {
                    Section {
                        DescriptionField(text: $description)
                    }
                    Section("Draft with Claude") {
                        DraftWithClaude(title: $task.title, description: $description, tracker: project?.kind)
                    }
                }

                if !isNew && !hasDetails {
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
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                if canSend, let project {
                    Button("Create in \(project.kind.label)…") {
                        save()
                        sendingToTracker = true
                    }
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Saves the task, then creates its ticket in \(project.kind.label).")
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    Task {
                        // A ticket alone is enough: its title is fetched on the way out. If that
                        // fails the sheet stays open with the reason, and Create then saves as is.
                        if task.title.trimmingCharacters(in: .whitespaces).isEmpty, fetchError == nil,
                           let project, project.kind != .other, !resolved.ref.isEmpty {
                            await fetchTitle()
                            if fetchError != nil { return }
                        }
                        saveAndClose()
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fetching)
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty
                              && ticketInput.isEmpty)
            }
            .padding(14)
        }
        .frame(width: isLocal ? 560 : 500)
        // The title follows the ticket as it is typed, after a short pause so a number half typed
        // is not looked up.
        .task(id: ticketInput) {
            guard linkChanged, let project, project.kind != .other, !resolved.ref.isEmpty,
                  project.kind != .redmine || Int(resolved.ref) != nil else { return }
            let current = task.title.trimmingCharacters(in: .whitespaces)
            guard current.isEmpty || current == fetchedTitle else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await fetchTitle(quiet: true)
        }
        .confirmationDialog("Delete “\(original.title.isEmpty ? original.displayRef : original.title)”?", isPresented: $confirmDelete) {
            Button("Delete task", role: .destructive) {
                store.delete(task: task.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tracked time is deleted too. This cannot be undone.")
        }
        // The goal picker adds a row, once there is a goal to pick.
        .frame(minHeight: (isLocal ? (isNew ? 600 : 720) : (isNew || hasDetails ? 230 : 440)) + (store.goals.isEmpty ? 0 : 40))
        // The task was saved before this opened; whatever happens there, this sheet's copy is old.
        .sheet(isPresented: $sendingToTracker, onDismiss: { dismiss() }) {
            CreateTicketView(taskId: task.id).environment(store)
        }
    }

    private func addManual() {
        guard let minutes = Double(manualMinutes.replacingOccurrences(of: ",", with: ".")), minutes > 0 else { return }
        let end = Date()
        task.entries.append(TimeEntry(start: end.addingTimeInterval(-minutes * 60), end: end))
        manualMinutes = ""
    }

    private func saveAndClose() {
        save()
        dismiss()
    }

    private func save() {
        let r = resolved
        task.ref = r.ref
        task.url = r.url
        task.title = task.title.trimmingCharacters(in: .whitespaces)
        // With a ticket, the tracker's description is the one that counts.
        task.draft = r.ref.isEmpty && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? description : nil
        // The timer may have been started or stopped while the editor was open: start from the live
        // entries and apply only what was changed here (removed, added, start/end edited).
        if let live = store.task(task.id) {
            // What this sheet does not show is not its to save: the card may have changed column,
            // or its notes been edited in the details, while the sheet was open.
            task.status = live.status
            task.order = live.order
            task.dueDate = live.dueDate
            if hasDetails { task.notes = live.notes }
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
        task.remoteType = linkChanged ? nil : (store.task(task.id)?.remoteType ?? task.remoteType)
        task.estimateGap = linkChanged ? nil : (store.task(task.id)?.estimateGap ?? task.estimateGap)
        task.remoteDue = linkChanged ? nil : (store.task(task.id)?.remoteDue ?? task.remoteDue)
        task.remoteAssignee = linkChanged ? nil : (store.task(task.id)?.remoteAssignee ?? task.remoteAssignee)
        task.explanation = linkChanged ? nil : (store.task(task.id)?.explanation ?? task.explanation)
        let needsStatus = task.remoteStatus == nil
        store.upsert(task)
        if needsStatus { Task { await store.refreshRemoteStatuses() } }
    }

    /// `quiet`: started by typing. Then the title is only replaced if the user has not typed one
    /// meanwhile, and nothing is applied once the ticket field has changed again.
    private func fetchTitle(quiet: Bool = false) async {
        guard let project else { return }
        let r = resolved
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            let subject = try await TicketFetcher.fetch(project: project, ref: r.ref, url: r.url).subject
            if quiet {
                guard resolved.ref == r.ref else { return }
                let current = task.title.trimmingCharacters(in: .whitespaces)
                guard current.isEmpty || current == fetchedTitle else { return }
            }
            task.title = subject
            fetchedTitle = subject
        } catch {
            guard !quiet || resolved.ref == r.ref else { return }
            fetchError = error.localizedDescription
        }
    }
}
