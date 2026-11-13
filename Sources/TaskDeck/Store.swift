import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppStore {
    var projects: [Project] = []
    var tasks: [TaskItem] = []
    var columns: [BoardColumn] = BoardColumn.defaults
    var singleTimer = false
    /// Claude model used by AI features, and instructions added to every AI request.
    var claudeModel = Claude.defaultModel
    var aiInstructions = ""
    /// Propose the time-entry comment when a log screen opens, instead of only on "Generate".
    var autoLogComment = false
    /// Updated every second; views showing running timers read from here.
    var now = Date()

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var statusLoop: Task<Void, Never>?
    var refreshingStatuses = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private struct Snapshot: Codable {
        var projects: [Project]
        var tasks: [TaskItem]
        var columns: [BoardColumn]?
        var singleTimer: Bool?
        var claudeModel: String?
        var aiInstructions: String?
        var autoLogComment: Bool?
    }

    static var dataURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    init() {
        load()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.updateDockBadge()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        // Keep the trackers' own statuses fresh: at launch and every 15 minutes.
        statusLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRemoteStatuses()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }

        // Don't let timers keep counting while the Mac sleeps or the app is closed.
        let pause: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: pause))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: pause))
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.dataURL),
           let snap = try? decoder.decode(Snapshot.self, from: data) {
            projects = snap.projects
            tasks = snap.tasks
            if let saved = snap.columns, !saved.isEmpty { columns = saved }
            adoptOrphans()
            singleTimer = snap.singleTimer ?? false
            claudeModel = snap.claudeModel ?? Claude.defaultModel
            aiInstructions = snap.aiInstructions ?? ""
            autoLogComment = snap.autoLogComment ?? false
        } else if !FileManager.default.fileExists(atPath: Self.dataURL.path) {
            projects = [
                Project(name: "Onerhino", kind: .redmine, colorIndex: 6),
                Project(name: "Aries/Slate", kind: .jira, colorIndex: 0),
                Project(name: "Apideck", kind: .github, colorIndex: 3),
            ]
            save()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snap = Snapshot(projects: projects, tasks: tasks, columns: columns, singleTimer: singleTimer,
                            claudeModel: claudeModel, aiInstructions: aiInstructions, autoLogComment: autoLogComment)
        if let data = try? encoder.encode(snap) {
            try? data.write(to: Self.dataURL, options: .atomic)
        }
    }

    // MARK: Projects

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func upsert(_ project: Project) {
        if let i = projects.firstIndex(where: { $0.id == project.id }) {
            projects[i] = project
        } else {
            projects.append(project)
        }
        save()
    }

    func delete(project: Project) {
        projects.removeAll { $0.id == project.id }
        for i in tasks.indices where tasks[i].projectId == project.id {
            tasks[i].projectId = nil
        }
        Keychain.delete(account: project.keychainAccount)
        Keychain.delete(account: Claude.legacyKeyAccount(project))
        save()
    }

    // MARK: Tasks

    func task(_ id: UUID) -> TaskItem? { tasks.first { $0.id == id } }

    func tasks(in columnId: String, project filter: UUID?) -> [TaskItem] {
        tasks.filter { $0.status == columnId && !$0.archived && (filter == nil || $0.projectId == filter) }
            .sorted { $0.order < $1.order }
    }

    private var nextOrder: Double { (tasks.map(\.order).max() ?? 0) + 1 }

    func upsert(_ task: TaskItem) {
        var task = task
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            if tasks[i].status != task.status { task.order = nextOrder }
            tasks[i] = task
            if role(of: task.status) == .done { closeEntries(at: i) }
        } else {
            task.order = nextOrder
            tasks.append(task)
        }
        save()
    }

    func delete(task id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    func move(_ id: UUID, to columnId: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status != columnId,
              column(columnId) != nil else { return }
        tasks[i].status = columnId
        tasks[i].order = nextOrder
        if role(of: columnId) == .done { closeEntries(at: i) }
        save()
    }

    func archive(column columnId: String) {
        for i in tasks.indices where tasks[i].status == columnId {
            tasks[i].archived = true
        }
        save()
    }

    // MARK: Columns

    func column(_ id: String) -> BoardColumn? { columns.first { $0.id == id } }

    func role(of columnId: String) -> ColumnRole { column(columnId)?.role ?? .normal }

    /// Where new and imported tasks go: the first not-started column, or simply the first one.
    var defaultColumnId: String {
        (columns.first { $0.role == .backlog } ?? columns.first)?.id ?? "todo"
    }

    func taskCount(in columnId: String) -> Int { tasks.filter { $0.status == columnId }.count }

    func addColumn() {
        columns.append(BoardColumn(name: "New column"))
        save()
    }

    /// Removes a column and moves its tasks (archived ones too) to another column. The last column stays.
    func deleteColumn(_ id: String) {
        guard columns.count > 1, let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns.remove(at: index)
        adoptOrphans()
        save()
    }

    /// Puts tasks whose column no longer exists into the default column.
    private func adoptOrphans() {
        let known = Set(columns.map(\.id))
        let fallback = defaultColumnId
        for i in tasks.indices where !known.contains(tasks[i].status) {
            tasks[i].status = fallback
        }
    }

    var archivedCount: Int { tasks.filter(\.archived).count }

    func unarchive(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].archived = false
        tasks[i].order = nextOrder
        save()
    }

    // MARK: Timers

    var runningTasks: [TaskItem] { tasks.filter(\.isRunning) }

    /// Dock badge while a timer runs: the time since the single running timer was started, or how many are running.
    /// Called every second by the ticker and right after a timer starts or stops.
    private func updateDockBadge() {
        let running = runningTasks
        let label: String? = switch running.count {
        case 0: nil
        // The current stretch only (since the last start), not the task's total.
        case 1: Fmt.hm(running[0].entries.last { $0.end == nil }?.duration(now: now) ?? 0)
        default: "\(running.count)"
        }
        let tile = NSApplication.shared.dockTile
        if tile.badgeLabel != label { tile.badgeLabel = label }
    }

    private func closeEntries(at i: Int) {
        let end = Date()
        for j in tasks[i].entries.indices where tasks[i].entries[j].end == nil {
            tasks[i].entries[j].end = end
        }
        // Discard accidental clicks (< 1s).
        tasks[i].entries.removeAll { ($0.end ?? .distantFuture).timeIntervalSince($0.start) < 1 }
    }

    func toggleTimer(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[i].isRunning {
            closeEntries(at: i)
        } else {
            if singleTimer {
                for k in tasks.indices where tasks[k].isRunning { closeEntries(at: k) }
            }
            tasks[i].entries.append(TimeEntry(start: Date()))
            // Starting work on a not-started or done task moves it to the In progress column, if there is one.
            let current = role(of: tasks[i].status)
            if current == .backlog || current == .done,
               let target = columns.first(where: { $0.role == .inProgress }) {
                tasks[i].status = target.id
                tasks[i].order = nextOrder
            }
            tasks[i].archived = false
        }
        now = Date()
        updateDockBadge()
        save()
    }

    func stopAll() {
        var changed = false
        for i in tasks.indices where tasks[i].isRunning {
            closeEntries(at: i)
            changed = true
        }
        if changed { save() }
        updateDockBadge()
    }

    /// Changes when a stretch started or ended. A running stretch stays running; an entry never ends before it starts.
    func updateEntry(task id: UUID, _ entry: TimeEntry) {
        guard let i = tasks.firstIndex(where: { $0.id == id }),
              let j = tasks[i].entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let current = tasks[i].entries[j]
        var updated = current
        let limit = current.end ?? Date()
        updated.start = min(entry.start, limit)
        if current.end != nil, let end = entry.end { updated.end = max(end, updated.start) }
        guard updated != current else { return }
        tasks[i].entries[j] = updated
        now = Date()
        updateDockBadge()
        save()
    }

    func deleteEntry(task id: UUID, entry entryId: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].entries.removeAll { $0.id == entryId }
        now = Date()
        updateDockBadge()
        save()
    }

    func setNotes(_ id: UUID, _ text: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].notes != text else { return }
        tasks[i].notes = text
        save()
    }

    func setExplanation(_ id: UUID, _ text: String?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].explanation = text
        save()
    }

    // MARK: Tracker status

    /// Records what the tracker says about a ticket: its status and who it is assigned to.
    func setRemote(_ id: UUID, from detail: TicketDetail) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if let status = detail.status, !status.isEmpty, tasks[i].remoteStatus != status {
            tasks[i].remoteStatus = status
            changed = true
        }
        // A successful fetch with no assignee means the ticket is unassigned now.
        if tasks[i].remoteAssignee != detail.assignee {
            tasks[i].remoteAssignee = detail.assignee
            changed = true
        }
        if changed { save() }
    }

    /// Re-reads the tracker status of every task on the board, one request at a time.
    func refreshRemoteStatuses() async {
        guard !refreshingStatuses else { return }
        refreshingStatuses = true
        defer { refreshingStatuses = false }
        let targets = tasks.filter { !$0.archived && TicketFetcher.canFetch(project: project($0.projectId), task: $0) }
        for task in targets {
            guard let project = project(task.projectId) else { continue }
            // A ticket that fails (no credentials, offline, deleted) just keeps its last known status.
            if let detail = try? await TicketFetcher.fetch(project: project, ref: task.ref, url: task.url) {
                setRemote(task.id, from: detail)
            }
        }
    }

    /// Redmine tasks with tracked time that was not sent yet, most pending time first.
    var pendingLogTasks: [TaskItem] {
        tasks.filter { task in
            task.unloggedSeconds > 0 && Int(task.ref) != nil && project(task.projectId)?.kind == .redmine
        }
        .sorted { $0.unloggedSeconds > $1.unloggedSeconds }
    }

    func markLogged(task id: UUID, entries ids: Set<UUID>) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let stamp = Date()
        for j in tasks[i].entries.indices where ids.contains(tasks[i].entries[j].id) {
            tasks[i].entries[j].loggedAt = stamp
        }
        save()
    }

    /// Time tracked today, for every project or only the given one.
    func trackedToday(now: Date, project: UUID? = nil) -> TimeInterval {
        let dayStart = Calendar.current.startOfDay(for: now)
        var sum: TimeInterval = 0
        for task in tasks where project == nil || task.projectId == project {
            for e in task.entries {
                let end = e.end ?? now
                let start = max(e.start, dayStart)
                if end > start { sum += end.timeIntervalSince(start) }
            }
        }
        return sum
    }
}
