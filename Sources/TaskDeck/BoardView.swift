import SwiftUI
import AppKit

struct BoardView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: UUID?
    /// The space last shown, so the board opens on it again.
    @AppStorage("boardSpace") private var savedSpace = ""
    @State private var editing: TaskItem?
    @State private var logging: TaskItem?
    @State private var details: TaskItem?
    @State private var showImport = false
    @State private var showArchive = false
    @State private var showToday = false
    @State private var showPending = false
    /// The window's tab: "overview" (the first page) or "board". Remembered between launches.
    @AppStorage("mainTab") private var tab = "overview"
    @State private var search = ""
    @FocusState private var searching: Bool

    /// Every word typed has to appear somewhere in the task, in any order, ignoring case and accents.
    private func matches(_ task: TaskItem) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = [task.title, task.displayRef, task.ref, task.notes, task.remoteStatus ?? "",
                    task.remoteAssignee ?? "", store.project(task.projectId)?.name ?? ""]
            .joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

private func newTask() {
        editing = TaskItem(projectId: filter ?? store.projects.first?.id, status: store.defaultColumnId)
    }

    /// Tracked time that is not on Redmine yet, in minutes worth showing.
    private var pendingSeconds: TimeInterval {
        let pending = store.pendingLogTasks.reduce(0) { $0 + $1.unloggedSeconds }
        return pending >= 60 ? pending : 0
    }

    /// "Time to push": a pale orange button of its own before the gray group, there only while there is
    /// time to log. The toolbar item itself always exists; its content comes and goes.
    @ToolbarContentBuilder
    private var pendingItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                if pendingSeconds > 0 {
                    Button { showPending = true } label: {
                        // Drawn by hand, like "New task": a tinted button style in the toolbar comes out oversized.
                        pendingLabel
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .glassEffect(.regular.tint(Theme.pending).interactive(), in: .capsule)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Time to push: tracked time that is not on Redmine yet (⌘L)")
                }
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                if pendingSeconds > 0 {
                    Button { showPending = true } label: { pendingLabel }
                        .help("Time to push: tracked time that is not on Redmine yet (⌘L)")
                        .buttonStyle(.borderedProminent).tint(Theme.pending)
                }
            }
        }
    }

    private var pendingLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.circle").font(.system(size: 14, weight: .semibold))
            Text(Fmt.short(pendingSeconds)).monospacedDigit().fontWeight(.semibold)
        }
        // Orange on the pale fill, exactly like the not-logged chip on a card.
        .foregroundStyle(Color.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time to push: \(Fmt.short(pendingSeconds))")
    }

    /// "New task": a red circle of its own, apart from the gray toolbar group.
    @ToolbarContentBuilder
    private var newTaskItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(action: newTask) {
                    // Drawn by hand: a tinted button style in the toolbar comes out oversized and not round.
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New task")
                .help("New task (⌘N)")
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newTask) { Label("New task", systemImage: "plus") }
                    .help("New task (⌘N)")
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
    }

        var body: some View {
        @Bindable var store = store
        Group {
            if tab == "overview" {
                OverviewView(spaceId: filter, onDetails: { details = $0 })
            } else {
                GeometryReader { geo in
                    // Columns share the window width; with many columns they keep a readable width and scroll sideways.
                    let count = CGFloat(max(store.columns.count, 1))
                    let width = max(250, (geo.size.width - 24 - 12 * (count - 1)) / count)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(store.columns) { column in
                                ColumnView(
                                    column: column,
                                    tasks: store.tasks(in: column.id, project: filter).filter(matches),
                                    onEdit: { editing = $0 },
                                    onLog: { logging = $0 },
                                    onDetails: { details = $0 },
                                    onShowArchive: { showArchive = true }
                                )
                                .frame(width: width)
                            }
                        }
                        .padding(12)
                        .frame(height: geo.size.height)
                    }
                }
            }
        }
        // The menu bar carries the shortcuts, so each shows next to its command there.
        .focusedSceneValue(\.board, BoardActions(
            newTask: newTask,
            fetchAssigned: { showImport = true },
            logPending: pendingSeconds > 0 ? { showPending = true } : nil,
            showArchive: { showArchive = true },
            search: { searching = true },
            show: { tab = $0 },
            space: filter,
            showSpace: { filter = $0 }))
        .onAppear {
            // A space deleted since last time falls back to all spaces.
            if let id = UUID(uuidString: savedSpace), store.project(id) != nil { filter = id }
        }
        .onChange(of: filter) { _, new in savedSpace = new?.uuidString ?? "" }
        // The window keeps its name for Mission Control and the Window menu; the toolbar has no room for it.
        .modifier(NoToolbarTitle())
        .searchable(text: $search, prompt: "Search tasks")
        .modifier(SearchFocus(focused: $searching))
        // The results are cards, so typing a search from the overview moves to the board.
        .onChange(of: search) { _, new in
            if !new.trimmingCharacters(in: .whitespaces).isEmpty, tab == "overview" { tab = "board" }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Space", selection: $filter) {
                    Text("All spaces").tag(UUID?.none)
                    ForEach(store.projects) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
                .fixedSize()
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Overview").tag("overview")
                    Text("Board").tag("board")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Overview (⌘1) or board (⌘2) of \(store.project(filter)?.name ?? "all spaces")")
            }
            ToolbarItem(placement: .navigation) {
                // With "All spaces", a click shows today's time per space.
                Button { if filter == nil { showToday.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("Today: \(Fmt.short(store.trackedToday(now: store.now, project: filter)))")
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
                .help(filter == nil ? "Show today's time per space" : "Time tracked today in this space")
                .popover(isPresented: $showToday, arrowEdge: .bottom) {
                    TodayBreakdown().environment(store)
                }
            }
            pendingItem
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await store.refreshEverything() } } label: {
                    // The spinner takes the icon's place while refreshing, so the button keeps its size.
                    ZStack {
                        Image(systemName: "arrow.clockwise").opacity(store.refreshingStatuses ? 0 : 1)
                        if store.refreshingStatuses { ProgressView().controlSize(.small) }
                    }
                    .accessibilityLabel(store.refreshingStatuses ? "Refreshing statuses" : "Refresh statuses")
                }
                .disabled(store.refreshingStatuses)
                .help("Refresh ticket statuses and assignees from the trackers, and agent sessions and pull requests (⌘R)")
                Button { showImport = true } label: {
                    Label("Assigned to me", systemImage: "tray.and.arrow.down")
                }
                .help("Fetch tickets assigned to me (⌘I)")
            }
            newTaskItem
        }
        .onChange(of: store.singleTimer) { store.save() }
        .sheet(item: $editing) { task in
            TaskEditor(task: task).environment(store)
        }
        .sheet(item: $logging) { task in
            LogTimeView(taskId: task.id).environment(store)
        }
        .sheet(item: $details) { task in
            IssueDetailView(taskId: task.id).environment(store)
        }
        .sheet(isPresented: $showArchive) {
            ArchiveView().environment(store)
        }
        .sheet(isPresented: $showPending) {
            PendingTimeView().environment(store)
        }
        .sheet(isPresented: $showImport) {
            ImportView().environment(store)
        }
    }
}

/// Lets ⌘F put the cursor in the search field. Before macOS 15 there is no way to do it, so the
/// shortcut does nothing there and the field is reached by clicking.
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

/// Hides the window's name in the toolbar. Before macOS 15 it stays.
private struct NoToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// What the main window offers to the menu bar. Nil while another window is in front.
struct BoardActions {
    var newTask: () -> Void
    var fetchAssigned: () -> Void
    /// Nil when there is no time waiting to be logged.
    var logPending: (() -> Void)?
    var showArchive: () -> Void
    var search: () -> Void
    /// "overview" or "board".
    var show: (String) -> Void
    /// The space shown, nil for all spaces.
    var space: UUID?
    var showSpace: (UUID?) -> Void
}

private struct BoardActionsKey: FocusedValueKey {
    typealias Value = BoardActions
}

extension FocusedValues {
    var board: BoardActions? {
        get { self[BoardActionsKey.self] }
        set { self[BoardActionsKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    let store: AppStore
    @FocusedValue(\.board) private var board

    var body: some Commands {
        // The app has one window, so "New" means a task.
        CommandGroup(replacing: .newItem) {
            Button("New Task") { board?.newTask() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(board == nil)
        }
        CommandMenu("Tasks") {
            Button("Fetch Tickets Assigned to Me…") { board?.fetchAssigned() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(board == nil)
            Button("Log Pending Time…") { board?.logPending?() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(board?.logPending == nil)
            Button("Refresh") { Task { await store.refreshEverything() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Stop All Timers") { store.stopAll() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Show Archive") { board?.showArchive() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(board == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Overview") { board?.show("overview") }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(board == nil)
            Button("Board") { board?.show("board") }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(board == nil)
            Divider()
            Button("Search Tasks") { board?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(board == nil)
            Divider()
            // Toggles, so the space being shown carries a checkmark.
            Toggle("All Spaces", isOn: Binding(get: { board != nil && board?.space == nil },
                                               set: { _ in board?.showSpace(nil) }))
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(board == nil)
            ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, space in
                let toggle = Toggle(space.name, isOn: Binding(get: { board?.space == space.id },
                                                              set: { _ in board?.showSpace(space.id) }))
                    .disabled(board == nil)
                // Only the first nine get a number key.
                if index < 9 {
                    toggle.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                } else {
                    toggle
                }
            }
            Divider()
        }
    }
}

struct ColumnView: View {
    @Environment(AppStore.self) private var store
    let column: BoardColumn
    let tasks: [TaskItem]
    let onEdit: (TaskItem) -> Void
    let onLog: (TaskItem) -> Void
    let onDetails: (TaskItem) -> Void
    let onShowArchive: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(column.displayName).font(.headline).lineLimit(1)
                Text("\(tasks.count)")
                    .font(.caption).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                if column.role == .done && !tasks.isEmpty {
                    Button("Archive") { store.archive(column: column.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Removes done tasks from the board (time history is kept)")
                }
                if column.role == .done && store.archivedCount > 0 {
                    Button(action: onShowArchive) {
                        Label("\(store.archivedCount)", systemImage: "archivebox")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Show archived tasks")
                }
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(task: task, onEdit: { onEdit(task) }, onLog: { onLog(task) }, onDetails: { onDetails(task) })
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Radius.column, style: .continuous)
                .fill(Color.primary.opacity(targeted ? 0.10 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.column, style: .continuous)
                .strokeBorder(Theme.accent.opacity(targeted ? 0.8 : 0), lineWidth: 2)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            store.move(id, to: column.id)
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct TaskCard: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    let onEdit: () -> Void
    let onLog: () -> Void
    let onDetails: () -> Void
    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        let project = store.project(task.projectId)
        let running = task.isRunning
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The project is shown by the colour strip on the card's left edge.
                if !task.displayRef.isEmpty {
                    if let url = URL(string: task.url), !task.url.isEmpty {
                        TicketLink(text: task.displayRef, url: url, space: project)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                            .help(task.url)
                    } else {
                        Text(task.displayRef).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else {
                    // A task without a ticket has nothing to put here, which left the row looking
                    // broken. Saying so fills the place the reference would, in the same colour.
                    Text("No ticket")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let status = task.remoteStatus, !status.isEmpty {
                    Text(status.prefix(1).uppercased() + status.dropFirst())
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                        .help("Status in \(project?.kind.label ?? "the tracker")")
                }
                Spacer(minLength: 0)
                Button(action: onEdit) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Edit task")
                    .opacity(hovering ? 1 : 0)
            }

            Text(task.title.isEmpty ? "(untitled)" : task.title)
                .font(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label {
                    Text(task.notes.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "note.text")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(task.notes)
            }

            HStack(spacing: 8) {
                if running {
                    Text(Fmt.clock(task.total(now: store.now)))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                } else if task.total(now: Date()) >= 60 {
                    // Under a minute reads as "0m", which says nothing: leave it out.
                    Text(Fmt.short(task.total(now: Date())))
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                        // Without this a crowded row squeezes the time into one character per line.
                        .fixedSize()
                }
                if project?.kind == .redmine, Int(task.ref) != nil, task.unloggedSeconds >= 60 {
                    // A compact one-line chip: an "upload" arrow and the time not yet logged.
                    Button(action: onLog) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                            Text(Fmt.short(task.unloggedSeconds))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(Color.orange)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(Fmt.short(task.unloggedSeconds)) not logged yet — click to log it to Redmine")
                }
                if let assignee = task.remoteAssignee, !assignee.isEmpty {
                    Label(assignee, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The name is the one thing in this row that may shrink.
                        .layoutPriority(-1)
                        .help("Assigned to \(assignee) in \(project?.kind.label ?? "the tracker")")
                }
                if let session = store.headlineSession(of: task) {
                    let status = store.status(of: session)
                    Button { Task { await Orca.reveal(session) } } label: {
                        SessionBadge(status: status, count: store.sessions(of: task).count)
                            .fixedSize()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Agent session “\(session.name)” in \(session.repoName). \(status?.detail ?? "") Click to open it in Orca.")
                }
                Spacer(minLength: 0)
                Button {
                    store.toggleTimer(task.id)
                } label: {
                    Image(systemName: running ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help(running ? "Pause timer" : "Start timer")
                // The pause button stays visible while the timer runs, so it can always be stopped.
                .opacity(hovering || running ? 1 : 0)
            }
        }
        .padding(10)
        // Running timer: a faint red wash over the card.
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Theme.accent.opacity(running ? 0.13 : 0)))
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        // A strip in the project's colour down the left edge, cut to the card's rounded corners.
        .overlay(alignment: .leading) {
            if let project {
                Rectangle().fill(project.color).frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) {
            // Without an integration there are no details to fetch: open the editor.
            if TicketFetcher.canFetch(project: project, task: task) { onDetails() } else { onEdit() }
        }
        .help(TicketFetcher.canFetch(project: project, task: task) ? "Double-click to see ticket details" : "Double-click to edit")
        .draggable(task.id.uuidString)
        .contextMenu {
            Button(running ? "Pause timer" : "Start timer") { store.toggleTimer(task.id) }
            Button("Edit…", action: onEdit)
            if let url = URL(string: task.url), !task.url.isEmpty {
                Button("Open ticket in browser") { Browser.open(url, space: project) }
            }
            if TicketFetcher.canFetch(project: project, task: task) {
                Button("View ticket details…", action: onDetails)
            }
            if project?.kind == .redmine {
                Button("Log time to Redmine…", action: onLog)
            }
            if let session = store.headlineSession(of: task) {
                Button("Open session in Orca") { Task { await Orca.reveal(session) } }
            }
            if let pr = store.sessions(of: task).compactMap({ store.status(of: $0)?.prURL }).last {
                Button("Open pull request in browser") { Browser.open(pr, space: project) }
            }
            Divider()
            Menu("Move to") {
                ForEach(store.columns.filter { $0.id != task.status }) { c in
                    Button(c.displayName) { store.move(task.id, to: c.id) }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(task.title.isEmpty ? task.displayRef : task.title)”?", isPresented: $confirmDelete) {
            Button("Delete task", role: .destructive) {
                store.delete(task: task.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tracked time is deleted too. This cannot be undone.")
        }
    }
}

/// Popover of the toolbar's "Today" total: time tracked today, per space.
struct TodayBreakdown: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let now = store.now
        let total = store.trackedToday(now: now)
        let rows = store.projects
            .map { (project: $0, seconds: store.trackedToday(now: now, project: $0.id)) }
            .filter { $0.seconds >= 1 }
            .sorted { $0.seconds > $1.seconds }
        let other = total - rows.reduce(0) { $0 + $1.seconds }
        VStack(alignment: .leading, spacing: 8) {
            Text("Today by space").font(.headline)
            if total < 1 {
                Text("No time tracked today.").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.project.id) { row in
                line(row.project.name, row.seconds, color: row.project.color)
            }
            if other >= 1 { line("No space", other, color: .gray) }
            if total >= 1 {
                Divider()
                HStack {
                    Text("Total").fontWeight(.semibold)
                    Spacer(minLength: 24)
                    Text(Fmt.short(total)).monospacedDigit().fontWeight(.semibold)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 220)
    }

    private func line(_ name: String, _ seconds: TimeInterval, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name)
            Spacer(minLength: 24)
            Text(Fmt.short(seconds)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
