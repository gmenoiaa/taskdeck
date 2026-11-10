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
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("Today: \(Fmt.short(store.trackedToday(now: store.now)))")
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("Only one timer at a time", isOn: $store.singleTimer)
                    Button("Pause all timers") { store.stopAll() }
                        .disabled(store.runningTasks.isEmpty)
                    Button("Archived tasks…") { showArchive = true }
                    Button("Refresh ticket statuses") { Task { await store.refreshRemoteStatuses() } }
                        .disabled(store.refreshingStatuses)
                    Divider()
                    SettingsLink { Text("Settings…") }
                    Button("Show data file in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppStore.dataURL])
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
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
            // On macOS 26+ this puts "New task" in its own glass capsule, apart from the group.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = TaskItem(projectId: filter ?? store.projects.first?.id, status: store.defaultColumnId)
                } label: {
                    Label("New task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New task (⌘N)")
            }
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

    var body: some View {
        let project = store.project(task.projectId)
        let running = task.isRunning
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let project {
                    Text(project.name)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(project.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(project.color)
                }
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
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(running ? Theme.accent.opacity(0.75) : Color.primary.opacity(0.08),
                              lineWidth: running ? 1.5 : 1)
        )
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
            Divider()
            Menu("Move to") {
                ForEach(store.columns.filter { $0.id != task.status }) { c in
                    Button(c.displayName) { store.move(task.id, to: c.id) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(task: task.id) }
        }
    }
}
