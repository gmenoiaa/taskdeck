import Foundation

/// Ticket data, regardless of the source tracker.
struct TicketDetail {
    struct Comment: Identifiable, Codable {
        let id: String
        let author: String
        let date: String
        let body: String
    }

    var kindLabel: String?
    var subject: String
    var status: String?
    var meta: [(String, String)] = []
    /// Pages behind some of the `meta` lines, by label: the parent ticket's, for one.
    var links: [String: URL] = [:]
    var description = ""
    /// Description and comments are Markdown.
    var markdown = false
    /// Oldest to newest.
    var comments: [Comment] = []
    var estimatedHours: Double?
    /// The tracker's due day ("2026-11-27"), when it has one.
    var dueDay: String?

    /// Who the ticket is assigned to (several people on GitHub), or nil when unassigned.
    var assignee: String? { meta.first { $0.0 == "Assignee" }?.1 }
    var totalSpentHours: Double?
    /// True for a tracker where a ticket is expected to carry an estimate (Redmine).
    var tracksEstimate = false
    /// Redmine's "Dev Estimate" custom field, when the ticket has one. Nil when it does not.
    var devEstimate: DevEstimate?

    struct DevEstimate: Codable, Hashable {
        let fieldId: Int
        var hours: Double?
    }

    /// What is missing, in words for a tooltip ("Estimate and dev estimate"), or nil when
    /// nothing is, or when the tracker has no estimates.
    var estimateGap: String? {
        guard tracksEstimate else { return nil }
        let noEstimate = (estimatedHours ?? 0) <= 0
        let noDev = devEstimate.map { ($0.hours ?? 0) <= 0 } ?? false
        switch (noEstimate, noDev) {
        case (true, true): return "Estimate and dev estimate"
        case (true, false): return "Estimate"
        case (false, true): return "Dev estimate"
        case (false, false): return nil
        }
    }
}

enum HTTP {
    static func getJSON(_ urlString: String, headers: [String: String]) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await send("GET", urlString, headers: headers))
    }

    @discardableResult
    static func send(_ method: String, _ urlString: String, headers: [String: String],
                     body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw RedmineError(message: "Invalid URL: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401: throw RedmineError(message: "401 — invalid credentials.")
            case 403: throw RedmineError(message: "403 — not allowed (or rate limit reached).")
            case 404: throw RedmineError(message: "404 — not found, or no access with these credentials.")
            default:
                // GitHub and Jira explain the reason in the response body.
                var detail = ""
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var parts: [String] = []
                    if let m = obj["message"] as? String { parts.append(m) }
                    for e in (obj["errors"] as? [[String: Any]]) ?? [] {
                        if let m = e["message"] as? String { parts.append(m) }
                    }
                    parts += (obj["errorMessages"] as? [String]) ?? []
                    detail = parts.joined(separator: " — ")
                }
                throw RedmineError(message: "HTTP \(code)" + (detail.isEmpty ? "" : ": \(detail)"))
            }
        }
        return data
    }
}

enum TicketFetcher {
    static let missingCredentials = RedmineError(message: "Set the space's base URL and credentials in Settings → Spaces.")

    static func canFetch(project: Project?, task: TaskItem) -> Bool {
        guard let project else { return false }
        switch project.kind {
        case .redmine: return Int(task.ref) != nil
        case .jira: return !task.ref.isEmpty && (!project.baseURL.isEmpty || task.url.hasPrefix("http"))
        case .github: return githubParts(task.url) != nil
        case .other: return false
        }
    }

    static func fetch(project: Project, ref: String, url: String) async throws -> TicketDetail {
        switch project.kind {
        case .redmine:
            guard let id = Int(ref) else {
                throw RedmineError(message: "Ticket “\(ref)” is not a Redmine issue number.")
            }
            guard let client = RedmineClient(project: project) else { throw missingCredentials }
            return redmineDetail(try await client.issue(id: id), project: project, base: client.baseURL)
        case .jira:
            return try await jira(project: project, key: ref, url: url)
        case .github:
            return try await github(project: project, url: url)
        case .other:
            throw RedmineError(message: "This space's tracker has no integration.")
        }
    }

    /// Posts a comment on the ticket as the owner of the project's credentials.
    static func postComment(project: Project, ref: String, url: String, text: String) async throws {
        switch project.kind {
        case .redmine:
            guard let id = Int(ref) else {
                throw RedmineError(message: "Ticket “\(ref)” is not a Redmine issue number.")
            }
            guard let client = RedmineClient(project: project) else { throw missingCredentials }
            try await HTTP.send("PUT", "\(client.baseURL)/issues/\(id).json",
                                headers: ["X-Redmine-API-Key": client.apiKey],
                                body: ["issue": ["notes": text]])
        case .jira:
            guard let base = jiraBase(project: project, url: url),
                  let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
                throw missingCredentials
            }
            let key = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
            try await HTTP.send("POST", "\(base)/rest/api/2/issue/\(key)/comment",
                                headers: jiraAuth(project: project, token: token),
                                body: ["body": text])
        case .github:
            guard let p = githubParts(url) else {
                throw RedmineError(message: "Could not find the repository and number in the ticket link.")
            }
            guard let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
                throw RedmineError(message: "To comment, set a GitHub token in Settings → Spaces.")
            }
            try await HTTP.send("POST", "\(p.api)/repos/\(p.owner)/\(p.repo)/issues/\(p.number)/comments",
                                headers: githubHeaders(token: token),
                                body: ["body": text])
        case .other:
            throw RedmineError(message: "This space's tracker has no integration.")
        }
    }

    // MARK: Redmine

    private static func redmineDetail(_ issue: RedmineClient.IssueDetail, project: Project, base: String) -> TicketDetail {
        let textile = project.textFormat != "markdown"
        func md(_ s: String?) -> String {
            textile ? Textile.toMarkdown(s ?? "", issueBase: base) : (s ?? "")
        }
        var d = TicketDetail(kindLabel: issue.tracker?.name, subject: issue.subject, status: issue.status?.name)
        d.description = md(issue.description)
        d.markdown = true
        d.estimatedHours = issue.estimated_hours
        d.totalSpentHours = issue.total_spent_hours ?? issue.spent_hours
        d.tracksEstimate = true
        // Found by name: the field's number differs from one Redmine to the next.
        if let field = issue.custom_fields?.first(where: { $0.name.caseInsensitiveCompare("Dev Estimate") == .orderedSame }) {
            let text = (field.value ?? "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            d.devEstimate = TicketDetail.DevEstimate(fieldId: field.id, hours: Double(text))
        }
        d.meta = compact([
            ("Project", issue.project?.name),
            ("Priority", issue.priority?.name),
            ("Assignee", issue.assigned_to?.name),
            ("Author", issue.author?.name),
            ("Created", RedmineDate.pretty(issue.created_on)),
            ("Updated", RedmineDate.pretty(issue.updated_on)),
            ("Due", issue.due_date.map { RedmineDate.prettyDay($0) }),
            ("Done", issue.done_ratio.map { "\($0)%" }),
            ("Parent", issue.parent.map { "#\($0.id)" }),
        ])
        d.dueDay = issue.due_date
        if let parent = issue.parent { d.links["Parent"] = URL(string: "\(base)/issues/\(parent.id)") }
        d.comments = (issue.journals ?? []).map {
            .init(id: "\($0.id)", author: $0.user?.name ?? "—",
                  date: RedmineDate.pretty($0.created_on), body: md($0.notes))
        }
        return d
    }

    // MARK: Jira

    private static func jiraAuth(project: Project, token: String) -> [String: String] {
        let user = (project.username ?? "").trimmingCharacters(in: .whitespaces)
        if user.isEmpty { return ["Authorization": "Bearer \(token)"] }
        let basic = Data("\(user):\(token)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(basic)"]
    }

    static func jiraBaseURL(_ project: Project) -> String? { jiraBase(project: project, url: "") }
    static func jiraHeaders(project: Project, token: String) -> [String: String] { jiraAuth(project: project, token: token) }
    static func githubAPIBase(host: String, scheme: String?) -> String { githubAPI(host: host, scheme: scheme) }
    static func githubAuthHeaders(token: String?) -> [String: String] { githubHeaders(token: token) }

    private static func jiraBase(project: Project, url: String) -> String? {
        var base = project.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.isEmpty { return base }
        guard let c = URLComponents(string: url), let scheme = c.scheme, let host = c.host else { return nil }
        return "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
    }

    /// Authenticated user's name — used by "Test connection".
    static func jiraWhoAmI(project: Project, token: String) async throws -> String {
        guard let base = jiraBase(project: project, url: "") else { throw missingCredentials }
        let json = try await HTTP.getJSON("\(base)/rest/api/2/myself", headers: jiraAuth(project: project, token: token))
        let me = json as? [String: Any]
        return (me?["displayName"] as? String) ?? (me?["name"] as? String) ?? "ok"
    }

    private static func jira(project: Project, key: String, url: String) async throws -> TicketDetail {
        guard let base = jiraBase(project: project, url: url),
              let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw missingCredentials
        }
        let fields = "summary,description,status,issuetype,priority,assignee,reporter,created,updated,duedate,project,comment,timetracking,labels,parent"
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let headers = jiraAuth(project: project, token: token)
        var json: Any
        var rich = true
        do {
            // Jira Cloud: v3 returns structured text (ADF), which becomes Markdown.
            json = try await HTTP.getJSON("\(base)/rest/api/3/issue/\(safeKey)?fields=\(fields)", headers: headers)
        } catch {
            // Jira Server / Data Center: only v2 exists, with raw wiki markup.
            json = try await HTTP.getJSON("\(base)/rest/api/2/issue/\(safeKey)?fields=\(fields)", headers: headers)
            rich = false
        }
        let f = ((json as? [String: Any])?["fields"] as? [String: Any]) ?? [:]
        func name(_ key: String) -> String? {
            let obj = f[key] as? [String: Any]
            return (obj?["displayName"] as? String) ?? (obj?["name"] as? String)
        }
        let tracking = f["timetracking"] as? [String: Any]
        let parent = f["parent"] as? [String: Any]
        let parentSummary = (parent?["fields"] as? [String: Any])?["summary"] as? String

        var d = TicketDetail(kindLabel: name("issuetype"),
                             subject: (f["summary"] as? String) ?? key,
                             status: name("status"))
        d.description = richText(f["description"])
        d.markdown = rich
        d.dueDay = f["duedate"] as? String
        d.meta = compact([
            ("Project", name("project")),
            ("Priority", name("priority")),
            ("Assignee", name("assignee")),
            ("Reporter", name("reporter")),
            ("Created", RedmineDate.pretty(f["created"] as? String)),
            ("Updated", RedmineDate.pretty(f["updated"] as? String)),
            ("Due", (f["duedate"] as? String).map { RedmineDate.prettyDay($0) }),
            ("Estimated", tracking?["originalEstimate"] as? String),
            ("Time spent", tracking?["timeSpent"] as? String),
            ("Labels", (f["labels"] as? [String])?.joined(separator: ", ")),
            ("Parent", (parent?["key"] as? String).map { [$0, parentSummary].compactMap { $0 }.joined(separator: " — ") }),
        ])
        if let parentKey = parent?["key"] as? String { d.links["Parent"] = URL(string: "\(base)/browse/\(parentKey)") }
        let comments = ((f["comment"] as? [String: Any])?["comments"] as? [[String: Any]]) ?? []
        d.comments = comments.enumerated().map { i, c in
            let author = c["author"] as? [String: Any]
            return .init(id: (c["id"] as? String) ?? "\(i)",
                         author: (author?["displayName"] as? String) ?? (author?["name"] as? String) ?? "—",
                         date: RedmineDate.pretty(c["created"] as? String),
                         body: richText(c["body"]))
        }
        return d
    }

    /// Plain text (API v2) or Atlassian Document Format converted to Markdown.
    private static func richText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let node = value as? [String: Any] else { return "" }
        return ADF.markdown(node)
    }

    // MARK: GitHub

    /// Extracts host/owner/repo/number from an issue or PR link.
    static func githubParts(_ url: String) -> (api: String, owner: String, repo: String, number: Int)? {
        guard let c = URLComponents(string: url), let host = c.host else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, ["issues", "pull"].contains(parts[2]), let n = Int(parts[3]) else { return nil }
        return (githubAPI(host: host, scheme: c.scheme), parts[0], parts[1], n)
    }

    private static func githubAPI(host: String, scheme: String?) -> String {
        host == "github.com" || host == "www.github.com"
            ? "https://api.github.com"
            : "\(scheme ?? "https")://\(host)/api/v3"
    }

    private static func githubHeaders(token: String?) -> [String: String] {
        var h = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let token, !token.isEmpty { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    /// Authenticated user's login — used by "Test connection".
    static func githubWhoAmI(project: Project, token: String) async throws -> String {
        let c = URLComponents(string: project.baseURL.trimmingCharacters(in: .whitespaces))
        let api = githubAPI(host: c?.host ?? "github.com", scheme: c?.scheme)
        let json = try await HTTP.getJSON("\(api)/user", headers: githubHeaders(token: token))
        return ((json as? [String: Any])?["login"] as? String) ?? "ok"
    }

    private static func github(project: Project, url: String) async throws -> TicketDetail {
        guard let p = githubParts(url) else {
            throw RedmineError(message: "Could not find the repository and number in the link. Use “repo#123” or paste the issue/PR link.")
        }
        let headers = githubHeaders(token: Keychain.get(account: project.keychainAccount))
        let path = "\(p.api)/repos/\(p.owner)/\(p.repo)/issues/\(p.number)"
        let issue = (try await HTTP.getJSON(path, headers: headers) as? [String: Any]) ?? [:]
        func login(_ any: Any?) -> String? { (any as? [String: Any])?["login"] as? String }
        let isPR = issue["pull_request"] != nil
        var state = issue["state"] as? String
        if isPR, ((issue["pull_request"] as? [String: Any])?["merged_at"] as? String) != nil { state = "merged" }
        if issue["draft"] as? Bool == true, state == "open" { state = "draft" }

        // An issue type set in the organisation (Bug, Epic…) says more than plain "Issue".
        let type = (issue["type"] as? [String: Any])?["name"] as? String
        var d = TicketDetail(kindLabel: type ?? (isPR ? "Pull request" : "Issue"),
                             subject: (issue["title"] as? String) ?? "#\(p.number)",
                             status: state)
        // An open ticket's real status is usually the one in its GitHub project; "open" says little.
        // Without a token, or without the project scope, the plain state stays.
        if state == "open", let board = try? await githubProjectStatus(project: project, url: url),
           let current = board.current {
            d.status = current
        }
        d.description = (issue["body"] as? String) ?? ""
        d.markdown = true
        let assignees = ((issue["assignees"] as? [[String: Any]]) ?? []).compactMap { $0["login"] as? String }
        let labels = ((issue["labels"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        d.meta = compact([
            ("Repository", "\(p.owner)/\(p.repo)"),
            ("Author", login(issue["user"])),
            ("Assignee", assignees.joined(separator: ", ")),
            ("Labels", labels.joined(separator: ", ")),
            ("Milestone", (issue["milestone"] as? [String: Any])?["title"] as? String),
            ("Created", RedmineDate.pretty(issue["created_at"] as? String)),
            ("Updated", RedmineDate.pretty(issue["updated_at"] as? String)),
            ("Closed", (issue["closed_at"] as? String).map { RedmineDate.pretty($0) }),
        ])
        if ((issue["comments"] as? Int) ?? 0) > 0 {
            let list = (try await HTTP.getJSON("\(path)/comments?per_page=100", headers: headers) as? [[String: Any]]) ?? []
            d.comments = list.enumerated().map { i, c in
                .init(id: (c["id"] as? Int).map(String.init) ?? "\(i)",
                      author: login(c["user"]) ?? "—",
                      date: RedmineDate.pretty(c["created_at"] as? String),
                      body: (c["body"] as? String) ?? "")
            }
        }
        return d
    }

    private static func compact(_ items: [(String, String?)]) -> [(String, String)] {
        items.compactMap { item in
            guard let value = item.1, !value.isEmpty else { return nil }
            return (item.0, value)
        }
    }
}

enum RedmineDate {
    static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = plain.date(from: iso) ?? fractional.date(from: iso) { return date }
        // Jira: 2024-01-02T10:11:12.345+0000
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return df.date(from: iso)
    }

    static func pretty(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        return date(iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }

    static func prettyDay(_ day: String) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: day) else { return day }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
