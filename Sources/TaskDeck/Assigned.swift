import Foundation

/// An open ticket assigned to me in some tracker, not necessarily on the board yet.
struct RemoteTicket: Identifiable, Hashable, Codable {
    let projectId: UUID
    let ref: String
    let title: String
    let url: String
    let status: String
    /// Project/repository inside the tracker.
    let context: String
    let updated: String
    /// Bug, Story, Epic… as the tracker names it. Optional so lists saved before it existed load.
    var type: String? = nil

    var id: String { "\(projectId.uuidString)|\(ref.lowercased())" }
    var displayRef: String { ref.allSatisfy(\.isNumber) ? "#\(ref)" : ref }
}

extension TicketFetcher {
    private static func q(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Open tickets assigned to the owner of the project's credentials, most recent first.
    static func assigned(project: Project) async throws -> [RemoteTicket] {
        switch project.kind {
        case .redmine: return try await assignedRedmine(project)
        case .jira: return try await assignedJira(project)
        case .github: return try await assignedGitHub(project)
        case .other: return []
        }
    }

    private static func assignedRedmine(_ project: Project) async throws -> [RemoteTicket] {
        guard let client = RedmineClient(project: project) else { throw missingCredentials }
        var out: [RemoteTicket] = []
        var offset = 0
        while true {
            let url = "\(client.baseURL)/issues.json?assigned_to_id=me&status_id=open&sort=\(q("updated_on:desc"))&limit=100&offset=\(offset)"
            let json = try await HTTP.getJSON(url, headers: ["X-Redmine-API-Key": client.apiKey]) as? [String: Any]
            let issues = (json?["issues"] as? [[String: Any]]) ?? []
            for issue in issues {
                guard let id = issue["id"] as? Int else { continue }
                out.append(RemoteTicket(
                    projectId: project.id,
                    ref: "\(id)",
                    title: (issue["subject"] as? String) ?? "",
                    url: "\(client.baseURL)/issues/\(id)",
                    status: ((issue["status"] as? [String: Any])?["name"] as? String) ?? "",
                    context: ((issue["project"] as? [String: Any])?["name"] as? String) ?? "",
                    updated: RedmineDate.pretty(issue["updated_on"] as? String),
                    type: (issue["tracker"] as? [String: Any])?["name"] as? String))
            }
            offset += issues.count
            if issues.isEmpty || offset >= ((json?["total_count"] as? Int) ?? 0) || offset >= 500 { break }
        }
        return out
    }

    private static func assignedJira(_ project: Project) async throws -> [RemoteTicket] {
        guard let base = jiraBaseURL(project),
              let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw missingCredentials
        }
        let headers = jiraHeaders(project: project, token: token)
        let query = "jql=\(q("assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"))"
            + "&fields=\(q("summary,status,issuetype,project,updated"))&maxResults=100"
        let json: Any
        do {
            // Jira Cloud (current endpoint).
            json = try await HTTP.getJSON("\(base)/rest/api/2/search/jql?\(query)", headers: headers)
        } catch {
            // Jira Server / Data Center.
            json = try await HTTP.getJSON("\(base)/rest/api/2/search?\(query)", headers: headers)
        }
        let issues = ((json as? [String: Any])?["issues"] as? [[String: Any]]) ?? []
        return issues.compactMap { issue in
            guard let key = issue["key"] as? String else { return nil }
            let f = (issue["fields"] as? [String: Any]) ?? [:]
            return RemoteTicket(
                projectId: project.id,
                ref: key,
                title: (f["summary"] as? String) ?? "",
                url: "\(base)/browse/\(key)",
                status: ((f["status"] as? [String: Any])?["name"] as? String) ?? "",
                context: ((f["project"] as? [String: Any])?["name"] as? String) ?? "",
                updated: RedmineDate.pretty(f["updated"] as? String),
                type: (f["issuetype"] as? [String: Any])?["name"] as? String)
        }
    }

    private static func assignedGitHub(_ project: Project) async throws -> [RemoteTicket] {
        guard let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw RedmineError(message: "To list what is assigned to you, set a GitHub token in Settings → Spaces.")
        }
        let c = URLComponents(string: project.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let api = githubAPIBase(host: c?.host ?? "github.com", scheme: c?.scheme)
        let parts = (c?.path ?? "").split(separator: "/").map(String.init)
        var scope = ""
        if parts.count >= 2 {
            scope = " repo:\(parts[0])/\(parts[1])"
        } else if parts.count == 1 {
            scope = " org:\(parts[0])"
        }
        // GitHub search requires is:issue or is:pr, so this takes two queries.
        var items: [[String: Any]] = []
        for type in ["is:issue", "is:pr"] {
            let search = "\(type) is:open assignee:@me\(scope)"
            let url = "\(api)/search/issues?q=\(q(search))&sort=updated&order=desc&per_page=100"
            let json = try await HTTP.getJSON(url, headers: githubAuthHeaders(token: token)) as? [String: Any]
            items += (json?["items"] as? [[String: Any]]) ?? []
        }
        items.sort { (($0["updated_at"] as? String) ?? "") > (($1["updated_at"] as? String) ?? "") }
        return items.compactMap { item in
            guard let link = item["html_url"] as? String, let p = githubParts(link) else { return nil }
            let isPR = item["pull_request"] != nil
            return RemoteTicket(
                projectId: project.id,
                ref: "\(p.repo)#\(p.number)",
                title: (item["title"] as? String) ?? "",
                url: link,
                status: isPR ? "Open PR" : "Open issue",
                context: "\(p.owner)/\(p.repo)",
                updated: RedmineDate.pretty(item["updated_at"] as? String),
                // Only a type someone set (Bug, Epic…): the status already says issue or pull request.
                type: (item["type"] as? [String: Any])?["name"] as? String)
        }
    }
}
