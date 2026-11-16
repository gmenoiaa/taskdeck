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
    /// The agent queue: how many of its sessions may work at once, whether they run without stopping
    /// for permission, and whether Claude is asked which repository a ticket is about.
    var agentQueueLimit = 2
    var agentQueueSkipPermissions = true
    var agentQueueAskClaude = false
    @ObservationIgnored var processingQueue = false
    /// Which notifications are sent.
    var notify = NotificationSettings()
    /// What each session was doing at the last look, to notice when it stops or its pull request closes.
    @ObservationIgnored var sessionKinds: [String: Orca.Status.Kind] = [:]
    /// Tickets already seen as assigned to me; nil until the first look, which only takes note.
    @ObservationIgnored var knownAssigned: Set<String>?
    /// When the end-of-day reminder about unlogged time was last sent.
    @ObservationIgnored var unloggedRemindedAt: Date?
    /// How many times a running entry has been reported as running long.
    @ObservationIgnored var longTimerReminders: [UUID: Int] = [:]
    /// Updated every second; views showing running timers read from here.
    var now = Date()

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var statusLoop: Task<Void, Never>?
    var refreshingStatuses = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Live status of Orca worktrees by id; nil until Orca answered, or when it cannot be reached.
    var sessionStatuses: [String: Orca.Status]?
    /// Worktrees created in Orca that carry a task's ticket reference, by task id. Never saved: they
    /// are found again from Orca on every refresh.
    var linkedSessions: [UUID: [AgentSession]] = [:]
    /// Pull requests found by asking GitHub directly, by worktree id, for when Orca reports none.
    @ObservationIgnored private var pullRequests: [String: Orca.PullRequest] = [:]
    @ObservationIgnored private var pullRequestAsked: [String: Date] = [:]
    @ObservationIgnored private var orcaRepos: [Orca.Repo] = []
    @ObservationIgnored private var orcaReposAt = Date.distantPast
    @ObservationIgnored private var sessionLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshingSessions = false

    /// When the user left (sleep, lock or display off) with a timer running; nil while they are here.
    /// Saved, so a Mac that shut down while asleep still asks on the next launch.
    @ObservationIgnored private(set) var awaySince: Date?
    /// What currently keeps the user away. They are back when it is empty.
    @ObservationIgnored private var awayReasons: Set<String> = []
    @ObservationIgnored private var askingAboutAway = false

    private struct Snapshot: Codable {
        var projects: [Project]
        var tasks: [TaskItem]
        var columns: [BoardColumn]?
        var singleTimer: Bool?
        var claudeModel: String?
        var aiInstructions: String?
        var autoLogComment: Bool?
        var awaySince: Date?
        var agentQueueLimit: Int?
        var agentQueueSkipPermissions: Bool?
        var agentQueueAskClaude: Bool?
        var notify: NotificationSettings?
        var knownAssigned: [String]?
        var unloggedRemindedAt: Date?
    }

    static var dataURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    init() {
        load()
        Notifier.setUp()
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
                await self?.noticeNewAssignments()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }

        // Agent sessions change by the minute. Only while the app is in front: nobody sees the cards otherwise.
        // The agent queue also needs them while the app is in the background, at a slower pace.
        sessionLoop = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                round += 1
                // In the background only what someone is waiting to hear about is worth asking Orca for.
                if NSApplication.shared.isActive || (self?.watchesSessionsInBackground == true && round % 3 == 0) {
                    await self?.refreshSessionStatuses()
                    self?.noticeSessionChanges()
                    await self?.runAgentQueue()
                }
                self?.noticeTimers()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    // Using the app proves the user is back, even if a wake or unlock notice never came.
                    if let self, self.awaySince != nil {
                        self.awayReasons.removeAll()
                        self.askAboutAway(until: Date())
                    }
                    await self?.refreshSessionStatuses()
                }
            })

        // A closed app cannot count time.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Quitting while away (a restart during sleep): nobody is there to ask, so the
                    // time away is left out, as it was before the question existed.
                    if let self, let since = self.awaySince {
                        self.cutAway(at: since, resumeAt: nil)
                        self.awaySince = nil
                    }
                    self?.stopAll()
                    self?.save()
                }
            })

        // Sleep, a locked screen or a dark display mean the user walked away. Timers keep running;
        // the user decides what to do with that time when they are back.
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let leaving: [(NotificationCenter, Notification.Name, String)] = [
            (workspace, NSWorkspace.willSleepNotification, "sleep"),
            (workspace, NSWorkspace.screensDidSleepNotification, "display"),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "lock"),
        ]
        let returning: [(NotificationCenter, Notification.Name, String)] = [
            (workspace, NSWorkspace.didWakeNotification, "sleep"),
            (workspace, NSWorkspace.screensDidWakeNotification, "display"),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "lock"),
        ]
        for (center, name, reason) in leaving {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.left(reason) }
            })
        }
        for (center, name, reason) in returning {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.returned(reason) }
            })
        }
        // Left over from a run that ended while the user was away (shutdown during sleep, a crash).
        if awaySince != nil {
            Task { @MainActor [weak self] in self?.askAboutAway(until: Date()) }
        }
    }

    // MARK: Away

    private func left(_ reason: String) {
        awayReasons.insert(reason)
        // The first sign counts: the display goes dark some time before the Mac sleeps.
        guard awaySince == nil, tasks.contains(where: \.isRunning) else { return }
        awaySince = Date()
        save()
    }

    private func returned(_ reason: String) {
        awayReasons.remove(reason)
        // A display that wakes behind a locked screen is not the user being back.
        guard awayReasons.isEmpty, awaySince != nil else { return }
        let back = Date()
        // After the handler, so the alert does not hold up the system's notification.
        Task { @MainActor [weak self] in self?.askAboutAway(until: back) }
    }

    /// Asks what to do with the time a timer ran while the user was away.
    private func askAboutAway(until back: Date) {
        guard !askingAboutAway, let since = awaySince else { return }
        let running = tasks.filter { task in task.entries.contains { $0.end == nil && $0.start < since } }
        let away = back.timeIntervalSince(since)
        // Nothing to decide: no timer was running through it, or it was a glance away.
        guard !running.isEmpty, away >= 120 else {
            awaySince = nil
            save()
            return
        }
        askingAboutAway = true
        defer { askingAboutAway = false }

        let clock = since.formatted(date: Calendar.current.isDate(since, inSameDayAs: back) ? .omitted : .abbreviated,
                                    time: .shortened)
        let what = running.count == 1
            ? "The timer on “\("\(running[0].displayRef) \(running[0].title)".trimmingCharacters(in: .whitespaces))”"
            : "\(running.count) timers"
        let alert = NSAlert()
        alert.messageText = "You were away for \(Fmt.short(away))"
        alert.informativeText = """
            \(what) kept running since \(clock).

            Pause stops it at \(clock), so the time away is not counted. \
            Continue from Now also leaves the time away out, and keeps the timer running. \
            Keep Running counts the time away.
            """
        alert.addButton(withTitle: "Pause")
        alert.addButton(withTitle: "Continue from Now")
        alert.addButton(withTitle: "Keep Running")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let answer = alert.runModal()

        awaySince = nil
        switch answer {
        case .alertFirstButtonReturn: cutAway(at: since, resumeAt: nil)
        case .alertSecondButtonReturn: cutAway(at: since, resumeAt: back)
        default: break
        }
        now = Date()
        updateDockBadge()
        save()
    }

    /// Ends the stretches that ran through the time away at the moment the user left, and optionally
    /// starts new ones from when they came back.
    private func cutAway(at since: Date, resumeAt back: Date?) {
        for i in tasks.indices {
            var cut = false
            for j in tasks[i].entries.indices where tasks[i].entries[j].end == nil && tasks[i].entries[j].start < since {
                tasks[i].entries[j].end = since
                cut = true
            }
            if cut, let back { tasks[i].entries.append(TimeEntry(start: back)) }
        }
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
            awaySince = snap.awaySince
            agentQueueLimit = snap.agentQueueLimit ?? 2
            agentQueueSkipPermissions = snap.agentQueueSkipPermissions ?? true
            agentQueueAskClaude = snap.agentQueueAskClaude ?? false
            notify = snap.notify ?? NotificationSettings()
            knownAssigned = snap.knownAssigned.map(Set.init)
            unloggedRemindedAt = snap.unloggedRemindedAt
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
                            claudeModel: claudeModel, aiInstructions: aiInstructions, autoLogComment: autoLogComment,
                            awaySince: awaySince, agentQueueLimit: agentQueueLimit,
                            agentQueueSkipPermissions: agentQueueSkipPermissions,
                            agentQueueAskClaude: agentQueueAskClaude, notify: notify,
                            knownAssigned: knownAssigned.map { $0.sorted() }, unloggedRemindedAt: unloggedRemindedAt)
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
            let moved = tasks[i].status != task.status
            if moved {
                task.order = nextOrder
                task.queueNote = nil
            }
            tasks[i] = task
            if role(of: task.status) == .done { closeEntries(at: i) }
            if moved { pushStatus(of: task.id) }
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
        // Dragging a task back into the queue is how a failed start is tried again.
        tasks[i].queueNote = nil
        if role(of: columnId) == .done { closeEntries(at: i) }
        save()
        pushStatus(of: id)
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
                pushStatus(of: id)
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

    // MARK: Agent sessions

    /// Records a session that Orca just started, and remembers the repository for the task's project.
    /// `claudeHome` is remembered too when the session ran Claude (nil leaves the project's value alone).
    func addSession(_ session: AgentSession, to id: UUID, repoId: String, claudeHome: String? = nil,
                    githubAccount: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].sessions = (tasks[i].sessions ?? []) + [session]
        if let p = projects.firstIndex(where: { $0.id == tasks[i].projectId }) {
            projects[p].orcaRepoId = repoId
            // A repository used for a space's task belongs to that space from then on.
            if !projects[p].repoIds.contains(repoId) { projects[p].orcaRepoIds = projects[p].repoIds + [repoId] }
            projects[p].githubAccount = githubAccount.isEmpty ? nil : githubAccount
            if let claudeHome { projects[p].claudeHome = claudeHome.isEmpty ? nil : claudeHome }
        }
        save()
        Task { await refreshSessionStatuses() }
    }

    /// Asks Orca about every worktree, but only when a task has a session or a space has repositories
    /// whose worktrees could belong to a task.
    /// `force` is the refresh button: it also asks GitHub again about every session without waiting
    /// out the five minutes, and reads Orca's repositories again.
    func refreshSessionStatuses(force: Bool = false) async {
        guard Orca.isInstalled else { return }
        if force {
            // A background refresh may be half-way; let it finish (a few seconds at most) and then run this one.
            for _ in 0..<50 where refreshingSessions { try? await Task.sleep(for: .milliseconds(100)) }
            pullRequestAsked.removeAll()
            orcaReposAt = .distantPast
        }
        guard !refreshingSessions else { return }
        let spaces = projects.filter { !$0.repoIds.isEmpty || !($0.githubOrg ?? "").isEmpty }
        guard !spaces.isEmpty || !queueWaiting.isEmpty
                || tasks.contains(where: { !$0.archived && !($0.sessions ?? []).isEmpty }) else { return }
        refreshingSessions = true
        defer { refreshingSessions = false }
        guard let trees = try? await Orca.worktrees() else {
            // Orca closed or not answering: show no status rather than a stale one.
            if sessionStatuses != nil { sessionStatuses = nil }
            return
        }
        // Repositories change rarely; they are needed for organisations and for asking GitHub.
        if Date().timeIntervalSince(orcaReposAt) > 300, let repos = try? await Orca.repos() {
            orcaRepos = repos
            orcaReposAt = Date()
        }
        link(trees, spaces: spaces)
        publish(trees)
        if await askGitHub(trees, limit: force ? 40 : 3) { publish(trees) }
    }

    /// Matches worktrees created in Orca to tasks: same space, and the ticket reference in the name or branch.
    private func link(_ trees: [Orca.Worktree], spaces: [Project]) {
        let saved = Set(tasks.flatMap { $0.sessions ?? [] }.compactMap(\.worktreeId))
        let known = Dictionary(linkedSessions.values.flatMap { $0 }.compactMap { s in s.worktreeId.map { ($0, s.id) } },
                               uniquingKeysWith: { first, _ in first })
        var fresh: [UUID: [AgentSession]] = [:]
        for space in spaces {
            let repoIds = Set(space.repoIds).union(orcaRepos.filter(space.owns).map(\.id))
            // The main checkout is the repository itself, not work on one ticket.
            let candidates = trees.filter { repoIds.contains($0.repoId) && !$0.isMain && !saved.contains($0.id) }
            guard !candidates.isEmpty else { continue }
            for task in tasks where task.projectId == space.id && !task.archived && !task.ref.isEmpty {
                let found = candidates
                    .filter { Orca.mentions(task.ref, in: $0.name) || Orca.mentions(task.ref, in: $0.branch) }
                    .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
                    .map { tree in
                        // The same id as last time, so the views do not rebuild their rows every refresh.
                        AgentSession(id: known[tree.id] ?? UUID(), worktreeId: tree.id, path: tree.path,
                                     name: tree.name, repoName: tree.repoName, agent: "",
                                     startedAt: tree.createdAt ?? .distantPast)
                    }
                if !found.isEmpty { fresh[task.id] = found }
            }
        }
        if linkedSessions != fresh { linkedSessions = fresh }
    }

    /// Turns Orca's answer into the statuses the views read, with GitHub's pull request where Orca has none.
    private func publish(_ trees: [Orca.Worktree]) {
        var fresh: [String: Orca.Status] = [:]
        let slugs = Dictionary(orcaRepos.compactMap { repo in repo.slug.map { (repo.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        for tree in trees {
            var status = tree.status
            if status.prNumber == nil, let pr = pullRequests[tree.id] {
                status.prNumber = pr.number
                if status.kind == .idle {
                    status.kind = pr.state == "open" ? .prOpen : pr.state == "merged" ? .prMerged : .prClosed
                }
            }
            if let number = status.prNumber, let slug = slugs[tree.repoId] {
                status.prURL = URL(string: "https://github.com/\(slug)/pull/\(number)")
            }
            fresh[tree.id] = status
        }
        if sessionStatuses != fresh { sessionStatuses = fresh }
    }

    /// Asks GitHub about sessions for which Orca reports no pull request, as the space's GitHub account.
    /// A few per background refresh and each at most every five minutes. Returns whether anything changed.
    private func askGitHub(_ trees: [Orca.Worktree], limit: Int) async -> Bool {
        let byId = Dictionary(trees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let slugs = Dictionary(orcaRepos.compactMap { repo in repo.slug.map { (repo.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        var due: [(tree: Orca.Worktree, slug: String, account: String?)] = []
        for task in tasks where !task.archived {
            for session in sessions(of: task) {
                guard let id = session.worktreeId, let tree = byId[id], !tree.branch.isEmpty,
                      tree.status.prNumber == nil, tree.status.kind != .working,
                      let slug = slugs[tree.repoId] else { continue }
                // A merged or closed pull request does not change again.
                if let pr = pullRequests[id], pr.state != "open" { continue }
                if let asked = pullRequestAsked[id], Date().timeIntervalSince(asked) < 300 { continue }
                if due.contains(where: { $0.tree.id == id }) { continue }
                due.append((tree, slug, session.githubAccount ?? project(task.projectId)?.githubAccount))
            }
        }
        var changed = false
        for item in due.prefix(limit) {
            pullRequestAsked[item.tree.id] = Date()
            // A failed question keeps what was known; only a real answer replaces it.
            guard let answer = await Orca.pullRequest(slug: item.slug, branch: item.tree.branch, account: item.account) else { continue }
            if pullRequests[item.tree.id] != answer {
                pullRequests[item.tree.id] = answer
                changed = true
            }
        }
        return changed
    }

    /// A task's sessions: those started here, then worktrees created in Orca that carry its reference.
    func sessions(of task: TaskItem) -> [AgentSession] {
        (task.sessions ?? []) + (linkedSessions[task.id] ?? [])
    }

    /// The live status of a session; nil when Orca did not answer or the session has no worktree id.
    func status(of session: AgentSession) -> Orca.Status? {
        guard let all = sessionStatuses, let id = session.worktreeId else { return nil }
        return all[id] ?? .gone
    }

    /// The session a card should show: one that waits for the user first, then one that is working,
    /// otherwise the newest.
    func headlineSession(of task: TaskItem) -> AgentSession? {
        let sessions = sessions(of: task)
        return sessions.last { status(of: $0)?.kind == .yourTurn }
            ?? sessions.last { status(of: $0)?.kind == .working }
            ?? sessions.last
    }

    /// Forgets a session here. The worktree and its branch stay in Orca.
    func removeSession(_ sessionId: UUID, from id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].sessions?.removeAll { $0.id == sessionId }
        save()
    }

    // MARK: Tracker status

    /// Tells the tracker about a task that just entered a column, when its space maps that column to
    /// a status. Runs in the background; a refusal is reported, and the card stays where it was put.
    func pushStatus(of id: UUID) {
        // A refusal belongs to the column the task was in then.
        if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].statusNote != nil {
            tasks[i].statusNote = nil
            save()
        }
        guard let task = task(id), let project = project(task.projectId),
              TicketFetcher.canSetStatus(project.kind), TicketFetcher.canFetch(project: project, task: task),
              let value = project.statusByColumn?[task.status], !value.isEmpty else { return }
        let column = task.status
        Task {
            do {
                // The status of the In progress column, as a stepping stone when the tracker has no
                // direct step to the one wanted.
                let via = columns.first { $0.role == .inProgress }.flatMap { project.statusByColumn?[$0.id] }
                let name = try await TicketFetcher.setStatus(project: project, ref: task.ref, url: task.url,
                                                             to: value, via: via)
                // Moved on while the request was out: the later move sends its own status.
                guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status == column else { return }
                if !name.isEmpty, tasks[i].remoteStatus != name {
                    tasks[i].remoteStatus = name
                    save()
                }
            } catch {
                // On the card as well: a notification is easy to miss, or switched off in macOS.
                if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status == column {
                    tasks[i].statusNote = error.localizedDescription
                    save()
                }
                Notifier.send(title: "Ticket status not changed",
                              body: "\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces)
                                + "\n\(error.localizedDescription)")
            }
        }
    }

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
    /// The refresh button: sessions and pull requests alongside the tickets, so one click brings
    /// everything up to date.
    func refreshEverything() async {
        async let sessions: Void = refreshSessionStatuses(force: true)
        await refreshRemoteStatuses()
        await sessions
    }

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
        return tracked(in: DateInterval(start: dayStart, end: max(now, dayStart)), now: now, project: project)
    }

    /// Time tracked inside a period, for every space or only the given one. Archived tasks count:
    /// the time was still spent.
    func tracked(in period: DateInterval, now: Date, project: UUID? = nil) -> TimeInterval {
        tasks.reduce(0) { sum, task in
            project == nil || task.projectId == project ? sum + task.tracked(in: period, now: now) : sum
        }
    }
}
