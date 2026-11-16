import Foundation

/// A status a ticket can have in its tracker. `id` is what the space saves for a column: Redmine's
/// status number, or the status name in Jira, where a status is reached through a transition.
struct TrackerStatus: Identifiable, Hashable {
    let id: String
    let name: String
}

extension TicketFetcher {
    /// Whether moving a card can change the ticket's status in this kind of tracker.
    static func canSetStatus(_ kind: TrackerKind) -> Bool { kind == .redmine || kind == .jira }

    /// The statuses the tracker knows, for choosing one per board column.
    static func statuses(project: Project) async throws -> [TrackerStatus] {
        switch project.kind {
        case .redmine:
            guard let client = RedmineClient(project: project) else { throw missingCredentials }
            let json = try await HTTP.getJSON("\(client.baseURL)/issue_statuses.json",
                                              headers: ["X-Redmine-API-Key": client.apiKey]) as? [String: Any]
            let rows = json?["issue_statuses"] as? [[String: Any]] ?? []
            return rows.compactMap { row in
                guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
                return TrackerStatus(id: String(id), name: name)
            }
        case .jira:
            guard let base = jiraBaseURL(project),
                  let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
                throw missingCredentials
            }
            let rows = try await HTTP.getJSON("\(base)/rest/api/2/status",
                                              headers: jiraHeaders(project: project, token: token)) as? [[String: Any]] ?? []
            // Jira lists a status once per workflow that uses it.
            let names = Set(rows.compactMap { $0["name"] as? String })
            return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { TrackerStatus(id: $0, name: $0) }
        case .github, .other:
            return []
        }
    }

    /// Sets the ticket's status and returns the name the tracker now shows. When the tracker has no
    /// direct step to it and `via` is given (the status of the In progress column), the ticket is
    /// taken through that status first: workflows often only reach review from in progress.
    /// Throws when the tracker still refuses.
    static func setStatus(project: Project, ref: String, url: String, to value: String,
                          via: String? = nil) async throws -> String {
        switch project.kind {
        case .redmine:
            guard let id = Int(ref), let statusId = Int(value) else {
                throw RedmineError(message: "Ticket “\(ref)” is not a Redmine issue number.")
            }
            guard let client = RedmineClient(project: project) else { throw missingCredentials }
            let before = try await client.issue(id: id)
            if before.status?.id == statusId { return before.status?.name ?? "" }
            // Redmine answers "ok" and changes nothing when its workflow does not allow a step, so
            // the ticket is read again after each change to see what happened.
            func put(_ status: Int) async throws -> RedmineClient.IssueDetail {
                try await HTTP.send("PUT", "\(client.baseURL)/issues/\(id).json",
                                    headers: ["X-Redmine-API-Key": client.apiKey],
                                    body: ["issue": ["status_id": status]])
                return try await client.issue(id: id)
            }
            var now = before
            // Where Redmine lists the allowed statuses, a step it forbids is not even tried.
            let direct = before.allowed_statuses.map { $0.contains { $0.id == statusId } } ?? true
            if direct { now = try await put(statusId) }
            if now.status?.id != statusId, let step = via.flatMap(Int.init), step != statusId, now.status?.id != step {
                now = try await put(step)
                if now.status?.id == step { now = try await put(statusId) }
            }
            guard now.status?.id == statusId else {
                let others = (now.allowed_statuses ?? []).filter { $0.id != now.status?.id }.map(\.name)
                throw RedmineError(message: "Redmine kept the status “\(now.status?.name ?? "?")”. Its workflow does not allow the status chosen for this column from there."
                                   + (others.isEmpty ? "" : " From here the ticket can go to: \(others.joined(separator: ", ")).") )
            }
            return now.status?.name ?? ""
        case .jira:
            // The space's base URL, or the ticket link's own host when none is set.
            let linkHost = URLComponents(string: url).flatMap { c in
                c.scheme.flatMap { scheme in c.host.map { "\(scheme)://\($0)" } }
            }
            guard let base = jiraBaseURL(project) ?? linkHost,
                  let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
                throw missingCredentials
            }
            let headers = jiraHeaders(project: project, token: token)
            let key = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
            func current() async throws -> String {
                let issue = try await HTTP.getJSON("\(base)/rest/api/2/issue/\(key)?fields=status", headers: headers) as? [String: Any]
                return ((issue?["fields"] as? [String: Any])?["status"] as? [String: Any])?["name"] as? String ?? ""
            }
            /// The names reachable from where the ticket is; takes the step to `name` when there is one.
            func step(to name: String) async throws -> (taken: Bool, reachable: [String]) {
                let json = try await HTTP.getJSON("\(base)/rest/api/2/issue/\(key)/transitions", headers: headers) as? [String: Any]
                let transitions = json?["transitions"] as? [[String: Any]] ?? []
                let reachable = transitions.compactMap { ($0["to"] as? [String: Any])?["name"] as? String }
                guard let found = transitions.first(where: {
                    (($0["to"] as? [String: Any])?["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
                }), let stepId = found["id"] as? String else { return (false, reachable) }
                try await HTTP.send("POST", "\(base)/rest/api/2/issue/\(key)/transitions", headers: headers,
                                    body: ["transition": ["id": stepId]])
                return (true, reachable)
            }
            let start = try await current()
            if start.caseInsensitiveCompare(value) == .orderedSame { return start }
            var attempt = try await step(to: value)
            if !attempt.taken, let via, via.caseInsensitiveCompare(value) != .orderedSame,
               start.caseInsensitiveCompare(via) != .orderedSame, try await step(to: via).taken {
                attempt = try await step(to: value)
            }
            guard attempt.taken else {
                let here = try await current()
                throw RedmineError(message: "Jira has no step from “\(here)” to “\(value)”."
                                   + (attempt.reachable.isEmpty ? "" : " From here it can go to: \(attempt.reachable.joined(separator: ", ")).") )
            }
            return try await current()
        case .github, .other:
            throw RedmineError(message: "This space's tracker has no statuses to set.")
        }
    }
}
