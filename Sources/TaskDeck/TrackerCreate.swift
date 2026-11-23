import Foundation

/// Where a new ticket can go inside a space's tracker: a Redmine project, a Jira project or a
/// GitHub repository. `types` is nil until read (Jira reads them per project, on demand).
struct CreateTarget: Identifiable, Hashable {
    let id: String
    let name: String
    var types: [TrackerChoice]?
}

/// A ticket the tracker created: what the task needs to point at it.
struct CreatedTicket {
    let ref: String
    let url: String
    /// Set when the ticket exists but something after its creation failed (assigning it).
    var warning: String?
}

extension TicketFetcher {
    // MARK: Where a ticket can go

    static func createTargets(project: Project) async throws -> [CreateTarget] {
        switch project.kind {
        case .redmine: return try await redmineTargets(project)
        case .jira: return try await jiraTargets(project)
        case .github: return try await githubTargets(project)
        case .other: throw RedmineError(message: "This space's tracker has no integration.")
        }
    }

    /// The ticket types of one target, for a tracker that does not list them with the targets.
    static func createTypes(project: Project, target: String) async throws -> [TrackerChoice] {
        guard project.kind == .jira else { return [] }
        return try await jiraTypes(project, key: target)
    }

    /// Creates the ticket. `markdown` is converted to the tracker's own text format.
    static func createTicket(project: Project, target: String, type: String?, title: String,
                             markdown: String, assignToMe: Bool) async throws -> CreatedTicket {
        switch project.kind {
        case .redmine:
            return try await redmineCreate(project, target: target, type: type, title: title,
                                           markdown: markdown, assignToMe: assignToMe)
        case .jira:
            return try await jiraCreate(project, key: target, type: type, title: title,
                                        markdown: markdown, assignToMe: assignToMe)
        case .github:
            return try await githubCreate(project, repo: target, title: title, markdown: markdown, assignToMe: assignToMe)
        case .other:
            throw RedmineError(message: "This space's tracker has no integration.")
        }
    }

    // MARK: Redmine

    private static func redmineTargets(_ project: Project) async throws -> [CreateTarget] {
        guard let client = RedmineClient(project: project) else { throw missingCredentials }
        let headers = ["X-Redmine-API-Key": client.apiKey]
        var targets: [CreateTarget] = []
        var offset = 0
        // Only open projects; the trackers come along, so no second request per project.
        while offset < 1000 {
            let json = try await HTTP.getJSON("\(client.baseURL)/projects.json?include=trackers&limit=100&offset=\(offset)",
                                              headers: headers) as? [String: Any]
            let rows = (json?["projects"] as? [[String: Any]]) ?? []
            for row in rows {
                guard let id = row["id"] as? Int, let name = row["name"] as? String,
                      (row["status"] as? Int ?? 1) == 1 else { continue }
                let parent = (row["parent"] as? [String: Any])?["name"] as? String
                let types = ((row["trackers"] as? [[String: Any]]) ?? []).compactMap { t -> TrackerChoice? in
                    guard let tid = t["id"] as? Int, let tname = t["name"] as? String else { return nil }
                    return TrackerChoice(id: String(tid), name: tname)
                }
                targets.append(CreateTarget(id: String(id), name: parent.map { "\($0) › \(name)" } ?? name, types: types))
            }
            offset += rows.count
            if rows.isEmpty || offset >= (json?["total_count"] as? Int ?? 0) { break }
        }
        return targets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func redmineCreate(_ project: Project, target: String, type: String?, title: String,
                                      markdown: String, assignToMe: Bool) async throws -> CreatedTicket {
        guard let client = RedmineClient(project: project) else { throw missingCredentials }
        let textile = project.textFormat != "markdown"
        var issue: [String: Any] = [
            "project_id": Int(target) ?? target,
            "subject": title,
            "description": textile ? Markup.textile(markdown) : markdown,
        ]
        if let type, let id = Int(type) { issue["tracker_id"] = id }
        if assignToMe { issue["assigned_to_id"] = try await client.currentUserId() }
        let data = try await HTTP.send("POST", "\(client.baseURL)/issues.json",
                                       headers: ["X-Redmine-API-Key": client.apiKey], body: ["issue": issue])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let id = (json?["issue"] as? [String: Any])?["id"] as? Int else {
            throw RedmineError(message: "Redmine answered without the new ticket's number. Check Redmine before trying again: it may have been created.")
        }
        return CreatedTicket(ref: String(id), url: "\(client.baseURL)/issues/\(id)")
    }

    // MARK: Jira

    private static func jiraContext(_ project: Project) throws -> (base: String, headers: [String: String]) {
        guard let base = jiraBaseURL(project),
              let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw missingCredentials
        }
        return (base, jiraHeaders(project: project, token: token))
    }

    private static func jiraTargets(_ project: Project) async throws -> [CreateTarget] {
        let jira = try jiraContext(project)
        let rows = try await HTTP.getJSON("\(jira.base)/rest/api/2/project", headers: jira.headers) as? [[String: Any]] ?? []
        return rows.compactMap { row -> CreateTarget? in
            guard let key = row["key"] as? String else { return nil }
            let name = (row["name"] as? String) ?? key
            return CreateTarget(id: key, name: "\(name) (\(key))")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func jiraTypes(_ project: Project, key: String) async throws -> [TrackerChoice] {
        let jira = try jiraContext(project)
        let safe = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        func choices(_ rows: [[String: Any]]) -> [TrackerChoice] {
            // Sub-tasks need a parent, which this screen does not ask for.
            rows.filter { ($0["subtask"] as? Bool) != true }.compactMap { row in
                guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                return TrackerChoice(id: id, name: name)
            }
        }
        do {
            // Jira Cloud and Data Center 8.4+. Cloud names the list "issueTypes", older answers "values".
            let json = try await HTTP.getJSON("\(jira.base)/rest/api/2/issue/createmeta/\(safe)/issuetypes?maxResults=100",
                                              headers: jira.headers) as? [String: Any]
            let rows = (json?["issueTypes"] as? [[String: Any]]) ?? (json?["values"] as? [[String: Any]]) ?? []
            if !rows.isEmpty { return choices(rows) }
        } catch {}
        // Older Server versions only have the original form of the call.
        let json = try await HTTP.getJSON("\(jira.base)/rest/api/2/issue/createmeta?projectKeys=\(safe)",
                                          headers: jira.headers) as? [String: Any]
        let first = (json?["projects"] as? [[String: Any]])?.first
        return choices((first?["issuetypes"] as? [[String: Any]]) ?? [])
    }

    private static func jiraCreate(_ project: Project, key: String, type: String?, title: String,
                                   markdown: String, assignToMe: Bool) async throws -> CreatedTicket {
        let jira = try jiraContext(project)
        guard let type else { throw RedmineError(message: "Choose the ticket type.") }
        // API v2 takes the description as wiki markup on Cloud and Server alike.
        let fields: [String: Any] = [
            "project": ["key": key],
            "summary": title,
            "issuetype": ["id": type],
            "description": Markup.jira(markdown),
        ]
        let data = try await HTTP.send("POST", "\(jira.base)/rest/api/2/issue", headers: jira.headers, body: ["fields": fields])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let newKey = json?["key"] as? String else {
            throw RedmineError(message: "Jira answered without the new ticket's key. Check Jira before trying again: it may have been created.")
        }
        var created = CreatedTicket(ref: newKey, url: "\(jira.base)/browse/\(newKey)")
        // Assigned in a second call: many projects leave the assignee off the create screen, and
        // then the whole creation would be refused for it.
        if assignToMe {
            do {
                let me = try await HTTP.getJSON("\(jira.base)/rest/api/2/myself", headers: jira.headers) as? [String: Any]
                let body: [String: Any]
                if let account = me?["accountId"] as? String { body = ["accountId": account] }
                else if let name = me?["name"] as? String { body = ["name": name] }
                else { throw RedmineError(message: "Jira did not say who you are.") }
                try await HTTP.send("PUT", "\(jira.base)/rest/api/2/issue/\(newKey)/assignee", headers: jira.headers, body: body)
            } catch {
                created.warning = "\(newKey) was created but not assigned to you: \(error.localizedDescription)"
            }
        }
        return created
    }

    // MARK: GitHub

    private static func githubContext(_ project: Project) throws -> (api: String, headers: [String: String], path: [String]) {
        guard let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw RedmineError(message: "To create an issue, set a GitHub token in Settings → Spaces.")
        }
        let c = URLComponents(string: project.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        return (githubAPIBase(host: c?.host ?? "github.com", scheme: c?.scheme),
                githubAuthHeaders(token: token),
                (c?.path ?? "").split(separator: "/").map(String.init))
    }

    private static func githubTargets(_ project: Project) async throws -> [CreateTarget] {
        let gh = try githubContext(project)
        // A space set to one repository only creates there.
        if gh.path.count >= 2 {
            let repo = "\(gh.path[0])/\(gh.path[1])"
            return [CreateTarget(id: repo, name: repo, types: [])]
        }
        let org = gh.path.first ?? project.githubOrg.flatMap { $0.isEmpty ? nil : $0 }
        let list = org.map { "\(gh.api)/orgs/\($0)/repos?sort=updated&per_page=100" }
            ?? "\(gh.api)/user/repos?sort=updated&per_page=100"
        var names: [String] = []
        for page in 1...3 {
            let rows = try await HTTP.getJSON("\(list)&page=\(page)", headers: gh.headers) as? [[String: Any]] ?? []
            names += rows.filter { ($0["archived"] as? Bool) != true && ($0["has_issues"] as? Bool) != false }
                .compactMap { $0["full_name"] as? String }
            if rows.count < 100 { break }
        }
        // Most recently updated first: the repository wanted is usually one of those.
        return names.map { CreateTarget(id: $0, name: $0, types: []) }
    }

    private static func githubCreate(_ project: Project, repo: String, title: String,
                                     markdown: String, assignToMe: Bool) async throws -> CreatedTicket {
        let gh = try githubContext(project)
        var body: [String: Any] = ["title": title, "body": markdown]
        if assignToMe, let me = try? await HTTP.getJSON("\(gh.api)/user", headers: gh.headers) as? [String: Any],
           let login = me["login"] as? String {
            // GitHub drops an assignee it does not accept instead of refusing the issue.
            body["assignees"] = [login]
        }
        let data = try await HTTP.send("POST", "\(gh.api)/repos/\(repo)/issues", headers: gh.headers, body: body)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let link = json?["html_url"] as? String, let number = json?["number"] as? Int else {
            throw RedmineError(message: "GitHub answered without the new issue's link. Check GitHub before trying again: it may have been created.")
        }
        // The same form as tickets fetched from the "assigned to me" list.
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return CreatedTicket(ref: "\(name)#\(number)", url: link)
    }
}

/// Markdown written in the app, turned into the markup of trackers that do not read Markdown.
/// Covers what a ticket description uses: headings, lists, emphasis, code and links.
enum Markup {
    static func textile(_ markdown: String) -> String { convert(markdown, jira: false) }
    static func jira(_ markdown: String) -> String { convert(markdown, jira: true) }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let heading = rx(#"^(#{1,6})\s+(.*)$"#)
    private static let bullet = rx(#"^(\s*)[-*+]\s+(.*)$"#)
    private static let numbered = rx(#"^(\s*)\d+[.)]\s+(.*)$"#)
    private static let quote = rx(#"^>\s?(.*)$"#)
    private static let bold = rx(#"\*\*(.+?)\*\*|__(.+?)__"#)
    private static let italic = rx(#"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])"#)
    private static let link = rx(#"\[([^\]]+)\]\(([^)\s]+)\)"#)

    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func replace(_ r: NSRegularExpression, _ s: String, _ template: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func convert(_ markdown: String, jira: Bool) -> String {
        var out: [String] = []
        var inCode = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if inCode {
                    out.append(jira ? "{code}" : "</code></pre>")
                } else if jira {
                    out.append(lang.isEmpty ? "{code}" : "{code:\(lang)}")
                } else {
                    out.append(lang.isEmpty ? "<pre><code>" : "<pre><code class=\"\(lang)\">")
                }
                inCode.toggle()
                continue
            }
            if inCode {
                // Inside <pre> Textile still reads HTML.
                out.append(jira ? line : line.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))
                continue
            }
            if let g = groups(heading, line) {
                out.append("h\(g[0].count). \(inline(g[1], jira: jira))")
            } else if let g = groups(bullet, line) {
                out.append(String(repeating: "*", count: g[0].count / 2 + 1) + " " + inline(g[1], jira: jira))
            } else if let g = groups(numbered, line) {
                out.append(String(repeating: "#", count: g[0].count / 2 + 1) + " " + inline(g[1], jira: jira))
            } else if let g = groups(quote, line) {
                out.append("bq. \(inline(g[0], jira: jira))")
            } else if trimmed == "---" || trimmed == "***" {
                out.append("----")
            } else {
                out.append(inline(line, jira: jira))
            }
        }
        if inCode { out.append(jira ? "{code}" : "</code></pre>") }
        return out.joined(separator: "\n")
    }

    /// Emphasis and links, leaving `code` spans as they are.
    private static func inline(_ text: String, jira: Bool) -> String {
        let parts = text.components(separatedBy: "`")
        return parts.enumerated().map { i, part in
            // Odd pieces sit between backticks; an unpaired last backtick is left as typed.
            if i % 2 == 1 {
                guard i < parts.count - 1 else { return "`" + part }
                return jira ? "{{\(part)}}" : "@\(part)@"
            }
            let marker = "\u{1}"
            var s = replace(bold, part, "\(marker)$1$2\(marker)")
            s = replace(italic, s, "_$1_")
            s = s.replacingOccurrences(of: marker, with: "*")
            s = replace(link, s, jira ? "[$1|$2]" : "\"$1\":$2")
            return s
        }.joined()
    }
}
