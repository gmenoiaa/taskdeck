import Foundation
import AppKit

/// Runs sessions in Orca, through its command-line tool. Every call asks for JSON and runs off the main thread.
struct OrcaRunner: SessionRunner {
    static let id = "orca"
    var id: String { Self.id }
    let label = "Orca"
    let capabilities: RunnerCapabilities = [.screen, .reveal, .removeWorktree, .addRepository]
    /// Orca knows more ids; these are the two it manages accounts for.
    let agents: [AgentKind] = [.claude, .codex]
    let unavailableHint = "The orca command was not found. Install it from Orca's settings (it goes in /usr/local/bin)."

    /// An app started from the Dock has a short PATH, so the usual install places are checked directly.
    private static var executable: String? {
        Shell.find("orca", also: ["/Applications/Orca.app/Contents/Resources/bin/orca"])
    }

    var isAvailable: Bool { Self.executable != nil }

    // MARK: Repositories

    func repos() async throws -> [SessionRepo] {
        let result = try await Self.run(["repo", "list"])
        let rows = result["repos"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let path = row["path"] as? String else { return nil }
            let name = (row["displayName"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
            // "github.com/owner/name", as Orca records the remote.
            let remote = ((row["gitRemoteIdentity"] as? [String: Any])?["canonicalKey"] as? String ?? "")
                .split(separator: "/")
            let onGitHub = remote.count >= 3 && remote[0] == "github.com"
            return SessionRepo(id: id, name: name, path: path, owner: remote.count >= 3 ? String(remote[1]) : nil,
                               slug: onGitHub ? remote[1...].joined(separator: "/") : nil, runner: Self.id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func addRepository(path: String) async throws -> SessionRepo {
        _ = try await Self.run(["repo", "add", "--path", path])
        // The answer's shape is not relied on; the list is, as everywhere else.
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let repo = try await repos().first(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == wanted
        }) else {
            throw ToolFailure.failed("Orca added \(path) but does not list it.")
        }
        return repo
    }

    // MARK: Sessions

    /// Creates a new checkout of the repository, starts the agent in it and sends the prompt.
    func start(_ launch: SessionLaunch) async throws -> AgentSession {
        let agent = launch.agent
        let home = agent.homeVariable == nil ? "" : launch.home.trimmingCharacters(in: .whitespaces)
        let account = launch.githubAccount.trimmingCharacters(in: .whitespaces)
        // Orca's launcher takes no flags either, so a session that must not stop to ask is typed too.
        let unattended = launch.unattended && agent.unattendedFlag != nil
        let customLaunch = !home.isEmpty || !account.isEmpty || unattended

        var args = ["worktree", "create", "--repo", "id:\(launch.repo.id)", "--name", launch.name, "--no-parent"]
        // Orca's own launcher cannot set environment variables, so when the session needs any the
        // worktree is created without an agent and the agent is started in a terminal below.
        if !customLaunch { args += ["--agent", agent.id, "--prompt", launch.prompt] }
        if !launch.comment.isEmpty { args += ["--comment", launch.comment] }
        if let baseBranch = launch.baseBranch { args += ["--base-branch", baseBranch] }
        let result = try await Self.run(args)
        // The shape of this result differs between Orca versions, so each value is looked up by key
        // wherever it sits rather than at a fixed path.
        let worktree = (result["worktree"] as? [String: Any]) ?? result
        var session = AgentSession(
            worktreeId: (worktree["id"] as? String) ?? (worktree["worktreeId"] as? String),
            path: worktree["path"] as? String,
            terminalHandle: (result["agentTerminalHandle"] as? String)
                ?? ((result["startupTerminal"] as? [String: Any])?["handle"] as? String),
            name: launch.name, repoName: launch.repo.name, agent: agent.id, runner: Self.id)
        guard customLaunch else { return session }

        guard let path = session.path else {
            throw ToolFailure.failed("Orca created the worktree but did not say where, so the agent was not started in it.")
        }
        let command = try agent.launchLine(home: home, account: account, prompt: launch.prompt, unattended: unattended)
        let terminal = try await Self.run(["terminal", "create", "--worktree", "path:\(path)",
                                           "--title", agent.label, "--command", command])
        session.terminalHandle = Self.firstString("handle", in: terminal) ?? session.terminalHandle
        session.claudeHome = home.isEmpty ? nil : home
        session.githubAccount = account.isEmpty ? nil : account
        return session
    }

    /// Deletes a worktree's checkout and takes it out of Orca. Without `force` git refuses a
    /// checkout with uncommitted changes, so nothing that is not saved somewhere else goes with
    /// it. `force` deletes those changes too. Either way Orca keeps any branch it cannot prove
    /// is merged: `--force` does not reach the branch.
    func removeWorktree(id: String, force: Bool) async throws {
        _ = try await Self.run(["worktree", "rm", "--worktree", "id:\(id)"] + (force ? ["--force"] : []))
    }

    /// A folder added to Orca as a workspace is somebody's own directory, not a checkout made for one ticket.
    func canRemove(worktreeId: String) -> Bool {
        !worktreeId.hasPrefix("folder:") && worktreeId.contains("::")
    }

    /// Brings Orca to the front on the session's agent terminal. If the terminal is gone (closed, or
    /// Orca was restarted), Orca still comes forward so the user can find the worktree by name.
    func reveal(_ session: AgentSession) async {
        // The handle saved at start is only good until Orca restarts: it then gives every
        // terminal a new one, and switching to the old one does nothing. So the worktree's live
        // terminals are asked for each time.
        var handle: String?
        // By the worktree's id where it is known: several of Orca's workspaces can sit on one
        // folder, and the path then names none of them (no terminals come back) or another one.
        let selector = session.worktreeId.map { "id:\($0)" } ?? session.path.map { "path:\($0)" }
        if let selector,
           let answer = try? await Self.run(["terminal", "list", "--worktree", selector]) {
            let live = Self.terminals(in: answer)
            handle = live.first { $0["handle"] as? String == session.terminalHandle }?["handle"] as? String
                // The agent's terminal rather than a plain shell opened beside it.
                ?? live.filter { $0["agentIdentity"] is String }
                    .max { ($0["lastOutputAt"] as? Double ?? 0) < ($1["lastOutputAt"] as? Double ?? 0) }?["handle"] as? String
                ?? live.max { ($0["lastOutputAt"] as? Double ?? 0) < ($1["lastOutputAt"] as? Double ?? 0) }?["handle"] as? String
        } else {
            handle = session.terminalHandle
        }
        if let handle {
            _ = try? await Self.run(["terminal", "switch", "--terminal", handle])
        }
        await MainActor.run {
            let url = URL(fileURLWithPath: "/Applications/Orca.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Status

    func worktrees() async throws -> [SessionWorktree] {
        // Far above any real number of worktrees, so the list is never cut short.
        let result = try await Self.run(["worktree", "ps", "--limit", "2000"])
        let rows = result["worktrees"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["worktreeId"] as? String, let repoId = row["repoId"] as? String,
                  let path = row["path"] as? String else { return nil }
            let branch = (row["branch"] as? String ?? "").replacingOccurrences(of: "refs/heads/", with: "")
            // Orca gives times in milliseconds.
            let created = (row["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let agents = row["agents"] as? [[String: Any]] ?? []
            let latest = agents.max { ($0["updatedAt"] as? Double ?? 0) < ($1["updatedAt"] as? Double ?? 0) }
            let prompt = (latest?["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SessionWorktree(id: id, repoId: repoId, repoName: row["repo"] as? String ?? "",
                                   name: row["displayName"] as? String ?? URL(fileURLWithPath: path).lastPathComponent,
                                   branch: branch, path: path, isMain: row["isMainWorktree"] as? Bool ?? false,
                                   createdAt: created, status: Self.status(of: row),
                                   agentPane: latest?["paneKey"] as? String,
                                   lastPrompt: (prompt ?? "").isEmpty ? nil : prompt, runner: Self.id)
        }
    }

    /// What the agent's terminal shows right now: one screen, as rendered. Nil when the agent's
    /// terminal cannot be told apart from a plain shell opened beside it: a shell may show
    /// anything, and this text is sent on to the review.
    func screen(of tree: SessionWorktree, savedHandle: String?) async -> String? {
        guard let answer = try? await Self.run(["terminal", "list", "--worktree", "id:\(tree.id)"]) else { return nil }
        let live = Self.terminals(in: answer)
        func pane(_ terminal: [String: Any]) -> String? {
            guard let tab = terminal["tabId"] as? String, let leaf = terminal["leafId"] as? String else { return nil }
            return "\(tab):\(leaf)"
        }
        let found = live.first { tree.agentPane != nil && pane($0) == tree.agentPane }
            ?? live.first { savedHandle != nil && $0["handle"] as? String == savedHandle }
            ?? live.filter { $0["agentIdentity"] is String }
                .max { ($0["lastOutputAt"] as? Double ?? 0) < ($1["lastOutputAt"] as? Double ?? 0) }
        guard let handle = found?["handle"] as? String,
              let read = try? await Self.run(["terminal", "read", "--terminal", handle, "--screen"]),
              let terminal = read["terminal"] as? [String: Any],
              // A screen that could not be rendered comes back as raw output, which is unreadable
              // for a program that repaints its lines.
              terminal["source"] as? String != "screen-unavailable",
              let rows = terminal["tail"] as? [String] else { return nil }
        let rule = CharacterSet(charactersIn: "─━═-_ ")
        let lines = rows.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty && !$0.unicodeScalars.allSatisfy(rule.contains) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func status(of row: [String: Any]) -> SessionStatus {
        let agents = row["agents"] as? [[String: Any]] ?? []
        let pr = row["linkedPR"] as? [String: Any]
        let prNumber = pr?["number"] as? Int

        // Orca lists an agent only when its own launcher started it. An agent started by a typed
        // command (a session with a Claude home or GitHub account) has no entry, so the worktree's
        // own status and unread mark are read as well.
        let busy = agents.first { $0["state"] as? String == "working" }
        if busy != nil || row["status"] as? String == "working" {
            return SessionStatus(kind: .working, tool: busy?["toolName"] as? String, prNumber: prNumber)
        }
        let latest = agents.max { ($0["updatedAt"] as? Double ?? 0) < ($1["updatedAt"] as? Double ?? 0) }
        let message = (latest?["lastAssistantMessage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A worktree that stopped is waiting for an answer until the user has looked at it in Orca.
        // Any agent state other than "done" (a question, a permission prompt) also needs the user.
        let stoppedUnseen = row["unread"] as? Bool == true
        let needsUser = latest.map { ($0["state"] as? String ?? "done") != "done" } ?? false
        if stoppedUnseen || needsUser {
            return SessionStatus(kind: .yourTurn, lastMessage: message, prNumber: prNumber)
        }
        let kind: SessionStatus.Kind
        // Orca reports a draft as a state of its own; it is an open pull request all the same.
        let draft = pr?["state"] as? String == "draft"
        switch pr?["state"] as? String {
        case "open", "draft": kind = .prOpen
        case "merged": kind = .prMerged
        case "closed": kind = .prClosed
        default: kind = .idle
        }
        return SessionStatus(kind: kind, lastMessage: message, prNumber: prNumber, prDraft: draft)
    }

    // MARK: Running the command

    /// Runs `orca <args> --json` and returns the `result` object of its reply.
    private static func run(_ args: [String]) async throws -> [String: Any] {
        guard let executable else {
            throw ToolFailure.failed("The orca command was not found. Install it from Orca's settings (it goes in /usr/local/bin).")
        }
        // Creating a worktree is the slowest thing asked of Orca, and it takes seconds; the
        // shared runner's limit is far above that.
        let result = try await Shell.run(executable, args + ["--json"])
        let reply = (try? JSONSerialization.jsonObject(with: result.out)) as? [String: Any]
        if let reply, reply["ok"] as? Bool == true {
            return reply["result"] as? [String: Any] ?? [:]
        }
        if let error = reply?["error"] as? [String: Any], let text = error["message"] as? String { throw ToolFailure.failed(text) }
        if let text = reply?["error"] as? String { throw ToolFailure.failed(text) }
        throw ToolFailure.failed(Shell.message(result, tool: "orca"))
    }

    /// The first string stored under `key` anywhere in a JSON value.
    private static func firstString(_ key: String, in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let found = object[key] as? String { return found }
            for child in object.values {
                if let found = firstString(key, in: child) { return found }
            }
        } else if let list = value as? [Any] {
            for child in list {
                if let found = firstString(key, in: child) { return found }
            }
        }
        return nil
    }

    /// The terminal entries of a `terminal list` answer, wherever the list sits in it.
    private static func terminals(in value: Any) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            if let list = object["terminals"] as? [[String: Any]] { return list }
            for child in object.values {
                let found = terminals(in: child)
                if !found.isEmpty { return found }
            }
        }
        return []
    }
}
