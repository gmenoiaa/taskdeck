import Foundation

/// One entry of a ticket's status or assignee menu. What `id` holds depends on the tracker and is
/// only handed back to it: a Redmine number, a Jira transition or account, a GitHub login or option.
struct TrackerChoice: Identifiable, Hashable, Codable {
    let id: String
    let name: String
}

/// What a ticket's status and assignee can be changed to, read from the tracker when the ticket's
/// details open. Nothing here is saved.
struct TicketOptions: Codable {
    var statuses: [TrackerChoice] = []
    /// The name of the status the ticket has now, as the menu shows it.
    var currentStatus: String?
    /// Where the statuses come from when that is not obvious (a GitHub project), or why they are few.
    var statusSource: String?
    var assignees: [TrackerChoice] = []
    var currentAssignees: Set<String> = []
    /// The owner of the space's credentials, for "Assign to me".
    var me: String?
    /// GitHub: a ticket can have several assignees, so picking one adds or removes it.
    var severalAssignees = false
    /// Why the list of people could not be read; the menu then only offers what is known.
    var assigneesNote: String?
}

/// The tracker kept the old status. `via` is a status the ticket can be taken through first, when
/// there is one to offer.
struct StatusRefused: LocalizedError {
    let message: String
    var via: TrackerChoice?
    var errorDescription: String? { message }
}

extension TicketFetcher {
    static func canEdit(_ kind: TrackerKind) -> Bool { kind != .other }

    // MARK: Reading the choices

    static func options(project: Project, ref: String, url: String) async throws -> TicketOptions {
        switch project.kind {
        case .redmine: return try await redmineOptions(project: project, ref: ref)
        case .jira: return try await jiraOptions(project: project, ref: ref, url: url)
        case .github: return try await githubOptions(project: project, url: url)
        case .other: return TicketOptions()
        }
    }

    /// Sets the status. `via` is a status to pass through first (Redmine only), used after the
    /// tracker refused the direct change and the user agreed to the detour.
    static func setStatus(project: Project, ref: String, url: String, to choice: TrackerChoice,
                          via: TrackerChoice? = nil, among statuses: [TrackerChoice] = []) async throws {
        switch project.kind {
        case .redmine:
            try await redmineSetStatus(project: project, ref: ref, to: choice, via: via, among: statuses)
        case .jira:
            let jira = try jiraAccess(project: project, ref: ref, url: url)
            try await HTTP.send("POST", "\(jira.base)/rest/api/2/issue/\(jira.key)/transitions", headers: jira.headers,
                                body: ["transition": ["id": choice.id]])
        case .github:
            try await githubSetStatus(project: project, url: url, to: choice)
        case .other:
            throw RedmineError(message: "This space's tracker has no integration.")
        }
    }

    /// Sets who the ticket is assigned to. Empty means nobody; more than one only on GitHub.
    static func setAssignees(project: Project, ref: String, url: String, to ids: [String]) async throws {
        switch project.kind {
        case .redmine:
            guard let id = Int(ref), let client = RedmineClient(project: project) else { throw missingCredentials }
            // Redmine takes an empty value as "nobody".
            let value: Any = ids.first.flatMap(Int.init) ?? ""
            try await HTTP.send("PUT", "\(client.baseURL)/issues/\(id).json",
                                headers: ["X-Redmine-API-Key": client.apiKey],
                                body: ["issue": ["assigned_to_id": value]])
        case .jira:
            let jira = try jiraAccess(project: project, ref: ref, url: url)
            // Cloud names people by account id, Server and Data Center by user name; the id was
            // saved with its kind in front when the list was read.
            var body: [String: Any] = ["accountId": NSNull()]
            if let first = ids.first {
                let parts = first.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { body = [parts[0]: parts[1]] }
            } else if jira.usesNames {
                body = ["name": NSNull()]
            }
            try await HTTP.send("PUT", "\(jira.base)/rest/api/2/issue/\(jira.key)/assignee", headers: jira.headers, body: body)
        case .github:
            let gh = try githubAccess(project: project, url: url)
            try await HTTP.send("PATCH", "\(gh.api)/repos/\(gh.owner)/\(gh.repo)/issues/\(gh.number)",
                                headers: gh.headers, body: ["assignees": ids])
        case .other:
            throw RedmineError(message: "This space's tracker has no integration.")
        }
    }

    // MARK: Redmine

    private static func redmineOptions(project: Project, ref: String) async throws -> TicketOptions {
        guard let id = Int(ref), let client = RedmineClient(project: project) else { throw missingCredentials }
        let headers = ["X-Redmine-API-Key": client.apiKey]
        let issue = try await client.issue(id: id)
        var options = TicketOptions(currentStatus: issue.status?.name)
        // Every status is listed: this Redmine does not say which ones its workflow allows from
        // here, so a refused one is found by reading the ticket again after the change.
        let json = try await HTTP.getJSON("\(client.baseURL)/issue_statuses.json", headers: headers) as? [String: Any]
        options.statuses = ((json?["issue_statuses"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
            return TrackerChoice(id: String(id), name: name)
        }
        if let current = issue.assigned_to?.id { options.currentAssignees = [String(current)] }
        options.me = (try? await client.currentUserId()).map(String.init)
        var people: [TrackerChoice] = []
        if let projectId = issue.project?.id {
            do {
                let json = try await HTTP.getJSON("\(client.baseURL)/projects/\(projectId)/memberships.json?limit=100",
                                                  headers: headers) as? [String: Any]
                people = ((json?["memberships"] as? [[String: Any]]) ?? []).compactMap { row in
                    guard let user = row["user"] as? [String: Any], let id = user["id"] as? Int,
                          let name = user["name"] as? String else { return nil }
                    return TrackerChoice(id: String(id), name: name)
                }
            } catch {
                options.assigneesNote = "Could not read the project's members: \(error.localizedDescription)"
            }
        }
        // The current assignee stays in the list even when the members could not be read.
        if let current = issue.assigned_to, let id = current.id, !people.contains(where: { $0.id == String(id) }) {
            people.append(TrackerChoice(id: String(id), name: current.name))
        }
        options.assignees = sorted(people)
        return options
    }

    /// Sets a Redmine ticket's estimate and, when it has the field, its dev estimate. Nil clears.
    /// Redmine answers "ok" even when it ignores a field the role may not edit, so the ticket is
    /// read again and compared.
    static func setEstimates(project: Project, ref: String, estimate: Double?,
                             dev: TicketDetail.DevEstimate?) async throws {
        guard let id = Int(ref), let client = RedmineClient(project: project) else { throw missingCredentials }
        func text(_ hours: Double?) -> String { hours.map { String(format: "%g", $0) } ?? "" }
        var issue: [String: Any] = ["estimated_hours": text(estimate)]
        if let dev { issue["custom_fields"] = [["id": dev.fieldId, "value": text(dev.hours)]] }
        try await HTTP.send("PUT", "\(client.baseURL)/issues/\(id).json",
                            headers: ["X-Redmine-API-Key": client.apiKey], body: ["issue": issue])
        let after = try await client.issue(id: id)
        func same(_ a: Double?, _ b: Double?) -> Bool { abs((a ?? 0) - (b ?? 0)) < 0.005 }
        var kept: [String] = []
        if !same(after.estimated_hours, estimate) { kept.append("estimate") }
        if let dev {
            let value = after.custom_fields?.first { $0.id == dev.fieldId }?.value ?? ""
            if !same(Double(value.replacingOccurrences(of: ",", with: ".")), dev.hours) { kept.append("dev estimate") }
        }
        if !kept.isEmpty {
            throw RedmineError(message: "Redmine did not change the \(kept.joined(separator: " or the ")). Your role may not be allowed to edit it on this ticket.")
        }
    }

    private static func redmineSetStatus(project: Project, ref: String, to choice: TrackerChoice,
                                         via: TrackerChoice?, among statuses: [TrackerChoice]) async throws {
        guard let id = Int(ref), let target = Int(choice.id), let client = RedmineClient(project: project) else {
            throw missingCredentials
        }
        // Redmine answers "ok" and changes nothing when its workflow does not allow a step, so the
        // ticket is read again after each change to see what happened.
        func put(_ status: Int) async throws -> RedmineClient.IssueDetail {
            try await HTTP.send("PUT", "\(client.baseURL)/issues/\(id).json",
                                headers: ["X-Redmine-API-Key": client.apiKey],
                                body: ["issue": ["status_id": status]])
            return try await client.issue(id: id)
        }
        if let via, let step = Int(via.id) {
            let middle = try await put(step)
            guard middle.status?.id == step else {
                throw StatusRefused(message: "Redmine kept the status “\(middle.status?.name ?? "?")”. Its workflow does not allow “\(via.name)” from there either.")
            }
            let after = try await put(target)
            guard after.status?.id == target else {
                throw StatusRefused(message: "The ticket is now “\(via.name)”, but Redmine's workflow does not allow “\(choice.name)” from there.")
            }
            return
        }
        let now = try await put(target)
        guard now.status?.id != target else { return }
        // Workflows often only reach a later status from in progress.
        let detour = statuses.first { $0.name.caseInsensitiveCompare("In Progress") == .orderedSame }
            ?? statuses.first { $0.name.localizedCaseInsensitiveContains("progress") }
        let usable = detour.flatMap { $0.id != choice.id && Int($0.id) != now.status?.id ? $0 : nil }
        throw StatusRefused(message: "Redmine kept the status “\(now.status?.name ?? "?")”. Its workflow does not allow “\(choice.name)” from there.",
                            via: usable)
    }

    // MARK: Jira

    private struct JiraAccess {
        let base: String
        let key: String
        let headers: [String: String]
        /// Server and Data Center, where people are named by user name and not by account id.
        var usesNames = false
    }

    private static func jiraAccess(project: Project, ref: String, url: String) throws -> JiraAccess {
        let linkHost = URLComponents(string: url).flatMap { c in
            c.scheme.flatMap { scheme in c.host.map { "\(scheme)://\($0)" } }
        }
        guard let base = jiraBaseURL(project) ?? linkHost,
              let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw missingCredentials
        }
        let user = (project.username ?? "").trimmingCharacters(in: .whitespaces)
        return JiraAccess(base: base, key: ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref,
                          headers: jiraHeaders(project: project, token: token),
                          // A personal access token without a user name is how Server is set up here.
                          usesNames: user.isEmpty)
    }

    private static func jiraPerson(_ row: [String: Any]) -> TrackerChoice? {
        let name = (row["displayName"] as? String) ?? (row["name"] as? String) ?? ""
        if let account = row["accountId"] as? String { return TrackerChoice(id: "accountId:\(account)", name: name) }
        if let login = row["name"] as? String { return TrackerChoice(id: "name:\(login)", name: name) }
        return nil
    }

    private static func jiraOptions(project: Project, ref: String, url: String) async throws -> TicketOptions {
        let jira = try jiraAccess(project: project, ref: ref, url: url)
        let issue = try await HTTP.getJSON("\(jira.base)/rest/api/2/issue/\(jira.key)?fields=status,assignee",
                                           headers: jira.headers) as? [String: Any]
        let fields = issue?["fields"] as? [String: Any]
        var options = TicketOptions(currentStatus: (fields?["status"] as? [String: Any])?["name"] as? String)
        // Jira only moves a ticket along its workflow, so the menu holds the steps open from here.
        let json = try await HTTP.getJSON("\(jira.base)/rest/api/2/issue/\(jira.key)/transitions", headers: jira.headers) as? [String: Any]
        options.statuses = ((json?["transitions"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let id = row["id"] as? String,
                  let name = ((row["to"] as? [String: Any])?["name"] as? String) ?? (row["name"] as? String) else { return nil }
            return TrackerChoice(id: id, name: name)
        }
        options.statusSource = "Jira lists only the steps its workflow allows from the current status."
        let current = (fields?["assignee"] as? [String: Any]).flatMap(jiraPerson)
        if let current { options.currentAssignees = [current.id] }
        if let me = try? await HTTP.getJSON("\(jira.base)/rest/api/2/myself", headers: jira.headers) as? [String: Any] {
            options.me = jiraPerson(me)?.id
        }
        var people: [TrackerChoice] = []
        do {
            let rows = try await HTTP.getJSON("\(jira.base)/rest/api/2/user/assignable/search?issueKey=\(jira.key)&maxResults=100",
                                              headers: jira.headers) as? [[String: Any]] ?? []
            people = rows.compactMap(jiraPerson)
        } catch {
            options.assigneesNote = "Could not read who can be assigned: \(error.localizedDescription)"
        }
        if let current, !people.contains(where: { $0.id == current.id }) { people.append(current) }
        options.assignees = sorted(people)
        return options
    }

    // MARK: GitHub

    private struct GitHubAccess {
        let api: String
        let owner: String
        let repo: String
        let number: Int
        let headers: [String: String]
        var graphQL: String {
            // GitHub Enterprise serves GraphQL beside its REST root, not under it.
            api == "https://api.github.com" ? "\(api)/graphql" : api.replacingOccurrences(of: "/api/v3", with: "/api/graphql")
        }
    }

    private static func githubAccess(project: Project, url: String) throws -> GitHubAccess {
        guard let p = githubParts(url) else {
            throw RedmineError(message: "Could not find the repository and number in the ticket link.")
        }
        guard let token = Keychain.get(account: project.keychainAccount), !token.isEmpty else {
            throw RedmineError(message: "To change a ticket, set a GitHub token in Settings → Spaces.")
        }
        return GitHubAccess(api: p.api, owner: p.owner, repo: p.repo, number: p.number,
                            headers: githubAuthHeaders(token: token))
    }

    /// The ticket's place in the first GitHub project that has a "Status" field: where an issue's
    /// real status usually lives, since the issue itself is only open or closed.
    struct GitHubProjectStatus {
        let project: String
        let projectId: String
        let itemId: String
        let fieldId: String
        let current: String?
        let options: [TrackerChoice]
    }

    private static func graphQL(_ gh: GitHubAccess, _ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        let data = try await HTTP.send("POST", gh.graphQL, headers: gh.headers, body: ["query": query, "variables": variables])
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        // GraphQL reports a missing permission inside a successful answer.
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first?["message"] as? String,
           json["data"] == nil || json["data"] is NSNull || first.localizedCaseInsensitiveContains("scope") {
            throw RedmineError(message: first)
        }
        return (json["data"] as? [String: Any]) ?? [:]
    }

    static func githubProjectStatus(project: Project, url: String) async throws -> GitHubProjectStatus? {
        let gh = try githubAccess(project: project, url: url)
        let item = """
            projectItems(first: 10) { nodes { id
              project { id title field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } } }
              fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
            } }
            """
        let query = """
            query($owner: String!, $repo: String!, $number: Int!) {
              repository(owner: $owner, name: $repo) { issueOrPullRequest(number: $number) {
                ... on Issue { \(item) }
                ... on PullRequest { \(item) }
              } }
            }
            """
        let data = try await graphQL(gh, query, ["owner": gh.owner, "repo": gh.repo, "number": gh.number])
        let ticket = (data["repository"] as? [String: Any])?["issueOrPullRequest"] as? [String: Any]
        let nodes = ((ticket?["projectItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        for node in nodes {
            guard let itemId = node["id"] as? String, let board = node["project"] as? [String: Any],
                  let projectId = board["id"] as? String, let field = board["field"] as? [String: Any],
                  let fieldId = field["id"] as? String else { continue }
            let options = ((field["options"] as? [[String: Any]]) ?? []).compactMap { row -> TrackerChoice? in
                guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                return TrackerChoice(id: id, name: name)
            }
            guard !options.isEmpty else { continue }
            return GitHubProjectStatus(project: (board["title"] as? String) ?? "project", projectId: projectId,
                                       itemId: itemId, fieldId: fieldId,
                                       current: (node["fieldValueByName"] as? [String: Any])?["name"] as? String,
                                       options: options)
        }
        return nil
    }

    private static let githubOpen = TrackerChoice(id: "state:open", name: "Open")
    private static let githubClosed = TrackerChoice(id: "state:closed", name: "Closed")

    private static func githubOptions(project: Project, url: String) async throws -> TicketOptions {
        let gh = try githubAccess(project: project, url: url)
        let path = "\(gh.api)/repos/\(gh.owner)/\(gh.repo)"
        let issue = (try await HTTP.getJSON("\(path)/issues/\(gh.number)", headers: gh.headers) as? [String: Any]) ?? [:]
        var options = TicketOptions(severalAssignees: true)
        let closed = (issue["state"] as? String) == "closed"
        var projectNote: String?
        do {
            if let status = try await githubProjectStatus(project: project, url: url) {
                // The option alone is not enough to change it: the project, item and field go along.
                options.statuses = status.options.map {
                    TrackerChoice(id: "project:\(status.projectId)|\(status.itemId)|\(status.fieldId)|\($0.id)", name: $0.name)
                }
                options.currentStatus = status.current
                options.statusSource = "Status in the GitHub project “\(status.project)”."
            } else {
                projectNote = "This ticket is in no GitHub project with a Status field, so it can only be opened or closed."
            }
        } catch {
            projectNote = "Could not read the ticket's GitHub project (\(error.localizedDescription)), so it can only be opened or closed. The token needs the “project” scope."
        }
        if options.statuses.isEmpty {
            options.statuses = [githubOpen, githubClosed]
            options.currentStatus = closed ? githubClosed.name : githubOpen.name
            options.statusSource = projectNote
        }
        options.currentAssignees = Set(((issue["assignees"] as? [[String: Any]]) ?? []).compactMap { $0["login"] as? String })
        if let me = try? await HTTP.getJSON("\(gh.api)/user", headers: gh.headers) as? [String: Any] {
            options.me = me["login"] as? String
        }
        var people: [TrackerChoice] = []
        do {
            let rows = try await HTTP.getJSON("\(path)/assignees?per_page=100", headers: gh.headers) as? [[String: Any]] ?? []
            people = rows.compactMap { ($0["login"] as? String).map { TrackerChoice(id: $0, name: $0) } }
        } catch {
            options.assigneesNote = "Could not read who can be assigned: \(error.localizedDescription)"
        }
        for login in options.currentAssignees where !people.contains(where: { $0.id == login }) {
            people.append(TrackerChoice(id: login, name: login))
        }
        options.assignees = sorted(people)
        return options
    }

    private static func githubSetStatus(project: Project, url: String, to choice: TrackerChoice) async throws {
        let gh = try githubAccess(project: project, url: url)
        if choice.id.hasPrefix("state:") {
            try await HTTP.send("PATCH", "\(gh.api)/repos/\(gh.owner)/\(gh.repo)/issues/\(gh.number)",
                                headers: gh.headers, body: ["state": String(choice.id.dropFirst(6))])
            return
        }
        let parts = choice.id.dropFirst("project:".count).split(separator: "|").map(String.init)
        guard parts.count == 4 else { throw RedmineError(message: "Unknown status “\(choice.name)”.") }
        let mutation = """
            mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
              updateProjectV2ItemFieldValue(input: { projectId: $project, itemId: $item, fieldId: $field,
                                                     value: { singleSelectOptionId: $option } }) { projectV2Item { id } }
            }
            """
        let data = try await graphQL(gh, mutation, ["project": parts[0], "item": parts[1], "field": parts[2], "option": parts[3]])
        guard data["updateProjectV2ItemFieldValue"] is [String: Any] else {
            throw RedmineError(message: "GitHub did not change the status. The token needs the “project” scope.")
        }
    }

    private static func sorted(_ people: [TrackerChoice]) -> [TrackerChoice] {
        people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
