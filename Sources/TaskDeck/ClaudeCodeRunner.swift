import Foundation
import AppKit

/// Runs sessions as Claude Code's own background sessions (`claude --bg`), each in a git worktree
/// of its own, and reads their state from `claude agents --json`. Needs no other app.
struct ClaudeCodeRunner: SessionRunner {
    static let id = "claude-code"
    var id: String { Self.id }
    let label = "Claude Code"
    let capabilities: RunnerCapabilities = [.reveal, .removeWorktree, .addRepository]
    let agents: [AgentKind] = [.claude]
    let unavailableHint = "The claude command was not found. Install Claude Code."

    var isAvailable: Bool { ClaudeCode.isInstalled }

    /// Worktree ids start with this, so they never meet Orca's.
    private static let prefix = "claude-code:"

    // MARK: Repositories

    /// The folders added here, and the Claude homes sessions were started with. A file of its own
    /// beside `data.json`: the runner is asked from outside the store, and both lists only grow.
    private struct Saved: Codable {
        var repos: [String] = []
        var homes: [String] = []
    }

    private static var savedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskDeck", isDirectory: true)
            .appendingPathComponent("claude-code.json")
    }

    private static func load() -> Saved {
        guard let data = try? Data(contentsOf: savedURL) else { return Saved() }
        return (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
    }

    private static func remember(repo path: String? = nil, home: String? = nil) {
        var saved = load()
        if let path, !saved.repos.contains(path) { saved.repos.append(path) }
        if let home, !home.isEmpty, !saved.homes.contains(home) { saved.homes.append(home) }
        try? FileManager.default.createDirectory(at: savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: savedURL, options: .atomic) }
    }

    /// The folders added here, plus every repository Orca has: a space moving from Orca keeps its
    /// repositories at hand. Ids are paths, which mean the same thing to every tool.
    func repos() async throws -> [SessionRepo] {
        var byPath: [String: SessionRepo] = [:]
        if OrcaRunner().isAvailable, let orca = try? await OrcaRunner().repos() {
            for repo in orca where FileManager.default.fileExists(atPath: repo.path) {
                byPath[repo.path] = SessionRepo(id: repo.path, name: repo.name, path: repo.path,
                                                owner: repo.owner, slug: repo.slug, runner: Self.id)
            }
        }
        for path in Self.load().repos where byPath[path] == nil && FileManager.default.fileExists(atPath: path) {
            byPath[path] = await Self.repo(at: path)
        }
        return byPath.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func addRepository(path: String) async throws -> SessionRepo {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolFailure.failed("\(path) is not a folder on this Mac.")
        }
        Self.remember(repo: resolved)
        return await Self.repo(at: resolved)
    }

    /// A folder as a repository, with its GitHub name read from the origin remote.
    private static func repo(at path: String) async -> SessionRepo {
        let reply = try? await Shell.run("/usr/bin/git", ["-C", path, "remote", "get-url", "origin"], timeout: 10)
        let remote = reply.flatMap { $0.status == 0 ? String(data: $0.out, encoding: .utf8) : nil }
        let slug = remote.flatMap(GitHub.slug)
        return SessionRepo(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                           owner: slug.flatMap { $0.split(separator: "/").first.map(String.init) }, slug: slug,
                           runner: Self.id)
    }

    // MARK: Sessions

    func start(_ launch: SessionLaunch) async throws -> AgentSession {
        guard let claude = ClaudeCode.executable else { throw ToolFailure.failed(unavailableHint) }
        let home = launch.home.trimmingCharacters(in: .whitespaces)
        let account = launch.githubAccount.trimmingCharacters(in: .whitespaces)
        let environment = try ClaudeCode.environment(home: home)
        let worktree = (launch.repo.path as NSString).appendingPathComponent(".claude/worktrees/\(launch.name)")
        // Checked before anything is made: without a token gh would answer as another account.
        let accountSettings = account.isEmpty ? nil : try await Self.githubSettings(account: account)

        var args = ["--bg", "--name", launch.name]
        let directory: String
        if let base = launch.baseBranch {
            // `--worktree` always starts from the repository's own branch, so a checkout of
            // something else (a pull request under review) is made here first.
            try await Self.addWorktree(repo: launch.repo.path, path: worktree, branch: launch.name, from: base)
            directory = worktree
        } else {
            args += ["--worktree", launch.name]
            directory = launch.repo.path
        }
        if launch.unattended { args += ["--permission-mode", "bypassPermissions"] }
        if let accountSettings { args += ["--settings", accountSettings] }
        args.append(launch.prompt)

        let reply = try await Shell.run(claude, args, environment: environment, directory: URL(fileURLWithPath: directory), timeout: 60)
        let output = String(data: reply.out + reply.err, encoding: .utf8) ?? ""
        // "backgrounded · 2a3a03e3 · name"
        guard reply.status == 0, let short = output.firstMatch(of: #/backgrounded\s*·\s*([0-9a-f]+)/#)?.1 else {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolFailure.failed(message.isEmpty ? Shell.message(reply, tool: "claude") : String(message.prefix(400)))
        }
        Self.remember(repo: launch.repo.path, home: home)
        let resolvedHome = home.isEmpty ? nil : Sessions.resolvedHome(home)
        return AgentSession(worktreeId: Self.worktreeId(short: String(short), home: resolvedHome), path: worktree,
                            name: launch.name, repoName: launch.repo.name, agent: AgentKind.claude.id,
                            claudeHome: home.isEmpty ? nil : home, githubAccount: account.isEmpty ? nil : account,
                            runner: Self.id)
    }

    /// Settings that make the session's gh commands run as `account`. Not an environment variable:
    /// `claude --bg` hands the session to a background service, which keeps the environment it
    /// was started with. A SessionStart hook adds a line to the session's environment file instead,
    /// and that line asks gh's keyring for the token each time a command runs, so the token is
    /// never written to disk (the file is kept and readable by other users) or seen by this app.
    private static func githubSettings(account: String) async throws -> String {
        guard let gh = GitHub.executable else {
            throw ToolFailure.failed("The gh command was not found, and the GitHub account is set with it.")
        }
        // GitHub logins are letters, digits and hyphens; anything else would break the quoting below.
        guard account.wholeMatch(of: #/[A-Za-z0-9-]+/#) != nil else {
            throw ToolFailure.failed("“\(account)” is not a GitHub login.")
        }
        // The token's presence only: the shell drops it, so this app never holds it.
        let check = try await Shell.run("/bin/sh", ["-c", "\"$0\" auth token --user \"$1\" >/dev/null 2>&1", gh, account], timeout: 30)
        guard check.status == 0 else {
            throw ToolFailure.failed("gh has no token for \(account). Run “gh auth login” in a terminal.")
        }
        let line = "export GH_TOKEN=\"$(\(gh) auth token --user \(account))\""
        let command = "echo '\(line)' >> \"$CLAUDE_ENV_FILE\""
        let settings: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": command]]]]]]
        let data = try JSONSerialization.data(withJSONObject: settings)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func addWorktree(repo: String, path: String, branch: String, from base: String) async throws {
        let reply = try await Shell.run("/usr/bin/git", ["-C", repo, "worktree", "add", "-b", branch, path, base])
        guard reply.status == 0 else {
            throw ToolFailure.failed("The checkout could not be made: " + Shell.message(reply, tool: "git"))
        }
    }

    /// "claude-code:<short id>", plus "@<home>" for a session of another Claude home: every
    /// command about it has to run as that home.
    private static func worktreeId(short: String, home: String?) -> String {
        guard let home, !ClaudeCode.isStandardHome(home) else { return prefix + short }
        return prefix + short + "@" + home
    }

    /// The short id and Claude home in a worktree id. Nil unless the short id is what Claude Code
    /// prints (hex): it ends up in a shell line, and nothing else may get that far.
    static func parse(_ worktreeId: String) -> (short: String, home: String)? {
        guard worktreeId.hasPrefix(prefix) else { return nil }
        let rest = worktreeId.dropFirst(prefix.count)
        let short: Substring, home: Substring
        if let at = rest.firstIndex(of: "@") {
            short = rest[..<at]
            home = rest[rest.index(after: at)...]
        } else {
            short = rest
            home = ""
        }
        guard !short.isEmpty, short.count <= 64, short.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return (String(short), String(home))
    }

    func canRemove(worktreeId: String) -> Bool { Self.parse(worktreeId) != nil }

    /// `claude rm`: the session leaves the list and its worktree goes. It refuses a worktree with
    /// work that is not pushed and names what to pass to remove it anyway; `force` passes that.
    func removeWorktree(id: String, force: Bool) async throws {
        guard let claude = ClaudeCode.executable else { throw ToolFailure.failed(unavailableHint) }
        guard let (short, home) = Self.parse(id) else { throw ToolFailure.failed("Not a Claude Code session.") }
        let environment = try ClaudeCode.environment(home: home)
        // Read before it goes: `claude rm` deletes only worktrees Claude Code made itself.
        let folder = await Self.folder(of: short, claude: claude, environment: environment)
        var reply = try await Shell.run(claude, ["rm", short], environment: environment, timeout: 60)
        var output = String(data: reply.out + reply.err, encoding: .utf8) ?? ""
        if reply.status != 0 || output.contains("--discard-unpushed") || output.contains("--force-remove-worktree") {
            guard force else { throw ToolFailure.failed(Self.plain(output, reply)) }
            var extra: [String] = []
            if let value = output.firstMatch(of: #/--discard-unpushed\s+(\S+)/#)?.1 { extra += ["--discard-unpushed", String(value)] }
            if let value = output.firstMatch(of: #/--force-remove-worktree\s+(\S+)/#)?.1 { extra += ["--force-remove-worktree", String(value)] }
            reply = try await Shell.run(claude, ["rm", short] + extra, environment: environment, timeout: 60)
            output = String(data: reply.out + reply.err, encoding: .utf8) ?? ""
            guard reply.status == 0 else { throw ToolFailure.failed(Self.plain(output, reply)) }
        }
        if let folder { try await Self.removeOwnCheckout(folder, force: force) }
    }

    /// The folder a session runs in, from Claude Code's own list.
    private static func folder(of short: String, claude: String, environment: [String: String]) async -> String? {
        guard let reply = try? await Shell.run(claude, ["agents", "--json", "--all"], environment: environment, timeout: 30),
              let rows = (try? JSONSerialization.jsonObject(with: reply.out)) as? [[String: Any]] else { return nil }
        return rows.first { $0["id"] as? String == short }?["cwd"] as? String
    }

    /// A checkout this app made for a session (one started from a pull request) is still there
    /// after `claude rm`. Only one inside a repository's ".claude/worktrees" is touched; git
    /// refuses one with uncommitted changes unless `force`. Its branch goes only if it is merged.
    private static func removeOwnCheckout(_ folder: String, force: Bool) async throws {
        let marker = "/.claude/worktrees/"
        guard let range = folder.range(of: marker), FileManager.default.fileExists(atPath: folder) else { return }
        let repo = String(folder[..<range.lowerBound])
        let branchReply = try? await Shell.run("/usr/bin/git", ["-C", folder, "branch", "--show-current"], timeout: 10)
        let branch = branchReply.flatMap { String(data: $0.out, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reply = try await Shell.run("/usr/bin/git", ["-C", repo, "worktree", "remove"] + (force ? ["--force"] : []) + [folder])
        guard reply.status == 0 else {
            throw ToolFailure.failed("The session is gone, but its checkout was kept: " + Shell.message(reply, tool: "git"))
        }
        if !branch.isEmpty { _ = try? await Shell.run("/usr/bin/git", ["-C", repo, "branch", "-d", branch], timeout: 10) }
    }

    private static func plain(_ output: String, _ reply: Shell.Result) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Shell.message(reply, tool: "claude") : String(text.prefix(400))
    }

    /// Opens the session in a terminal window with `claude attach`. The window shows the session
    /// as it runs; closing it leaves the session running.
    func reveal(_ session: AgentSession) async {
        guard let worktreeId = session.worktreeId, let (short, home) = Self.parse(worktreeId),
              let claude = ClaudeCode.executable else { return }
        var lines = ["#!/bin/zsh -l"]
        if !home.isEmpty { lines.append("export CLAUDE_CONFIG_DIR=\(Sessions.shellQuoted(home))") }
        lines.append("exec \(Sessions.shellQuoted(claude)) attach \(Sessions.shellQuoted(short))")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("taskdeck-attach-\(short).command")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return
        }
        _ = await MainActor.run { NSWorkspace.shared.open(file) }
    }

    func screen(of tree: SessionWorktree, savedHandle: String?) async -> String? { nil }

    // MARK: Status

    /// Every background session of the default Claude home and of the homes sessions were started
    /// with. Fails only when the default home cannot be asked, so one broken home hides only its own.
    func worktrees() async throws -> [SessionWorktree] {
        guard let claude = ClaudeCode.executable else { throw ToolFailure.failed(unavailableHint) }
        let homes = [""] + Array(Set(Self.load().homes.compactMap(Sessions.resolvedHome)))
            .filter { !ClaudeCode.isStandardHome($0) }.sorted()
        var out: [SessionWorktree] = []
        for home in homes {
            guard let environment = try? ClaudeCode.environment(home: home) else { continue }
            let reply = try await Shell.run(claude, ["agents", "--json", "--all"], environment: environment, timeout: 30)
            guard reply.status == 0, let rows = (try? JSONSerialization.jsonObject(with: reply.out)) as? [[String: Any]] else {
                if home.isEmpty { throw ToolFailure.failed(Shell.message(reply, tool: "claude")) }
                continue
            }
            for row in rows where row["kind"] as? String == "background" {
                guard let short = row["id"] as? String, let cwd = row["cwd"] as? String else { continue }
                out.append(await Self.worktree(row, short: short, cwd: cwd, home: home.isEmpty ? nil : home))
            }
        }
        return out
    }

    private static func worktree(_ row: [String: Any], short: String, cwd: String, home: String?) async -> SessionWorktree {
        // Its own worktrees sit in "<repository>/.claude/worktrees/<name>".
        let marker = "/.claude/worktrees/"
        let repo = cwd.range(of: marker).map { String(cwd[..<$0.lowerBound]) } ?? cwd
        let name = row["name"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent
        var branch = ""
        if FileManager.default.fileExists(atPath: cwd),
           let reply = try? await Shell.run("/usr/bin/git", ["-C", cwd, "branch", "--show-current"], timeout: 10), reply.status == 0 {
            branch = String(data: reply.out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let created = (row["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return SessionWorktree(id: worktreeId(short: short, home: home), repoId: repo,
                               repoName: URL(fileURLWithPath: repo).lastPathComponent, name: name, branch: branch,
                               path: cwd, isMain: cwd == repo, createdAt: created, status: status(of: row),
                               agentPane: nil, lastPrompt: nil, runner: Self.id)
    }

    /// `state` is working, blocked, done, failed or stopped; `status` is busy, waiting or idle.
    private static func status(of row: [String: Any]) -> SessionStatus {
        let state = row["state"] as? String
        let status = row["status"] as? String
        if state == "blocked" || status == "waiting" {
            return SessionStatus(kind: .yourTurn, ask: row["waitingFor"] as? String)
        }
        if state == "working" || status == "busy" { return SessionStatus(kind: .working) }
        return SessionStatus(kind: .idle)
    }
}
