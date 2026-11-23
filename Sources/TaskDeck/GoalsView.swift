import SwiftUI
import AppKit

/// Goals: things the user looks after that span several tasks, in any space, each with the notes
/// and links that go with it. The list on the left, the chosen goal on the right.
struct GoalsView: View {
    @Environment(AppStore.self) private var store
    let spaceId: UUID?
    /// The chosen goal's id, kept by the window so "New task" can put the task in it.
    @Binding var selection: String
    /// Opens a task's ticket view, or its editor when it has no ticket.
    let onOpen: (TaskItem) -> Void
    let onNewTask: (UUID) -> Void
    let onShowOnBoard: (UUID) -> Void

    @State private var importing = false

    private var goals: [Goal] { store.goals(in: spaceId) }
    private var selected: Goal? { goals.first { $0.id.uuidString == selection } ?? goals.first }

    var body: some View {
        let goals = goals
        HStack(spacing: 0) {
            list(goals).frame(width: 250)
            Divider()
            if let goal = selected {
                GoalDetail(goalId: goal.id, onOpen: onOpen, onNewTask: onNewTask, onShowOnBoard: onShowOnBoard)
                    // A fresh view per goal, so a half-typed note does not follow to the next one.
                    .id(goal.id)
            } else {
                ContentUnavailableView {
                    Label("No goals yet", systemImage: "flag")
                } description: {
                    Text("A goal groups the tasks, notes and links of something you are looking after.")
                } actions: {
                    Button("New goal", action: add)
                    Button("From a tracker epic…") { importing = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The first goal is shown when none is chosen; saying so keeps "New task" in step with it.
        .onAppear { if let goal = selected, selection != goal.id.uuidString { selection = goal.id.uuidString } }
        .onChange(of: selected?.id) { _, new in selection = new?.uuidString ?? "" }
        .sheet(isPresented: $importing) {
            GoalImportView(goalId: nil) { selection = $0.uuidString }.environment(store)
        }
    }

    private func add() {
        selection = store.addGoal().id.uuidString
    }

    private func list(_ goals: [Goal]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(goals) { goal in
                        row(goal, chosen: goal.id == selected?.id)
                    }
                }
                .padding(8)
            }
            Divider()
            HStack {
                Button(action: add) {
                    Label("New goal", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New goal from a tracker's epic, parent issue or milestone")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func row(_ goal: Goal, chosen: Bool) -> some View {
        let tasks = store.tasks(of: goal.id)
        let done = tasks.filter(store.isDone).count
        let time = tasks.reduce(0) { $0 + $1.total(now: store.now) }
        var facts = [tasks.isEmpty ? "No tasks" : "\(done)/\(tasks.count) done"]
        if time >= 60 { facts.append(Fmt.short(time)) }
        if goal.status != .active { facts.append(goal.status.label) }
        return Button { selection = goal.id.uuidString } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.displayName).lineLimit(1)
                Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(chosen ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .opacity(goal.status == .done ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }
}

private struct GoalDetail: View {
    @Environment(AppStore.self) private var store
    let goalId: UUID
    let onOpen: (TaskItem) -> Void
    let onNewTask: (UUID) -> Void
    let onShowOnBoard: (UUID) -> Void

    @State private var draft = ""
    @State private var picking = false
    @State private var editingItem: UUID?
    @State private var confirmDelete = false
    @State private var dropping = false
    @State private var dropError: String?
    @State private var updating = false
    @State private var standing = ""
    @State private var asking = false
    @State private var askError: String?
    @FocusState private var naming: Bool

    var body: some View {
        if let goal = store.goal(goalId) {
            let tasks = store.tasks(of: goalId)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(goal)
                    if !tasks.isEmpty { standingBox(goal) }
                    taskSection(tasks)
                    materials(goal, space: space(of: tasks))
                }
                .padding(20)
                // Same reading width as the overview.
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .softScrollEdges()
            // The whole pane takes drops: the notes section alone was too small a target, and
            // a drop just beside it did nothing.
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: Radius.column, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.column, style: .continuous))
                        .overlay(Label("Add to “\(goal.displayName)”", systemImage: "plus.circle.fill")
                            .font(.headline).foregroundStyle(Theme.accent))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: GoalDrop.types, isTargeted: $dropping) { providers in
                Task {
                    let (items, failure) = await GoalDrop.items(from: providers)
                    if !items.isEmpty { store.updateGoal(goalId) { $0.items.append(contentsOf: items) } }
                    dropError = failure?.localizedDescription
                }
                return true
            }
            // A goal just made has no name: the cursor goes there.
            .onAppear { if goal.name.isEmpty { naming = true } }
            .sheet(isPresented: $updating) {
                GoalImportView(goalId: goalId).environment(store)
            }
            .confirmationDialog("Delete “\(goal.displayName)”?", isPresented: $confirmDelete) {
                Button("Delete goal", role: .destructive) { store.delete(goal: goalId) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its notes and links are deleted. Its tasks stay on the board. This cannot be undone.")
            }
        }
    }

    private func bind<Value>(_ goal: Goal, _ key: WritableKeyPath<Goal, Value>) -> Binding<Value> {
        Binding(get: { (store.goal(goalId) ?? goal)[keyPath: key] },
                set: { value in store.updateGoal(goalId) { $0[keyPath: key] = value } })
    }

    /// The space whose browser opens the goal's links: only when all its tasks are in one.
    private func space(of tasks: [TaskItem]) -> Project? {
        let spaces = Set(tasks.compactMap(\.projectId))
        return spaces.count == 1 ? store.project(spaces.first) : nil
    }

    // MARK: Header

    private func header(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Goal name", text: bind(goal, \.name))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($naming)
                Picker("Status", selection: bind(goal, \.status)) {
                    ForEach(GoalStatus.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize().tint(nil)
                Menu {
                    if let source = goal.source {
                        Button("Update from \(store.project(source.projectId)?.kind.label ?? "Tracker")…") { updating = true }
                    } else {
                        Button("Add Tasks from a Tracker Epic…") { updating = true }
                    }
                    Button("Show on Board") { onShowOnBoard(goalId) }
                        .disabled(store.tasks(of: goalId).allSatisfy(\.archived))
                    Divider()
                    Button("Delete Goal…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            TextField("What is this goal about?", text: bind(goal, \.summary), axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1...6)
            HStack(spacing: 6) {
                if let due = goal.due {
                    DatePicker("Due", selection: Binding(get: { due }, set: { day in store.updateGoal(goalId) { $0.due = day } }),
                               displayedComponents: .date)
                        .fixedSize()
                    Button { store.updateGoal(goalId) { $0.due = nil } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Remove the due date")
                    if goal.status != .done, due < Calendar.current.startOfDay(for: store.now) {
                        Text("Overdue").font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Button("Set a due date") { store.updateGoal(goalId) { $0.due = Date() } }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    // MARK: Where it stands

    /// Claude's account of the goal, streamed in as it is written; the last one is kept with the goal.
    private func standingBox(_ goal: Goal) -> some View {
        let text = asking ? standing : (goal.standing ?? "")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Where it stands").font(.headline)
                if let at = goal.standingAt, !asking {
                    Text(at, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if asking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(goal.standing == nil ? "Ask Claude" : "Refresh") { Task { await ask(goal) } }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            .foregroundStyle(Theme.accent)
            if let askError {
                Label(askError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if !text.isEmpty {
                MarkdownView(text: text)
            } else if asking {
                Text("Claude is reading the goal's tickets…").foregroundStyle(.secondary)
            } else {
                Text("A short report on the goal from its tickets' status, time and comments.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Sent to Claude: the goal's name and description, its tickets as last read, and the titles of its links. Notes are not sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
    }

    private func ask(_ goal: Goal) async {
        Claude.adoptLegacyKey(from: store.projects)
        guard let key = Claude.apiKey() else {
            askError = "Set your Claude API key in Settings → AI (⌘,)."
            return
        }
        asking = true
        askError = nil
        standing = ""
        defer { asking = false }
        do {
            let system = Claude.system(Claude.goalSystem, custom: store.aiInstructions)
            let user = Claude.goalText(goal, store: store)
            for try await chunk in Claude.stream(apiKey: key, model: store.claudeModel, system: system, user: user) {
                standing += chunk
            }
            store.setStanding(goalId, standing)
        } catch {
            // The earlier report stays when a new one fails.
            askError = "Could not get a report: \(error.localizedDescription)"
        }
    }

    // MARK: Tasks

    private func taskSection(_ tasks: [TaskItem]) -> some View {
        let done = tasks.filter(store.isDone).count
        let time = tasks.reduce(0) { $0 + $1.total(now: store.now) }
        let onBoard = tasks.filter { !$0.archived }
        let archived = tasks.filter(\.archived)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Tasks").font(.headline)
                if !tasks.isEmpty {
                    Text("\(done) of \(tasks.count) done · \(Fmt.short(time))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("New Task") { onNewTask(goalId) }
                Button("Add Existing…") { picking = true }
                    .popover(isPresented: $picking, arrowEdge: .bottom) {
                        GoalTaskPicker(goalId: goalId).environment(store)
                    }
            }
            .tint(nil)
            if tasks.isEmpty {
                Text("No tasks yet. Add tasks that are already on the board, or create one here.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(done), total: Double(tasks.count)).tint(Theme.accent)
                ForEach(store.columns) { column in
                    let inColumn = onBoard.filter { $0.status == column.id }
                    if !inColumn.isEmpty { group(column.displayName, inColumn) }
                }
                if !archived.isEmpty { group("Archived", archived) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group(_ title: String, _ tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 2)
            ForEach(tasks) { task in
                taskRow(task)
                if task.id != tasks.last?.id { Divider() }
            }
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        let space = store.project(task.projectId)
        return HStack(spacing: 8) {
            Circle().fill(space?.color ?? .gray).frame(width: 7, height: 7)
                .help(space?.name ?? "No space")
            if !task.displayRef.isEmpty {
                if let url = URL(string: task.url), !task.url.isEmpty {
                    TicketLink(text: task.displayRef, url: url, space: space)
                } else {
                    Text(task.displayRef).foregroundStyle(.secondary)
                }
            }
            Button { onOpen(task) } label: {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(task.isRunning ? Fmt.clock(task.currentStretch(now: store.now)) : Fmt.short(task.total(now: store.now)))
                .monospacedDigit()
                .foregroundStyle(task.isRunning ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            if !task.archived {
                Button { store.toggleTimer(task.id) } label: {
                    Image(systemName: task.isRunning ? "stop.fill" : "play.fill").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(task.isRunning ? "Stop the timer" : "Start the timer")
            }
        }
        .padding(.vertical, 5)
        .opacity(task.archived ? 0.6 : 1)
        .contextMenu {
            Button("Remove from Goal") { store.setGoal(task.id, nil) }
        }
    }

    // MARK: Notes and links

    private func materials(_ goal: Goal, space: Project?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes and links").font(.headline)
            HStack(alignment: .bottom, spacing: 8) {
                // Return adds; Option-Return makes a new line.
                TextField("Write a note, or paste a link", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit(addDraft)
                Button("Add", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Links, files and messages from Mail can also be dropped here. Notes are saved only on this Mac and are not sent to the AI.")
                .font(.caption).foregroundStyle(.secondary)
            if let dropError {
                Label(dropError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(goal.items.sorted { $0.createdAt > $1.createdAt }) { item in
                itemRow(item, space: space)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

    }

    private func addDraft() {
        guard let item = GoalItem.from(draft) else { return }
        store.updateGoal(goalId) { $0.items.append(item) }
        draft = ""
    }

    private func bind(_ item: GoalItem, _ key: WritableKeyPath<GoalItem, String>) -> Binding<String> {
        Binding(get: { (store.goal(goalId)?.items.first { $0.id == item.id } ?? item)[keyPath: key] },
                set: { value in
                    store.updateGoal(goalId) { goal in
                        if let i = goal.items.firstIndex(where: { $0.id == item.id }) { goal.items[i][keyPath: key] = value }
                    }
                })
    }

    private func itemRow(_ item: GoalItem, space: Project?) -> some View {
        let isNote = item.kind == .note
        let editing = editingItem == item.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.icon).foregroundStyle(.secondary).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextField(isNote ? "Note" : "Name", text: bind(item, isNote ? \.text : \.title), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...10)
                        .onSubmit { editingItem = nil }
                } else if isNote {
                    Text(item.text).textSelection(.enabled)
                } else {
                    Button { open(item, space: space) } label: {
                        Text(item.displayTitle).foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(item.kind == .mail ? "Open in Mail" : item.url)
                    if item.kind == .mail, !item.text.isEmpty {
                        Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(item.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if editing {
                Button("Done") { editingItem = nil }.tint(nil)
            }
        }
        .padding(10)
        // Notes in the same pale yellow as a task's private notes; pointers stay neutral.
        .background(isNote ? Color.yellow.opacity(0.10) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contextMenu {
            Button(isNote ? "Edit" : "Rename") { editingItem = item.id }
            if !isNote {
                Button("Copy Link") { copy(item.url) }
            } else {
                Button("Copy") { copy(item.text) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.updateGoal(goalId) { goal in goal.items.removeAll { $0.id == item.id } }
            }
        }
    }

    private func open(_ item: GoalItem, space: Project?) {
        guard let url = URL(string: item.url) else { return }
        Browser.open(url, space: space)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Tasks on the board that are not in this goal yet. A click adds one and the list stays open
/// for the next.
private struct GoalTaskPicker: View {
    @Environment(AppStore.self) private var store
    let goalId: UUID
    @State private var search = ""

    private var candidates: [TaskItem] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return store.tasks.filter { task in
            guard !task.archived, task.goalId != goalId else { return false }
            let text = "\(task.title)\n\(task.ref)\n\(store.project(task.projectId)?.name ?? "")"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let candidates = candidates
        VStack(spacing: 0) {
            TextField("Search tasks", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            if candidates.isEmpty {
                Text(search.isEmpty ? "Every task on the board is already in this goal." : "No task matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { task in
                            Button { store.setGoal(task.id, goalId) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces)).lineLimit(1)
                                    // Adding it here takes it out of the goal it is in.
                                    if let other = store.goal(task.goalId) {
                                        Text("Moves from “\(other.displayName)”").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 380, height: 340)
    }
}
