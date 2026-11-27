import Foundation

/// Asks GitHub about repositories and pull requests through the `gh` command, and clones with it.
/// Nothing here depends on which tool runs the agent sessions.
enum GitHub {
    struct PullRequest: Hashable {
        let number: Int
        /// "open", "merged" or "closed".
        let state: String
        var draft = false
    }

    struct PullRequestDetail: Hashable {
        let number: Int
        let title: String
        /// The description as written, Markdown and all.
        let body: String
        /// "open", "merged" or "closed".
        let state: String
        let draft: Bool
        let createdAt: Date?
        let mergedAt: Date?
        let closedAt: Date?

        /// What happened to it in the period, latest first: "merged", then "opened".
        func events(in period: DateInterval) -> [(String, Date)] {
            var out: [(String, Date)] = []
            if let mergedAt, period.contains(mergedAt) { out.append(("merged", mergedAt)) }
            else if let closedAt, state == "closed", period.contains(closedAt) { out.append(("closed without merging", closedAt)) }
            if let createdAt, period.contains(createdAt) { out.append(("opened", createdAt)) }
            return out
        }
    }

    /// What people said on a pull request: reviews, comments and open review threads by someone
    /// other than the developer's own GitHub accounts and the pull request's author. Bots (CI,
    /// code scanners, review apps) are left out: the agent deals with them, and they comment on
    /// every push.
    struct PullRequestFeedback: Hashable {
        struct Item: Hashable {
            enum Kind: Hashable { case approved, changesRequested, comment }
            let id: String
            let kind: Kind
            let author: String
            let body: String
            let at: Date
        }
        let number: Int
        /// "open", "merged" or "closed".
        let state: String
        let approved: Bool
        let changesRequested: Bool
        /// Oldest first.
        let items: [Item]
        /// The last push, or the developer's last comment or reply, whichever is later.
        let answeredAt: Date?

        /// What came after the last push or reply and still asks something of the developer.
        /// An approval asks nothing, and it settles what the same reviewer wrote before it:
        /// someone who commented and then approved is not waiting for an answer.
        var waiting: [Item] {
            var approvedAt: [String: Date] = [:]
            for item in items where item.kind == .approved { approvedAt[item.author] = item.at }
            return items.filter { item in
                item.kind != .approved && item.at > (answeredAt ?? .distantPast)
                    && item.at > (approvedAt[item.author] ?? .distantPast)
            }
        }
    }

    /// Everything one question to GitHub says about a pull request.
    struct PullRequestReport: Hashable {
        let detail: PullRequestDetail
        let feedback: PullRequestFeedback
        /// "passing", "failing" or "pending"; nil when the last commit has no checks.
        let checks: String?
        let conflict: Bool
        let headSha: String?
    }

    // MARK: Repositories

    /// "owner/name" from what was typed: that itself, a github.com address or an ssh one.
    /// Nil for anything else.
    static func slug(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var isAddress = false
        if let at = text.range(of: "github.com:") ?? text.range(of: "github.com/") {
            text = String(text[at.upperBound...])
            isAddress = true
        } else if text.contains(":") {
            return nil
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // A pasted page address goes on after the name ("/tree/main", "/pull/3").
        guard parts.count == 2 || (isAddress && parts.count > 2) else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let plain = { (part: String) in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        }
        return plain(parts[0]) && plain(name) ? "\(parts[0])/\(name)" : nil
    }

    /// Clones a GitHub repository into a new folder of `parent` and returns the folder.
    /// `account` is the `gh` user the clone runs as; empty means gh's active account.
    static func clone(slug: String, into parent: String, account: String?) async throws -> String {
        guard let gh = executable else {
            throw ToolFailure.failed("The gh command was not found, and the clone is made with it. Install it with “brew install gh”.")
        }
        let name = slug.split(separator: "/").last.map(String.init) ?? slug
        let path = try Sessions.newDirectoryPath(named: name, in: parent)
        // A large repository takes far longer than anything else asked of a command.
        guard let reply = await run(gh, ["repo", "clone", slug, path], account: account, timeout: 1800) else {
            throw ToolFailure.failed("gh could not be started.")
        }
        guard reply.status == 0 else {
            if reply.status == 9, let account, !account.isEmpty {
                throw ToolFailure.failed("gh has no token for \(account). Run “gh auth login” in a terminal.")
            }
            throw ToolFailure.failed(Shell.message(reply, tool: "gh"))
        }
        return path
    }

    /// Fetches a pull request's head into the repository at `path`, so a worktree can start from
    /// the code under review. Returns the ref to base the worktree on. The ref is a remote-tracking
    /// one of its own, so no local branch is made or moved.
    static func fetchPullRequest(_ number: Int, in path: String, account: String?) async throws -> String {
        let git = "/usr/bin/git"
        let args = ["-C", path, "fetch", "origin", "+refs/pull/\(number)/head:refs/remotes/origin/pr/\(number)"]
        // Never a password prompt: there is no terminal to answer it, and the fetch would hang.
        let quiet = ["GIT_TERMINAL_PROMPT": "0"]
        let reply: Shell.Result
        if let account, !account.isEmpty, let gh = executable {
            // As in `run`: the token goes from gh's keyring to git inside the shell. It only
            // counts when git asks gh for credentials (gh auth setup-git); an ssh remote ignores it.
            let script = "T=\"$(\"$0\" auth token --user \"$1\")\"; [ -n \"$T\" ] || exit 9; shift; GH_TOKEN=\"$T\" exec \(git) \"$@\""
            reply = try await Shell.run("/bin/sh", ["-c", script, gh, account] + args, environment: quiet, timeout: 600)
            if reply.status == 9 {
                throw ToolFailure.failed("gh has no token for \(account). Run “gh auth login” in a terminal.")
            }
        } else {
            reply = try await Shell.run(git, args, environment: quiet, timeout: 600)
        }
        guard reply.status == 0 else { throw ToolFailure.failed(Shell.message(reply, tool: "git")) }
        return "origin/pr/\(number)"
    }

    // MARK: Accounts

    /// The github.com accounts signed in to the `gh` command. Empty when gh is missing or says nothing.
    static func accounts() async -> [String] {
        guard let gh = executable,
              let reply = try? await Shell.run(gh, ["auth", "status", "--json", "hosts"]),
              let json = (try? JSONSerialization.jsonObject(with: reply.out)) as? [String: Any],
              let hosts = json["hosts"] as? [String: Any],
              let accounts = hosts["github.com"] as? [[String: Any]] else { return [] }
        return accounts.compactMap { $0["login"] as? String }
    }

    /// The GitHub logins of the accounts gh is signed in to, the developer's own. Empty when gh
    /// is missing or did not answer.
    static func logins() async -> Set<String> {
        guard let gh = executable, let reply = try? await Shell.run(gh, ["auth", "status", "--json", "hosts"], timeout: 30),
              let root = (try? JSONSerialization.jsonObject(with: reply.out)) as? [String: Any],
              let hosts = root["hosts"] as? [String: Any] else { return [] }
        let accounts = hosts.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
        return Set(accounts.compactMap { ($0["login"] as? String)?.lowercased() })
    }

    // MARK: Pull requests

    /// Asks GitHub for the pull requests of a branch, all of them: a branch reused after a merge
    /// has several. Nil means the question could not be asked (gh missing, no token, no network);
    /// an empty list means GitHub answered and there is none.
    static func pullRequests(slug: String, branch: String, account: String?) async -> [PullRequest]? {
        guard let gh = executable else { return nil }
        let list = ["pr", "list", "--repo", slug, "--head", branch, "--state", "all",
                    "--json", "number,state,isDraft", "--limit", "10"]
        guard let reply = await run(gh, list, account: account), reply.status == 0,
              let rows = (try? JSONSerialization.jsonObject(with: reply.out)) as? [[String: Any]] else { return nil }
        return rows.compactMap { row -> PullRequest? in
            guard let number = row["number"] as? Int, let state = row["state"] as? String else { return nil }
            return PullRequest(number: number, state: state.lowercased(), draft: row["isDraft"] as? Bool ?? false)
        }
    }

    /// The one a session's badge is about: the one still open, else a merged one.
    static func current(_ found: [PullRequest]) -> PullRequest? {
        found.first { $0.state == "open" } ?? found.first { $0.state == "merged" } ?? found.first
    }

    /// A pull request's title, draft flag and dates, for the code review's sheet. Nil when gh is missing or GitHub did not answer.
    static func pullRequestDetail(_ url: URL, account: String?) async -> PullRequestDetail? {
        guard let gh = executable else { return nil }
        let args = ["pr", "view", url.absoluteString, "--json", "number,title,body,state,isDraft,createdAt,mergedAt,closedAt"]
        guard let reply = await run(gh, args, account: account), reply.status == 0,
              let row = (try? JSONSerialization.jsonObject(with: reply.out)) as? [String: Any],
              let number = row["number"] as? Int, let state = row["state"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        // GitHub sends an empty string (or the zero date) for what has not happened yet.
        func date(_ key: String) -> Date? {
            (row[key] as? String).flatMap { iso.date(from: $0) }.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        }
        return PullRequestDetail(number: number, title: row["title"] as? String ?? "",
                                 body: row["body"] as? String ?? "", state: state.lowercased(),
                                 draft: row["isDraft"] as? Bool ?? false, createdAt: date("createdAt"),
                                 mergedAt: date("mergedAt"), closedAt: date("closedAt"))
    }

    private static let feedbackQuery = """
    query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) {
      number state reviewDecision author { login }
      title body isDraft createdAt mergedAt closedAt mergeable
      commits(last: 1) { nodes { commit { oid committedDate statusCheckRollup { contexts(first: 100) { nodes {
        __typename ... on CheckRun { status conclusion } ... on StatusContext { state }
      } } } } } }
      reviews(last: 50) { nodes { id state body submittedAt author { __typename login } } }
      comments(last: 50) { nodes { id body createdAt author { __typename login } } }
      reviewThreads(last: 80) { nodes { isResolved comments(last: 1) { nodes { id body createdAt author { __typename login } } } } }
    } } }
    """

    /// Reads a pull request: its state, title and dates, the last commit's checks, whether it
    /// conflicts, and its reviews and comments. `mine` holds the developer's GitHub logins,
    /// lowercased. Nil when gh is missing or GitHub did not answer.
    static func pullRequestReport(slug: String, number: Int, account: String?, mine: Set<String>) async -> PullRequestReport? {
        let parts = slug.split(separator: "/").map(String.init)
        guard let gh = executable, parts.count == 2 else { return nil }
        let args = ["api", "graphql", "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])", "-F", "number=\(number)",
                    "-f", "query=\(feedbackQuery)"]
        guard let reply = await run(gh, args, account: account), reply.status == 0,
              let root = (try? JSONSerialization.jsonObject(with: reply.out)) as? [String: Any],
              let pr = ((root["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
              let state = pr["state"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        func nodes(_ object: Any?) -> [[String: Any]] { (object as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] }
        let author = ((pr["author"] as? [String: Any])?["login"] as? String)?.lowercased()
        let me = mine.union([author].compactMap { $0 })

        var items: [PullRequestFeedback.Item] = []
        var answered = nodes(pr["commits"]).compactMap { (($0["commit"] as? [String: Any])?["committedDate"] as? String).flatMap(iso.date) }.max()
        // Everything written, by whom and when: the developer's own count as answers.
        func take(_ node: [String: Any], date key: String, kind: PullRequestFeedback.Item.Kind?) {
            guard let who = node["author"] as? [String: Any], let login = who["login"] as? String,
                  let at = (node[key] as? String).flatMap(iso.date), let id = node["id"] as? String else { return }
            if me.contains(login.lowercased()) {
                answered = max(answered ?? at, at)
                return
            }
            guard who["__typename"] as? String == "User", let kind else { return }
            items.append(.init(id: id, kind: kind, author: login,
                               body: (node["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), at: at))
        }
        // Each reviewer's last verdict; GitHub lists reviews oldest first.
        var decisions: [String: String] = [:]
        for review in nodes(pr["reviews"]) {
            let body = (review["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: PullRequestFeedback.Item.Kind?
            switch review["state"] as? String {
            case "APPROVED": kind = .approved
            case "CHANGES_REQUESTED": kind = .changesRequested
            // A review with no text only wraps line comments, which come with their threads.
            case "COMMENTED": kind = body.isEmpty ? nil : .comment
            default: kind = nil
            }
            take(review, date: "submittedAt", kind: kind)
            if let state = review["state"] as? String, state == "APPROVED" || state == "CHANGES_REQUESTED",
               let login = (review["author"] as? [String: Any])?["login"] as? String, !me.contains(login.lowercased()) {
                decisions[login] = state
            }
        }
        for comment in nodes(pr["comments"]) { take(comment, date: "createdAt", kind: .comment) }
        // A thread counts by its last comment, and only while it is open: a resolved thread, or
        // one whose last word is the developer's, is answered.
        for thread in nodes(pr["reviewThreads"]) where thread["isResolved"] as? Bool != true {
            for comment in nodes(thread["comments"]) { take(comment, date: "createdAt", kind: .comment) }
        }
        // GitHub's own verdict where the repository requires reviews; otherwise each reviewer's last say.
        let decision = pr["reviewDecision"] as? String
        let changes = decision == "CHANGES_REQUESTED" || (decision == nil && decisions.values.contains("CHANGES_REQUESTED"))
        let approved = !changes && (decision == "APPROVED" || (decision == nil && decisions.values.contains("APPROVED")))
        let feedback = PullRequestFeedback(number: pr["number"] as? Int ?? number, state: state.lowercased(),
                                           approved: approved, changesRequested: changes,
                                           items: items.sorted { $0.at < $1.at }, answeredAt: answered)
        func date(_ key: String) -> Date? { (pr[key] as? String).flatMap(iso.date) }
        let detail = PullRequestDetail(number: feedback.number, title: pr["title"] as? String ?? "",
                                       body: pr["body"] as? String ?? "", state: feedback.state,
                                       draft: pr["isDraft"] as? Bool ?? false, createdAt: date("createdAt"),
                                       mergedAt: date("mergedAt"), closedAt: date("closedAt"))
        let commit = nodes(pr["commits"]).last?["commit"] as? [String: Any]
        // Counted from the checks themselves. GitHub's own summary says "failure" for a gate
        // that waits for somebody's approval, also while the tests are still running.
        var failed = false, unfinished = false
        let runs = nodes((commit?["statusCheckRollup"] as? [String: Any])?["contexts"])
        for run in runs {
            if run["__typename"] as? String == "CheckRun" {
                if run["status"] as? String != "COMPLETED" { unfinished = true; continue }
                switch run["conclusion"] as? String {
                case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE": failed = true
                // Waiting for a person, not failed.
                case "ACTION_REQUIRED": unfinished = true
                // Success, skipped, neutral; and cancelled, which is usually a run a newer one replaced.
                default: break
                }
            } else {
                switch run["state"] as? String {
                case "FAILURE", "ERROR": failed = true
                case "PENDING", "EXPECTED": unfinished = true
                default: break
                }
            }
        }
        let checks: String? = runs.isEmpty ? nil : failed ? "failing" : unfinished ? "pending" : "passing"
        return PullRequestReport(detail: detail, feedback: feedback, checks: checks,
                                 conflict: pr["mergeable"] as? String == "CONFLICTING", headSha: commit?["oid"] as? String)
    }

    // MARK: Running gh

    static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs gh as the given account, or as gh's active one when none is given.
    private static func run(_ gh: String, _ args: [String], account: String?,
                            timeout: TimeInterval = 180) async -> Shell.Result? {
        guard let account, !account.isEmpty else { return try? await Shell.run(gh, args, timeout: timeout) }
        // The token goes from gh's keyring to gh inside the shell; this app never reads it.
        // Without a token nothing is asked: gh would silently answer as the active account.
        let script = "T=\"$(\"$0\" auth token --user \"$1\")\"; [ -n \"$T\" ] || exit 9; shift; GH_TOKEN=\"$T\" exec \"$0\" \"$@\""
        return try? await Shell.run("/bin/sh", ["-c", script, gh, account] + args, timeout: timeout)
    }
}
