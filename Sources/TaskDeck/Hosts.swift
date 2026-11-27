import Foundation

/// A session as its Mac tells the others about it: enough to show it on their boards, nothing to
/// act on it with. Paths, terminals and Claude homes stay on the Mac that runs it.
struct PublishedSession: Codable, Equatable {
    var id: UUID
    var name: String
    var repoName: String
    var agent: String
    var runner: String?
    var startedAt: Date
    var kind: SessionStatus.Kind
    var tool: String?
    var lastMessage: String?
    var ask: String?
    var prNumber: Int?
    var prDraft: Bool?
    var prURL: URL?

    init(_ session: AgentSession, status: SessionStatus?) {
        id = session.id
        name = session.name
        repoName = session.repoName
        agent = session.agent
        runner = session.runner
        startedAt = session.startedAt
        kind = status?.kind ?? .idle
        tool = status?.tool
        lastMessage = status?.lastMessage.map { String($0.prefix(4000)) }
        ask = status?.ask.map { String($0.prefix(1000)) }
        prNumber = status?.prNumber
        prDraft = status?.prDraft
        prURL = status?.prURL
    }

    /// The session as the other Mac's board shows it: marked with its host, so nothing here tries
    /// to open or remove it. The worktree id is made up and unique, for the views that key on it.
    func session(host: String) -> AgentSession {
        AgentSession(id: id, worktreeId: "remote:\(host):\(id.uuidString)", name: name, repoName: repoName,
                     agent: agent, startedAt: startedAt, runner: runner, host: host)
    }

    var status: SessionStatus {
        SessionStatus(kind: kind, tool: tool, lastMessage: lastMessage, ask: ask, prNumber: prNumber,
                      prDraft: prDraft ?? false, prURL: prURL)
    }
}

/// What one Mac publishes about itself through sync, as the record "host:<Machine.id>". Only that
/// Mac writes it, so two Macs never change the same record.
struct HostState: Codable, Equatable {
    var name: String
    /// By task id.
    var sessions: [String: [PublishedSession]] = [:]
}

extension AppStore {
    /// The Mac's name for people: "This Mac" for this one, else what it published.
    func hostName(_ id: String?) -> String {
        guard let id, id != Machine.id else { return "This Mac" }
        return hosts[id]?.name ?? "another Mac"
    }

    /// This Mac and the other Macs that have published, this Mac first.
    var knownHosts: [(id: String, name: String)] {
        [(Machine.id, "This Mac")] + hosts.sorted { $0.value.name < $1.value.name }.map { ($0.key, $0.value.name) }
    }

    /// This Mac's own sessions with their status, as the other Macs should see them.
    func currentHostState() -> HostState {
        var state = HostState(name: machineName)
        for task in tasks where !task.archived {
            let local = sessions(of: task).filter { !$0.isRemote }
            guard !local.isEmpty else { continue }
            state.sessions[task.id.uuidString] = local.map { PublishedSession($0, status: status(of: $0)) }
        }
        return state
    }

    /// Saves when what this Mac publishes changed, so the next sync carries it. Only while sync is
    /// on: with nothing to send it to, a status that changes every few seconds is not worth a save.
    func publishHostState() {
        guard syncEnabled else { return }
        let state = currentHostState()
        guard state != publishedHost else { return }
        publishedHost = state
        save()
    }
}
