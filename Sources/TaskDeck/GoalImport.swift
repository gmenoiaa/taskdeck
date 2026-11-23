import Foundation

/// A ticket that groups others in its tracker, read so a goal can be made from it: a Jira epic, a
/// Redmine parent issue, a GitHub issue with sub-issues, or a GitHub milestone.
struct EpicTickets {
    struct Child: Identifiable, Hashable {
        let ref: String
        let title: String
        let url: String
        let status: String
        let type: String?
        /// Finished in the tracker. Such children are offered but not ticked.
        let closed: Bool
        var id: String { ref.lowercased() }
        var displayRef: String { ref.allSatisfy(\.isNumber) ? "#\(ref)" : ref }
    }

    let ref: String
    let title: String
    let url: String
    let children: [Child]
}

extension TicketFetcher {
    /// What to type to name the parent, per tracker.
    static func epicHint(_ kind: TrackerKind) -> String {
        switch kind {
        case .redmine: return "Parent issue: 12345 or link"
        case .jira: return "Epic or parent: PROJ-123 or link"
        case .github: return "Issue with sub-issues, or a milestone link"
        case .other: return ""
        }
    }

    /// Reads the parent ticket and every ticket under it, closed ones included.
    static func epic(project: Project, input raw: String) async throws -> EpicTickets {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw RedmineError(message: "Type the parent ticket.") }
        switch project.kind {
        case .redmine: return try await redmineEpic(project, input)
        case .jira: return try await jiraEpic(project, input)
        case .github: return try await githubEpic(project, input)
        case .other: throw RedmineError(message: "This space's tracker has no integration.")
        }
    }

    // MARK: Redmine

    private static func redmineEpic(_ project: Project, _ input: String) async throws -> EpicTickets {
        guard let client = RedmineClient(project: project) else { throw missingCredentials }
        let ref = LinkResolver.resolve(input, kind: .redmine, base: project.baseURL).ref
        guard let id = Int(ref) else { throw RedmineError(message: "“\(input)” is not a Redmine issue number.") }
        let headers = ["X-Redmine-API-Key": client.apiKey]
        var children: [EpicTickets.Child] = []
        var offset = 0
        while true {
            let url = "\(client.baseURL)/issues.json?parent_id=\(id)&status_id=*&sort=id&limit=100&offset=\(offset)"
            let json = try await HTTP.getJSON(url, headers: headers) as? [String: Any]
            let issues = (json?["issues"] as? [[String: Any]]) ?? []
            for issue in issues {
                guard let childId = issue["id"] as? Int else { continue }
                let status = issue["status"] as? [String: Any]
                children.append(.init(
                    ref: "\(childId)",
                    title: (issue["subject"] as? String) ?? "",
                    url: "\(client.baseURL)/issues/\(childId)",
                    status: (status?["name"] as? String) ?? "",
                    type: (issue["tracker"] as? [String: Any])?["name"] as? String,
                    // `is_closed` is only in newer Redmine; a closing date says the same on older ones.
                    closed: (status?["is_closed"] as? Bool) ?? (issue["closed_on"] as? String != nil)))
            }
            offset += issues.count
            if issues.isEmpty || offset >= ((json?["total_count"] as? Int) ?? 0) || offset >= 500 { break }
        }
        return EpicTickets(ref: "\(id)", title: try await client.issueSubject(id: id),
                           url: "\(client.baseURL)/issues/\(id)", children: children)
    }

    // MARK: Jira

    private static func jiraEpic(_ project: Project, _ input: String) async throws -> EpicTickets {
        guard let base = jiraBaseURL(project),
              let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw missingCredentials
        }
        let headers = jiraHeaders(project: project, token: token)
        let key = LinkResolver.resolve(input, kind: .jira, base: base).ref.uppercased()
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let parent = try await HTTP.getJSON("\(base)/rest/api/2/issue/\(safeKey)?fields=summary", headers: headers)
        let title = (((parent as? [String: Any])?["fields"] as? [String: Any])?["summary"] as? String) ?? key

        func search(_ jql: String) async throws -> [[String: Any]] {
            let query = "jql=\(jql.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? jql)"
                + "&fields=summary,status,issuetype&maxResults=100"
            let json: Any
            do {
                // Jira Cloud (current endpoint).
                json = try await HTTP.getJSON("\(base)/rest/api/2/search/jql?\(query)", headers: headers)
            } catch {
                // Jira Server / Data Center.
                json = try await HTTP.getJSON("\(base)/rest/api/2/search?\(query)", headers: headers)
            }
            return ((json as? [String: Any])?["issues"] as? [[String: Any]]) ?? []
        }
        // `parent` covers epics on Jira Cloud and sub-tasks everywhere. Older Jira Server links
        // stories to their epic through the "Epic Link" field instead.
        var issues = try await search("parent = \(key) ORDER BY created ASC")
        if issues.isEmpty, let linked = try? await search("\"Epic Link\" = \(key) ORDER BY created ASC") {
            issues = linked
        }
        let children: [EpicTickets.Child] = issues.compactMap { issue in
            guard let childKey = issue["key"] as? String else { return nil }
            let f = (issue["fields"] as? [String: Any]) ?? [:]
            let status = f["status"] as? [String: Any]
            let category = (status?["statusCategory"] as? [String: Any])?["key"] as? String
            return .init(ref: childKey, title: (f["summary"] as? String) ?? "", url: "\(base)/browse/\(childKey)",
                         status: (status?["name"] as? String) ?? "",
                         type: (f["issuetype"] as? [String: Any])?["name"] as? String,
                         closed: category == "done")
        }
        return EpicTickets(ref: key, title: title, url: "\(base)/browse/\(key)", children: children)
    }

    // MARK: GitHub

    private static func githubEpic(_ project: Project, _ input: String) async throws -> EpicTickets {
        let headers = githubAuthHeaders(token: Keychain.get(account: project.keychainAccount))
        let url = input.lowercased().hasPrefix("http")
            ? input : LinkResolver.resolve(input, kind: .github, base: project.baseURL).url
        guard let c = URLComponents(string: url), let host = c.host else {
            throw RedmineError(message: "Paste the issue or milestone link, or type “repo#123”.")
        }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, let number = Int(parts[3]) else {
            throw RedmineError(message: "Could not find the repository and number in “\(input)”.")
        }
        let api = githubAPIBase(host: host, scheme: c.scheme)
        let repo = "\(api)/repos/\(parts[0])/\(parts[1])"

        func child(_ item: [String: Any]) -> EpicTickets.Child? {
            guard let link = item["html_url"] as? String, let p = githubParts(link) else { return nil }
            let isPR = item["pull_request"] != nil
            let state = (item["state"] as? String) ?? "open"
            return .init(ref: "\(p.repo)#\(p.number)", title: (item["title"] as? String) ?? "", url: link,
                         status: isPR ? (state == "open" ? "Open PR" : "Closed PR") : (state == "open" ? "Open issue" : "Closed"),
                         type: (item["type"] as? [String: Any])?["name"] as? String,
                         closed: state != "open")
        }

        if parts[2] == "milestone" {
            let milestone = try await HTTP.getJSON("\(repo)/milestones/\(number)", headers: headers) as? [String: Any]
            var items: [[String: Any]] = []
            for page in 1...5 {
                let batch = try await HTTP.getJSON("\(repo)/issues?milestone=\(number)&state=all&per_page=100&page=\(page)",
                                                   headers: headers) as? [[String: Any]] ?? []
                items += batch
                if batch.count < 100 { break }
            }
            return EpicTickets(ref: "\(parts[1]) milestone", title: (milestone?["title"] as? String) ?? "Milestone \(number)",
                               url: url, children: items.compactMap(child))
        }
        guard ["issues", "pull"].contains(parts[2]) else {
            throw RedmineError(message: "Paste an issue or a milestone link.")
        }
        let issue = try await HTTP.getJSON("\(repo)/issues/\(number)", headers: headers) as? [String: Any]
        let subs = try await HTTP.getJSON("\(repo)/issues/\(number)/sub_issues?per_page=100", headers: headers)
            as? [[String: Any]] ?? []
        return EpicTickets(ref: "\(parts[1])#\(number)", title: (issue?["title"] as? String) ?? "",
                           url: (issue?["html_url"] as? String) ?? url, children: subs.compactMap(child))
    }
}
