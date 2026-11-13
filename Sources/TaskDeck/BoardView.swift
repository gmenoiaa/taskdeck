import SwiftUI
import AppKit

struct BoardView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: UUID?
    @State private var editing: TaskItem?
    @State private var logging: TaskItem?
    @State private var details: TaskItem?
    @State private var showImport = false
    @State private var showArchive = false
    @State private var showToday = false
    @State private var showPending = false

private func newTask() {
        editing = TaskItem(projectId: filter ?? store.projects.first?.id, status: store.defaultColumnId)
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
                .keyboardShortcut("n", modifiers: .command)
                .help("New task (⌘N)")
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newTask) { Label("New task", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New task (⌘N)")
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
    }

        var body: some View {
        @Bindable var store = store
        GeometryReader { geo in
            // Columns share the window width; with many columns they keep a readable width and scroll sideways.
            let count = CGFloat(max(store.columns.count, 1))
            let width = max(250, (geo.size.width - 24 - 12 * (count - 1)) / count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(store.columns) { column in
                        ColumnView(
                            column: column,
                            tasks: store.tasks(in: column.id, project: filter),
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Project", selection: $filter) {
                    Text("All projects").tag(UUID?.none)
                    ForEach(store.projects) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
                .fixedSize()
            }
            ToolbarItem(placement: .principal) {
                // With "All projects", a click shows today's time per project.
                Button { if filter == nil { showToday.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("Today: \(Fmt.short(store.trackedToday(now: store.now, project: filter)))")
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
                .help(filter == nil ? "Show today's time per project" : "Time tracked today on this project")
                .popover(isPresented: $showToday, arrowEdge: .bottom) {
                    TodayBreakdown().environment(store)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await store.refreshRemoteStatuses() } } label: {
                    // The spinner takes the icon's place while refreshing, so the button keeps its size.
                    ZStack {
                        Image(systemName: "arrow.clockwise").opacity(store.refreshingStatuses ? 0 : 1)
                        if store.refreshingStatuses { ProgressView().controlSize(.small) }
                    }
                    .accessibilityLabel(store.refreshingStatuses ? "Refreshing statuses" : "Refresh statuses")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.refreshingStatuses)
                .help("Refresh ticket statuses and assignees from the trackers (⌘R)")
                // Tracked time not on Redmine yet: the amount shows next to the icon.
                Button { showPending = true } label: {
                    let pending = store.pendingLogTasks.reduce(0) { $0 + $1.unloggedSeconds }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle")
                        if pending >= 60 {
                            Text(Fmt.short(pending)).monospacedDigit().foregroundStyle(.orange)
                        }
                    }
                    .accessibilityLabel("Time to push")
                }
                .keyboardShortcut("l", modifiers: .command)
                .help("Time to push: tracked time that is not on Redmine yet (⌘L)")
                Button { showImport = true } label: {
                    Label("Assigned to me", systemImage: "tray.and.arrow.down")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Fetch tickets assigned to me (⌘I)")
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings: projects, AI and timers (⌘,)")
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
                        TicketLink(text: task.displayRef, url: url)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                            .help(task.url)
                    } else {
                        Text(task.displayRef).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
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
                } else {
                    Text(Fmt.short(task.total(now: Date())))
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
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
                        .help("Assigned to \(assignee) in \(project?.kind.label ?? "the tracker")")
                }
                if let session = store.headlineSession(of: task) {
                    let status = store.status(of: session)
                    Button { Task { await Orca.reveal(session) } } label: {
                        SessionBadge(status: status, count: task.sessions?.count ?? 1)
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
                Button("Open ticket in browser") { NSWorkspace.shared.open(url) }
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

/// Popover of the toolbar's "Today" total: time tracked today, per project.
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
            Text("Today by project").font(.headline)
            if total < 1 {
                Text("No time tracked today.").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.project.id) { row in
                line(row.project.name, row.seconds, color: row.project.color)
            }
            if other >= 1 { line("No project", other, color: .gray) }
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
