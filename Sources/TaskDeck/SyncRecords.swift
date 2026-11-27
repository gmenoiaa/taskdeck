import Foundation

/// The settings that follow the user from Mac to Mac, saved as one record. Everything else in
/// the snapshot's settings belongs to one Mac: its folders, its Claude homes, its window layout.
struct SyncedSettings: Codable, Equatable {
    var singleTimer: Bool?
    var claudeModel: String?
    var aiInstructions: String?
    var autoLogComment: Bool?
    var notify: NotificationSettings?
    var codeReviewPrompt: String?
    var clearedWaiting: [String]?
    var ignoredAssigned: [String]?
    var sessionAgent: String?
    /// The Mac queued tasks run on; nil for the Mac they were queued on.
    var queueHost: String?
}

extension Project {
    /// The space as it follows the user: without the fields that name things on one Mac.
    var synced: Project {
        var copy = self
        copy.orcaRepoId = nil
        copy.orcaRepoIds = nil
        copy.runnerRepoIds = nil
        copy.claudeHome = nil
        copy.githubAccount = nil
        copy.sessionRunner = nil
        copy.browser = nil
        copy.browserProfile = nil
        return copy
    }

    /// A space that came from the other copy, with this Mac's own fields from `local`, or none
    /// when this Mac has no such space yet: they are never taken from the other copy, which could
    /// otherwise point this Mac at a folder, a Claude home or a browser of its choosing.
    func keepingMachineFields(of local: Project?) -> Project {
        guard let local else { return synced }
        var copy = self
        copy.orcaRepoId = local.orcaRepoId
        copy.orcaRepoIds = local.orcaRepoIds
        copy.runnerRepoIds = local.runnerRepoIds
        copy.claudeHome = local.claudeHome
        copy.githubAccount = local.githubAccount
        copy.sessionRunner = local.sessionRunner
        copy.browser = local.browser
        copy.browserProfile = local.browserProfile
        return copy
    }
}

extension TaskItem {
    /// The task as it follows the user. Agent sessions live in one Mac's folders, and so does the
    /// repository picked for a queued task.
    var synced: TaskItem {
        var copy = self
        copy.sessions = nil
        copy.queueRepoId = nil
        return copy
    }

    /// As for spaces: a task new to this Mac starts with no agent sessions here, whatever the
    /// other copy says. A session names a worktree that this Mac opens in a terminal.
    func keepingMachineFields(of local: TaskItem?) -> TaskItem {
        guard let local else { return synced }
        var copy = self
        copy.sessions = local.sessions
        copy.queueRepoId = local.queueRepoId
        return copy
    }
}

extension AppStore.Snapshot {
    /// One encoder for comparing and storing records: the same value always gives the same bytes.
    static let recordEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let recordDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var settings: SyncedSettings {
        SyncedSettings(singleTimer: singleTimer, claudeModel: claudeModel, aiInstructions: aiInstructions,
                       autoLogComment: autoLogComment, notify: notify, codeReviewPrompt: codeReviewPrompt,
                       clearedWaiting: clearedWaiting, ignoredAssigned: ignoredAssigned, sessionAgent: sessionAgent,
                       queueHost: queueHost)
    }

    /// Every record that follows the user, by key: "task:<id>", "space:<id>", "goal:<id>",
    /// "standup:<space id>", "columns" and "settings".
    func syncRecords() -> [String: Data] {
        var out: [String: Data] = [:]
        func put<Value: Encodable>(_ key: String, _ value: Value) {
            if let data = try? Self.recordEncoder.encode(value) { out[key] = data }
        }
        for task in tasks { put("task:\(task.id.uuidString)", task.synced) }
        for space in projects { put("space:\(space.id.uuidString)", space.synced) }
        for goal in goals ?? [] { put("goal:\(goal.id.uuidString)", goal) }
        for (space, note) in standups ?? [:] { put("standup:\(space)", note) }
        put("columns", columns ?? [])
        put("settings", settings)
        for (host, state) in hosts ?? [:] { put("host:\(host)", state) }
        return out
    }

    func document() -> SyncDocument {
        SyncDocument(schema: schema ?? SyncSchema.current, records: syncRecords(), meta: sync ?? SyncMeta())
    }

    /// This snapshot with `merged` in place of its own records. This Mac's own fields stay: on
    /// the spaces and tasks it already had, and in the settings that are not synced. Records new
    /// to this Mac go after the ones it had, so its own order does not change.
    func applying(_ merged: SyncDocument) throws -> AppStore.Snapshot {
        var out = self
        func values<Value: Decodable>(_ prefix: String, as type: Value.Type) throws -> [(String, Value)] {
            try merged.records.filter { $0.key.hasPrefix(prefix) }
                .map { (String($0.key.dropFirst(prefix.count)), try Self.recordDecoder.decode(Value.self, from: $0.value)) }
        }

        let localTasks = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mergedTasks = try values("task:", as: TaskItem.self).map { $0.1.keepingMachineFields(of: localTasks[$0.1.id]) }
        out.tasks = Self.ordered(mergedTasks, like: tasks.map(\.id), newBy: { $0.createdAt < $1.createdAt })

        let localSpaces = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mergedSpaces = try values("space:", as: Project.self).map { $0.1.keepingMachineFields(of: localSpaces[$0.1.id]) }
        out.projects = Self.ordered(mergedSpaces, like: projects.map(\.id),
                                    newBy: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })

        let mergedGoals = try values("goal:", as: Goal.self).map(\.1)
        let goalList = Self.ordered(mergedGoals, like: (goals ?? []).map(\.id), newBy: { $0.createdAt < $1.createdAt })
        out.goals = goalList.isEmpty ? nil : goalList

        let notes = Dictionary(try values("standup:", as: StandupNote.self), uniquingKeysWith: { first, _ in first })
        out.standups = notes.isEmpty ? nil : notes

        // Every Mac's published sessions, except this Mac's own: only this Mac says what runs here.
        var hostStates = try Dictionary(values("host:", as: HostState.self), uniquingKeysWith: { first, _ in first })
        hostStates[Machine.id] = hosts?[Machine.id]
        out.hosts = hostStates.isEmpty ? nil : hostStates

        if let data = merged.records["columns"] {
            let list = try Self.recordDecoder.decode([BoardColumn].self, from: data)
            out.columns = list.isEmpty ? nil : list
        }
        if let data = merged.records["settings"] {
            let s = try Self.recordDecoder.decode(SyncedSettings.self, from: data)
            out.singleTimer = s.singleTimer
            out.claudeModel = s.claudeModel
            out.aiInstructions = s.aiInstructions
            out.autoLogComment = s.autoLogComment
            out.notify = s.notify
            out.codeReviewPrompt = s.codeReviewPrompt
            out.clearedWaiting = s.clearedWaiting
            out.ignoredAssigned = s.ignoredAssigned
            out.sessionAgent = s.sessionAgent
            out.queueHost = s.queueHost
        }
        out.schema = merged.schema
        out.sync = merged.meta
        return out
    }

    /// `items` in the order of `known`, then the ones `known` does not have, sorted by `newBy`.
    private static func ordered<Item: Identifiable>(_ items: [Item], like known: [Item.ID],
                                                    newBy: (Item, Item) -> Bool) -> [Item] where Item.ID: Hashable {
        let position = Dictionary(known.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let old = items.filter { position[$0.id] != nil }.sorted { position[$0.id]! < position[$1.id]! }
        let new = items.filter { position[$0.id] == nil }.sorted(by: newBy)
        return old + new
    }
}
