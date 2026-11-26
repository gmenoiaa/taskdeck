import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppStore {
    var projects: [Project] = []
    var tasks: [TaskItem] = []
    var goals: [Goal] = []
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
    /// The first message of a code review session, for spaces without their own. Empty means
    /// `CodeReview.standardPrompt`.
    var codeReviewPrompt = ""
    var agentQueueSkipPermissions = true
    var agentQueueAskClaude = false
    @ObservationIgnored var processingQueue = false
    /// Which notifications are sent.
    var notify = NotificationSettings() {
        didSet { Notifier.sound = notify.sound }
    }
    /// What each session was doing at the last look, to notice when it stops or its pull request closes.
    @ObservationIgnored var sessionKinds: [String: Orca.Status.Kind] = [:]
    /// Tickets already seen as assigned to me; nil until the first look, which only takes note.
    @ObservationIgnored var knownAssigned: Set<String>?
    /// Waiting items the user cleared from the bell's list, by `WaitingItem.id`.
    var clearedWaiting: Set<String> = []
    /// Pull requests whose end (merged or closed) was already reported, as "worktree|kind". Saved:
    /// after a launch the app learns again that an old one is merged, and that is not news.
    var announcedPullRequests: Set<String> = []
    /// For each open pull request's page, when its newest review or comment was written, as of the
    /// last announcement. Saved, so a launch does not announce old feedback again. A pull request
    /// first seen with feedback on it takes note of it without a banner.
    var pullRequestFeedbackSeen: [String: Date] = [:]
    /// What each space's tracker lists as assigned to me, as of the last look (kept in `assigned.json`).
    var assignedTickets: [UUID: [RemoteTicket]] = [:]
    /// Why a space's tracker could not be read at the last look.
    var assignedErrors: [UUID: String] = [:]
    var refreshingAssigned = false
    /// Assigned tickets the user does not want on the board, by `RemoteTicket.id`.
    var ignoredAssigned: Set<String> = []
    /// When the end-of-day reminder about unlogged time was last sent.
    @ObservationIgnored var unloggedRemindedAt: Date?
    /// What the last review found, over every space.
    var review: Review?
    /// The Claude home whose login runs the review, as typed; empty for the default one.
    var reviewHome = ""
    var reviewModel = ClaudeCode.defaultModel
    /// Whether a session that stops starts a review by itself.
    var reviewWhenSessionStops = false
    var reviewing = false
    /// Review lines the user dismissed, by task id, with what each was about (`ReviewItem.key`).
    var reviewDismissed: [String: String] = [:]
    /// When a review last started, so automatic ones keep their distance.
    @ObservationIgnored var reviewRanAt: Date?
    /// Exactly what the last request to Claude held, to be read in the app. Not saved.
    var lastReviewPrompt: String?
    /// The last standup update written for each space, by space id.
    var standups: [UUID: StandupNote] = [:]
    /// When each space's standup reminder was last sent, so it comes once a day.
    @ObservationIgnored var standupRemindedAt: [UUID: Date] = [:]
    /// A space whose standup sheet should open in the main window: set by the menu bar, a command
    /// or a notification, and cleared by the window once it shows the sheet. Not saved.
    var openStandup: UUID?
    /// A request for the main window to open the review sheet: a pull request's link dropped on the
    /// board, or an empty text from the menu bar, where the sheet looks at the clipboard itself.
    /// Cleared by the window once it shows the sheet. Not saved.
    var openReview: String?

    /// Takes a dropped text when it is a pull request's link. Cards are dragged as text too, so
    /// the board's drop targets ask this first.
    func takeDrop(_ text: String) -> Bool {
        guard Orca.isInstalled, CodeReview.pullRequest(text) != nil else { return false }
        openReview = text
        return true
    }
    /// The overview's widgets in the user's order; empty means the default. Read it through
    /// `overviewPlacements`, which fills in widgets the file does not mention.
    var overviewLayout: [OverviewSlot] = []
    /// Since when the user has been at the Mac in one go; nil while away or idle. Not saved.
    var activeSince: Date? = Date()
    @ObservationIgnored var noTimerRemindedAt: Date?
    /// Set for a short while after a timer starts late: the choice to count from earlier.
    var backdateOffer: BackdateOffer?
    var isAway: Bool { !awayReasons.isEmpty }
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
    /// Worktree ids being removed in Orca right now, so the views can show it is under way.
    var removingWorktrees: Set<String> = []
    /// Pull requests found by asking GitHub directly, by worktree id, for when Orca reports none.
    @ObservationIgnored private var pullRequests: [String: Orca.PullRequest] = [:]
    /// What each stopped session's transcript ends on, by worktree id. Read again on every refresh.
    @ObservationIgnored private var transcripts: [String: SessionTranscript.Last] = [:]
    /// Title, draft flag and dates of the agent sessions' pull requests, by their page. Read for
    /// a standup only; a merged or closed one is not asked about again.
    @ObservationIgnored private var pullRequestDetails: [URL: Orca.PullRequestDetail] = [:]
    @ObservationIgnored private var pullRequestAsked: [String: Date] = [:]
    /// Reviews and comments on the sessions' open pull requests, by the pull request's page.
    @ObservationIgnored private var pullRequestFeedback: [URL: Orca.PullRequestFeedback] = [:]
    @ObservationIgnored private var feedbackAsked: [URL: Date] = [:]
    /// The developer's own GitHub logins, read from gh at most every hour.
    @ObservationIgnored private var githubLogins: (logins: Set<String>, at: Date)?
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
        var clearedWaiting: [String]?
        var announcedPullRequests: [String]?
        var pullRequestFeedbackSeen: [String: Date]?
        var ignoredAssigned: [String]?
        var unloggedRemindedAt: Date?
        var goals: [Goal]?
        /// Keyed by the space's UUID string: dictionaries with UUID keys encode as arrays.
        var standups: [String: StandupNote]?
        var standupRemindedAt: [String: Date]?
        var review: Review?
        var reviewHome: String?
        var reviewModel: String?
        var reviewWhenSessionStops: Bool?
        var reviewDismissed: [String: String]?
        var overviewLayout: [OverviewSlot]?
        var codeReviewPrompt: String?
    }

    static var dataURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    init() {
        load()
        // Said outright: whether `didSet` runs for values set during init is easy to get wrong.
        Notifier.sound = notify.sound
        loadAssigned()
        Notifier.setUp()
        Notifier.onStart = { [weak self] id, since in self?.startTimer(id, from: since) }
        Notifier.onStandup = { [weak self] id in self?.openStandup = id }
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
                await self?.refreshAssigned()
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
                self?.noticeStandups()
                self?.trackPresence()
                self?.noticeNoTimer()
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
        activeSince = nil
        // The first sign counts: the display goes dark some time before the Mac sleeps.
        guard awaySince == nil, tasks.contains(where: \.isRunning) else { return }
        awaySince = Date()
        save()
    }

    private func returned(_ reason: String) {
        awayReasons.remove(reason)
        if awayReasons.isEmpty, activeSince == nil { activeSince = Date() }
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
            clearedWaiting = Set(snap.clearedWaiting ?? [])
            announcedPullRequests = Set(snap.announcedPullRequests ?? [])
            pullRequestFeedbackSeen = snap.pullRequestFeedbackSeen ?? [:]
            ignoredAssigned = Set(snap.ignoredAssigned ?? [])
            unloggedRemindedAt = snap.unloggedRemindedAt
            goals = snap.goals ?? []
            standups = Self.byUUID(snap.standups)
            standupRemindedAt = Self.byUUID(snap.standupRemindedAt)
            review = snap.review
            reviewHome = snap.reviewHome ?? ""
            reviewModel = snap.reviewModel ?? ClaudeCode.defaultModel
            reviewWhenSessionStops = snap.reviewWhenSessionStops ?? false
            reviewDismissed = snap.reviewDismissed ?? [:]
            overviewLayout = snap.overviewLayout ?? []
            codeReviewPrompt = snap.codeReviewPrompt ?? ""
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
                            knownAssigned: knownAssigned.map { $0.sorted() },
                            clearedWaiting: clearedWaiting.isEmpty ? nil : clearedWaiting.sorted(),
                            announcedPullRequests: announcedPullRequests.isEmpty ? nil : announcedPullRequests.sorted(),
                            pullRequestFeedbackSeen: pullRequestFeedbackSeen.isEmpty ? nil : pullRequestFeedbackSeen,
                            ignoredAssigned: ignoredAssigned.isEmpty ? nil : ignoredAssigned.sorted(), unloggedRemindedAt: unloggedRemindedAt,
                            goals: goals.isEmpty ? nil : goals,
                            standups: standups.isEmpty ? nil : Self.byString(standups),
                            standupRemindedAt: standupRemindedAt.isEmpty ? nil : Self.byString(standupRemindedAt),
                            review: review, reviewHome: reviewHome.isEmpty ? nil : reviewHome,
                            reviewModel: reviewModel, reviewWhenSessionStops: reviewWhenSessionStops,
                            reviewDismissed: reviewDismissed.isEmpty ? nil : reviewDismissed,
                            overviewLayout: overviewLayout.isEmpty ? nil : overviewLayout,
                            codeReviewPrompt: codeReviewPrompt.isEmpty ? nil : codeReviewPrompt)
        if let data = try? encoder.encode(snap) {
            try? data.write(to: Self.dataURL, options: .atomic)
        }
    }

    private static func byUUID<Value>(_ saved: [String: Value]?) -> [UUID: Value] {
        var out: [UUID: Value] = [:]
        for (key, value) in saved ?? [:] { if let id = UUID(uuidString: key) { out[id] = value } }
        return out
    }

    private static func byString<Value>(_ values: [UUID: Value]) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) })
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
        standups[project.id] = nil
        standupRemindedAt[project.id] = nil
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
            // The move log is the store's: an edited copy may hold an older one.
            task.moves = tasks[i].moves
            if moved {
                task.order = nextOrder
                task.queueNote = nil
                task.noteMove(to: task.status)
            }
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
        TicketCache.remove(id)
        save()
    }

    func move(_ id: UUID, to columnId: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), column(columnId) != nil else { return }
        // A search shows archived cards too; moving one is putting it back on the board, even
        // into the lane it was archived from.
        guard tasks[i].status != columnId || tasks[i].archived else { return }
        tasks[i].archived = false
        let from = role(of: tasks[i].status)
        tasks[i].status = columnId
        tasks[i].noteMove(to: columnId)
        tasks[i].order = nextOrder
        // Moving a card to In progress is saying "I am on this now". Not from the agents' lane:
        // that card was the agent's work, and picking it up is not the user starting on it.
        if notify.autoStartInProgress, role(of: columnId) == .inProgress, from != .agents, !tasks[i].isRunning {
            begin(i)
            now = Date()
            updateDockBadge()
        }
        // Dragging a task back into the queue is how a failed start is tried again.
        tasks[i].queueNote = nil
        if role(of: columnId) == .done { closeEntries(at: i) }
        save()
    }

    /// Puts a task just above another one in a column, or last when `target` is nil, changing
    /// its column if needed.
    func place(_ id: UUID, before target: UUID?, in columnId: String) {
        guard id != target, column(columnId) != nil, tasks.contains(where: { $0.id == id }) else { return }
        move(id, to: columnId)
        // The whole column, not only the space being shown: `order` is shared by every space.
        var ids = tasks.filter { $0.status == columnId && !$0.archived && $0.id != id }
            .sorted { $0.order < $1.order }
            .map(\.id)
        ids.insert(id, at: target.flatMap { ids.firstIndex(of: $0) } ?? ids.count)
        // Renumbered rather than squeezed between two neighbours: tasks can share an `order`,
        // and then there is no value in between. Order is only ever compared inside a column.
        for (position, taskId) in ids.enumerated() {
            if let i = tasks.firstIndex(where: { $0.id == taskId }) { tasks[i].order = Double(position + 1) }
        }
        save()
    }

    /// Puts a task first in its own column.
    func moveToTop(_ id: UUID) {
        guard let task = task(id) else { return }
        let first = tasks.filter { $0.status == task.status && !$0.archived && $0.id != id }
            .min { $0.order < $1.order }
        guard let first else { return }
        place(id, before: first.id, in: task.status)
    }

    /// Takes one task off the board, keeping its time history. A running timer is stopped:
    /// an archived task has no card to stop it from.
    func archive(task id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        closeEntries(at: i)
        tasks[i].archived = true
        save()
    }

    func archive(column columnId: String) {
        for i in tasks.indices where tasks[i].status == columnId {
            tasks[i].archived = true
        }
        save()
    }

    // MARK: Goals

    func goal(_ id: UUID?) -> Goal? {
        guard let id else { return nil }
        return goals.first { $0.id == id }
    }

    /// A goal's tasks, archived ones included: they are part of what was done for it.
    func tasks(of goalId: UUID) -> [TaskItem] {
        tasks.filter { $0.goalId == goalId }.sorted { $0.order < $1.order }
    }

    func isDone(_ task: TaskItem) -> Bool { task.archived || role(of: task.status) == .done }

    /// Goals to show for a space: those with a task in it, and those with no task yet, which
    /// would otherwise be nowhere to be found. Active first, finished last.
    func goals(in space: UUID?) -> [Goal] {
        let rank: [GoalStatus: Int] = [.active: 0, .paused: 1, .done: 2]
        return goals.filter { goal in
            guard let space else { return true }
            let mine = tasks.filter { $0.goalId == goal.id }
            return mine.isEmpty || mine.contains { $0.projectId == space }
        }
        .sorted { (rank[$0.status] ?? 0, $0.createdAt) < (rank[$1.status] ?? 0, $1.createdAt) }
    }

    func addGoal() -> Goal {
        let goal = Goal()
        goals.append(goal)
        save()
        return goal
    }

    func updateGoal(_ id: UUID, _ change: (inout Goal) -> Void) {
        guard let i = goals.firstIndex(where: { $0.id == id }) else { return }
        var goal = goals[i]
        change(&goal)
        guard goal != goals[i] else { return }
        goals[i] = goal
        save()
    }

    /// Deletes the goal with its notes and links. Its tasks stay on the board, without a goal.
    func delete(goal id: UUID) {
        goals.removeAll { $0.id == id }
        for i in tasks.indices where tasks[i].goalId == id { tasks[i].goalId = nil }
        save()
    }

    /// The board task for a tracker ticket, if there is one, archived ones included.
    func task(project: UUID, ref: String) -> TaskItem? {
        tasks.first { $0.projectId == project && $0.ref.caseInsensitiveCompare(ref) == .orderedSame }
    }

    /// Makes a goal from a tracker's epic (or adds to `goalId`): the epic's link goes in its notes and
    /// links, the chosen children become its tasks. Children already on the board join the goal
    /// where they are, even from another goal; new ones go to the first column, or to the done
    /// column when the tracker says they are finished.
    @discardableResult
    func importEpic(_ epic: EpicTickets, project: Project, children: [EpicTickets.Child], into goalId: UUID?) -> UUID {
        let id: UUID
        if let goalId, let i = goals.firstIndex(where: { $0.id == goalId }) {
            id = goalId
            // The first epic added to a goal made by hand becomes its source, for later updates.
            if goals[i].source == nil {
                goals[i].source = GoalSource(projectId: project.id, ref: epic.ref, url: epic.url)
                goals[i].items.append(GoalItem(kind: .link, title: "\(project.kind.label) \(epic.ref): \(epic.title)", url: epic.url))
            }
        } else {
            var goal = Goal(name: epic.title)
            goal.source = GoalSource(projectId: project.id, ref: epic.ref, url: epic.url)
            goal.items = [GoalItem(kind: .link, title: "\(project.kind.label) \(epic.ref): \(epic.title)", url: epic.url)]
            goals.append(goal)
            id = goal.id
        }
        let done = columns.first { $0.role == .done }?.id ?? defaultColumnId
        for child in children {
            if let i = tasks.firstIndex(where: { $0.projectId == project.id && $0.ref.caseInsensitiveCompare(child.ref) == .orderedSame }) {
                tasks[i].goalId = id
                continue
            }
            var task = TaskItem(projectId: project.id, ref: child.ref, title: child.title, url: child.url,
                                status: child.closed ? done : defaultColumnId,
                                // GitHub's list only says open or closed; the refresh fetches the real state.
                                remoteStatus: project.kind == .github ? nil : child.status, remoteType: child.type)
            task.goalId = id
            task.order = nextOrder
            tasks.append(task)
        }
        save()
        Task { await refreshRemoteStatuses() }
        return id
    }

    func setStanding(_ goalId: UUID, _ text: String?) {
        updateGoal(goalId) {
            $0.standing = text
            $0.standingAt = text == nil ? nil : Date()
        }
    }

    func setStandup(_ spaceId: UUID, _ note: StandupNote) {
        standups[spaceId] = note
        save()
    }

    func setGoal(_ taskId: UUID, _ goalId: UUID?) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }), tasks[i].goalId != goalId else { return }
        tasks[i].goalId = goalId
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

    /// Dock badge: how many things wait for me, or (by choice) the running timer — the time since
    /// the single running timer was started, or how many are running.
    /// Called every second by the ticker and right after a timer starts or stops.
    private func updateDockBadge() {
        forgetCleared()
        let label: String?
        switch notify.badge {
        case .none:
            label = nil
        case .waiting:
            let count = waitingCount
            label = count == 0 ? nil : "\(count)"
        case .timer:
            let running = runningTasks
            switch running.count {
            case 0: label = nil
            // The current stretch only (since the last start), not the task's total.
            case 1: label = Fmt.hm(running[0].entries.last { $0.end == nil }?.duration(now: now) ?? 0)
            default: label = "\(running.count)"
            }
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
            begin(i)
        }
        now = Date()
        updateDockBadge()
        save()
    }

    /// Starts the timer of the task at `i`, and offers to count from earlier when there is a gap.
    private func begin(_ i: Int) {
        // Before anything is stopped or started: afterwards there is no gap left to see.
        let earlier = backdateOptions()
        if singleTimer {
            for k in tasks.indices where tasks[k].isRunning { closeEntries(at: k) }
        }
        let entry = TimeEntry(start: Date())
        tasks[i].entries.append(entry)
        // Starting work on a not-started or done task moves it to the In progress column, if there is one.
        let current = role(of: tasks[i].status)
        if current == .backlog || current == .done,
           let target = columns.first(where: { $0.role == .inProgress }) {
            tasks[i].status = target.id
            tasks[i].noteMove(to: target.id)
            tasks[i].order = nextOrder
        }
        tasks[i].archived = false
        backdateOffer = earlier.isEmpty ? nil
            : BackdateOffer(taskId: tasks[i].id, entryId: entry.id, options: earlier, made: Date())
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

    func setNotes(_ id: UUID, _ notes: [TaskNote]) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].noteList != notes else { return }
        tasks[i].noteList = notes
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
    /// `remember` is false for a code review: somebody else's repository, reviewed once, should not
    /// become the space's own or the one preselected for its next session.
    func addSession(_ session: AgentSession, to id: UUID, repoId: String, claudeHome: String? = nil,
                    githubAccount: String, remember: Bool = true) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].sessions = (tasks[i].sessions ?? []) + [session]
        if remember, let p = projects.firstIndex(where: { $0.id == tasks[i].projectId }) {
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
        await readTranscripts(trees)
        publish(trees)
        if await askGitHub(trees, limit: force ? 40 : 3) { publish(trees) }
        await askPullRequestFeedback(limit: force ? 40 : 3)
    }

    /// Reads reviews and comments on the sessions' open pull requests, a few per refresh and each
    /// at most every five minutes, and announces what is new.
    private func askPullRequestFeedback(limit: Int) async {
        var open: [(url: URL, task: TaskItem, account: String?)] = []
        for task in tasks where !task.archived {
            for session in sessions(of: task) {
                guard let status = status(of: session), status.kind == .prOpen, let url = status.prURL,
                      !open.contains(where: { $0.url == url }) else { continue }
                open.append((url, task, session.githubAccount ?? project(task.projectId)?.githubAccount))
            }
        }
        // Pull requests that are no longer open are forgotten, so the saved list does not grow.
        let pages = Set(open.map(\.url.absoluteString))
        var changed = false
        if sessionStatuses != nil, pullRequestFeedbackSeen.keys.contains(where: { !pages.contains($0) }) {
            pullRequestFeedbackSeen = pullRequestFeedbackSeen.filter { pages.contains($0.key) }
            changed = true
        }
        let due = open.filter { feedbackAsked[$0.url].map { Date().timeIntervalSince($0) >= 300 } ?? true }
        if !due.isEmpty, Date().timeIntervalSince(githubLogins?.at ?? .distantPast) > 3600 {
            githubLogins = (await Orca.githubLogins(), Date())
        }
        for item in due.prefix(limit) {
            feedbackAsked[item.url] = Date()
            // A failed question keeps what was known.
            guard let feedback = await Orca.pullRequestFeedback(item.url, account: item.account,
                                                                mine: githubLogins?.logins ?? []) else { continue }
            pullRequestFeedback[item.url] = feedback
            let key = item.url.absoluteString
            if let seen = pullRequestFeedbackSeen[key] {
                let fresh = feedback.items.filter { $0.at > seen }
                guard let newest = fresh.last else { continue }
                announceFeedback(fresh, on: feedback, task: item.task)
                pullRequestFeedbackSeen[key] = newest.at
            } else {
                pullRequestFeedbackSeen[key] = feedback.items.last?.at ?? .distantPast
            }
            changed = true
        }
        if changed { save() }
    }

    /// Reviews and comments on a session's open pull request, as last read from GitHub.
    func feedback(of session: AgentSession) -> Orca.PullRequestFeedback? {
        status(of: session)?.prURL.flatMap { pullRequestFeedback[$0] }
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
            // Archived tasks too: their worktrees are the ones left to clean up.
            for task in tasks where task.projectId == space.id && !task.ref.isEmpty {
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

    /// Reads what the agent last said from Claude Code's transcript, for the sessions of tasks
    /// that stopped: Orca knows the answer only of agents its own launcher started. Read even
    /// when Orca has the answer: only the transcript says what the agent is waiting for, a
    /// question or something it left running. A file that has not changed is not read again.
    private func readTranscripts(_ trees: [Orca.Worktree]) async {
        let sessions = tasks.filter { !$0.archived }.flatMap(sessions(of:))
        let mine = Set(sessions.compactMap(\.worktreeId))
        let homes = SessionTranscript.homes(Array(Set(sessions.compactMap(\.claudeHome))).sorted())
        var fresh: [String: SessionTranscript.Last] = [:]
        for tree in trees where mine.contains(tree.id) && tree.status.kind != .working {
            fresh[tree.id] = await SessionTranscript.last(worktree: tree.path, homes: homes)
        }
        transcripts = fresh
    }

    /// Turns Orca's answer into the statuses the views read, with GitHub's pull request where Orca has none.
    private func publish(_ trees: [Orca.Worktree]) {
        var fresh: [String: Orca.Status] = [:]
        let slugs = Dictionary(orcaRepos.compactMap { repo in repo.slug.map { (repo.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        for tree in trees {
            var status = tree.status
            if let last = transcripts[tree.id] {
                // Orca's own answer wins where it has one: it is tied to the agent's terminal,
                // while the transcript is found by folder.
                if (status.lastMessage ?? "").isEmpty { status.lastMessage = last.message }
                if status.kind == .yourTurn { status.ask = last.ask }
                status.running = last.running
            }
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

    /// The task's worktrees that can be removed now: Orca answered, the worktree is still there,
    /// and no agent is working in it.
    func removableSessions(of task: TaskItem) -> [AgentSession] {
        sessions(of: task).filter { session in
            guard let id = session.worktreeId, Orca.canRemove(worktreeId: id),
                  let kind = status(of: session)?.kind else { return false }
            return kind != .gone && kind != .working
        }
    }

    /// Worktrees left behind by archived tasks. One that a task still on the board also points
    /// to (the same ticket brought back) is that task's work, so it is left alone.
    var archivedWorktrees: [TaskWorktree] {
        let inUse = Set(tasks.filter { !$0.archived }.flatMap(sessions(of:)).compactMap(\.worktreeId))
        var seen = Set<String>()
        return tasks.filter(\.archived).flatMap { task in
            removableSessions(of: task).compactMap { session -> TaskWorktree? in
                guard let id = session.worktreeId, !inUse.contains(id), seen.insert(id).inserted else { return nil }
                return TaskWorktree(taskId: task.id, session: session)
            }
        }
    }

    /// Removes worktrees in Orca one by one and forgets them here. Returns the ones Orca refused,
    /// usually because of uncommitted changes, with its reason.
    func removeWorktrees(_ items: [TaskWorktree], force: Bool = false) async -> [(item: TaskWorktree, reason: String)] {
        var failures: [(item: TaskWorktree, reason: String)] = []
        for item in items {
            guard let id = item.session.worktreeId, !removingWorktrees.contains(id) else { continue }
            removingWorktrees.insert(id)
            defer { removingWorktrees.remove(id) }
            do {
                try await Orca.removeWorktree(id: id, force: force)
                if let i = tasks.firstIndex(where: { $0.id == item.taskId }) {
                    tasks[i].sessions?.removeAll { $0.worktreeId == id }
                }
                linkedSessions[item.taskId]?.removeAll { $0.worktreeId == id }
                sessionStatuses?[id] = nil
            } catch {
                failures.append((item, error.localizedDescription))
            }
        }
        save()
        await refreshSessionStatuses(force: true)
        return failures
    }

    /// Forgets a session here. The worktree and its branch stay in Orca.
    func removeSession(_ sessionId: UUID, from id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].sessions?.removeAll { $0.id == sessionId }
        save()
    }

    // MARK: Tracker status

    /// Sets the task's own due date; nil goes back to the tracker's, if it has one.
    func setDue(_ id: UUID, _ date: Date?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].dueDate = date.map { Calendar.current.startOfDay(for: $0) }
        save()
    }

    /// Records what the tracker says about a ticket: its status and who it is assigned to.
    func setRemote(_ id: UUID, from detail: TicketDetail) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if let status = detail.status, !status.isEmpty, tasks[i].remoteStatus != status {
            tasks[i].remoteStatus = status
            changed = true
        }
        if let type = detail.kindLabel, !type.isEmpty, tasks[i].remoteType != type {
            tasks[i].remoteType = type
            changed = true
        }
        if detail.tracksEstimate, tasks[i].estimateGap != detail.estimateGap {
            tasks[i].estimateGap = detail.estimateGap
            changed = true
        }
        if tasks[i].remoteDue != Due.day(detail.dueDay) {
            tasks[i].remoteDue = Due.day(detail.dueDay)
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
                received(detail, for: task.id)
            }
        }
    }

    /// A ticket read from its tracker: its status goes on the card, and the whole ticket into the
    /// cache, so the details, the goal report and the standup have its latest description and
    /// comments without another request. The cached edit choices stay: this read does not fetch them.
    func received(_ detail: TicketDetail, for id: UUID) {
        TicketCache.save(.init(detail: detail, options: TicketCache.load(id)?.options), for: id)
        setRemote(id, from: detail)
    }

    /// How many tickets a space refresh reads at once: quicker than one by one, without a burst
    /// a tracker could take for abuse.
    private static let spaceRefreshWidth = 4

    /// Reads every open ticket of a space again, with the agents' state and the tickets assigned
    /// in that tracker, so a standup is written from what the trackers say now. Returns how many
    /// tickets could not be read; those keep their last saved copy.
    func refreshSpace(_ spaceId: UUID) async -> (failed: Int, total: Int) {
        guard let space = project(spaceId) else { return (0, 0) }
        let targets = tasks.filter { $0.projectId == spaceId && !$0.archived && TicketFetcher.canFetch(project: space, task: $0) }
        // The pull requests are known only once the sessions are.
        async let sessions: Void = { await self.refreshSessionStatuses(force: true); await self.refreshPullRequests(space: space) }()
        async let assigned: Void = refreshAssigned(space: space)
        @Sendable func read(_ task: TaskItem) async -> (UUID, TicketDetail?) {
            (task.id, try? await TicketFetcher.fetch(project: space, ref: task.ref, url: task.url))
        }
        var failed = 0
        await withTaskGroup(of: (UUID, TicketDetail?).self) { group in
            var next = 0
            for task in targets.prefix(Self.spaceRefreshWidth) { group.addTask { await read(task) } }
            next = min(Self.spaceRefreshWidth, targets.count)
            for await (id, detail) in group {
                if let detail { received(detail, for: id) } else { failed += 1 }
                if next < targets.count {
                    let task = targets[next]
                    next += 1
                    group.addTask { await read(task) }
                }
            }
        }
        _ = await (sessions, assigned)
        return (failed, targets.count)
    }

    /// The pull request of an agent session, as last read from GitHub for a standup.
    func pullRequest(of session: AgentSession) -> Orca.PullRequestDetail? {
        status(of: session)?.prURL.flatMap { pullRequestDetails[$0] }
    }

    /// Reads the pull requests of a space's agent sessions from GitHub, a few at a time.
    func refreshPullRequests(space: Project) async {
        var due: [(url: URL, account: String?)] = []
        for task in tasks where task.projectId == space.id {
            for session in sessions(of: task) {
                guard let url = status(of: session)?.prURL, !due.contains(where: { $0.url == url }) else { continue }
                if let known = pullRequestDetails[url], known.state != "open" { continue }
                due.append((url, session.githubAccount ?? space.githubAccount))
            }
        }
        await withTaskGroup(of: (URL, Orca.PullRequestDetail?).self) { group in
            var next = 0
            func add() {
                guard next < due.count else { return }
                let item = due[next]
                next += 1
                group.addTask { (item.url, await Orca.pullRequestDetail(item.url, account: item.account)) }
            }
            for _ in 0..<Self.spaceRefreshWidth { add() }
            for await (url, detail) in group {
                // A failed question keeps what was known.
                if let detail { pullRequestDetails[url] = detail }
                add()
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
