import Foundation
import Security

enum Keychain {
    private static let service = "local.taskdeck"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// In-memory cache: each key is read from the Keychain at most once per run.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func get(account: String) -> String? {
        lock.lock()
        let cached = cache[account]
        lock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }

        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        cache[account] = value
        lock.unlock()
        // Items created by old builds (ad-hoc signature) are rewritten once,
        // so they belong to the stable signature and stop asking for the password.
        let flag = "keychain-owned-\(account)"
        if !UserDefaults.standard.bool(forKey: flag) {
            SecItemDelete(query(account) as CFDictionary)
            var add = query(account)
            add[kSecValueData as String] = data
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
                UserDefaults.standard.set(true, forKey: flag)
            }
        }
        return value
    }

    static func set(_ value: String, account: String) {
        lock.lock()
        let unchanged = cache[account] == value
        cache[account] = value
        lock.unlock()
        if unchanged { return }
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.set(true, forKey: "keychain-owned-\(account)")
        }
    }

    static func delete(account: String) {
        lock.lock()
        cache[account] = nil
        lock.unlock()
        SecItemDelete(query(account) as CFDictionary)
    }
}

struct RedmineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RedmineClient {
    let baseURL: String
    let apiKey: String

    struct Activity: Identifiable, Decodable, Hashable {
        let id: Int
        let name: String
        let is_default: Bool?
        let active: Bool?
    }

    init?(project: Project) {
        var base = project.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard project.kind == .redmine, !base.isEmpty,
              let key = Keychain.get(account: project.keychainAccount), !key.isEmpty else { return nil }
        baseURL = base
        apiKey = key
    }

    init(baseURL: String, apiKey: String) {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.apiKey = apiKey
    }

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw RedmineError(message: "Invalid URL: \(baseURL + path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(apiKey, forHTTPHeaderField: "X-Redmine-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var detail = ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = obj["errors"] as? [String] {
                detail = errors.joined(separator: "; ")
            }
            switch code {
            case 401: throw RedmineError(message: "401 — invalid API key.")
            case 403: throw RedmineError(message: "403 — not allowed to do this.")
            case 404: throw RedmineError(message: "404 — not found.")
            default: throw RedmineError(message: "HTTP \(code)" + (detail.isEmpty ? "" : " — \(detail)"))
            }
        }
        return data
    }

    func issueSubject(id: Int) async throws -> String {
        struct Wrapper: Decodable {
            struct Issue: Decodable { let subject: String }
            let issue: Issue
        }
        let data = try await send("/issues/\(id).json")
        return try JSONDecoder().decode(Wrapper.self, from: data).issue.subject
    }

    struct Named: Decodable, Hashable {
        let id: Int?
        let name: String
    }

    struct Journal: Decodable, Identifiable {
        let id: Int
        let user: Named?
        let notes: String?
        let created_on: String?
    }

    struct IssueDetail: Decodable {
        let id: Int
        let subject: String
        let description: String?
        let status: Named?
        let priority: Named?
        let tracker: Named?
        let project: Named?
        let author: Named?
        let assigned_to: Named?
        let done_ratio: Int?
        let estimated_hours: Double?
        let spent_hours: Double?
        let total_spent_hours: Double?
        let created_on: String?
        let updated_on: String?
        let due_date: String?
        let journals: [Journal]?
        let parent: Parent?
        let custom_fields: [CustomField]?

        struct Parent: Decodable { let id: Int }

        struct CustomField: Decodable {
            let id: Int
            let name: String
            /// Nil for an empty field, and for a list field, whose value is not a single text.
            let value: String?

            private enum CodingKeys: String, CodingKey { case id, name, value }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(Int.self, forKey: .id)
                name = try c.decode(String.self, forKey: .name)
                value = try? c.decode(String.self, forKey: .value)
            }
        }
    }

    struct SpentEntry: Decodable, Identifiable {
        let id: Int
        let hours: Double
        let comments: String?
        let spent_on: String
        let activity: Named?
    }

    func issue(id: Int) async throws -> IssueDetail {
        struct Wrapper: Decodable { let issue: IssueDetail }
        let data = try await send("/issues/\(id).json?include=journals")
        return try JSONDecoder().decode(Wrapper.self, from: data).issue
    }

    /// Id of the API key's owner.
    func currentUserId() async throws -> Int {
        struct Wrapper: Decodable {
            struct User: Decodable { let id: Int }
            let user: User
        }
        return try JSONDecoder().decode(Wrapper.self, from: try await send("/users/current.json")).user.id
    }

    /// Hours logged by the API key's owner on this issue (most recent first).
    func myTimeEntries(issueId: Int) async throws -> [SpentEntry] {
        struct Wrapper: Decodable {
            let time_entries: [SpentEntry]
            let total_count: Int?
        }
        var all: [SpentEntry] = []
        var offset = 0
        while true {
            let data = try await send("/time_entries.json?issue_id=\(issueId)&user_id=me&limit=100&offset=\(offset)")
            let page = try JSONDecoder().decode(Wrapper.self, from: data)
            all += page.time_entries
            offset += page.time_entries.count
            if page.time_entries.isEmpty || offset >= (page.total_count ?? 0) || offset >= 1000 { break }
        }
        return all.sorted { $0.spent_on > $1.spent_on }
    }

    func activities() async throws -> [Activity] {
        struct Wrapper: Decodable { let time_entry_activities: [Activity] }
        let data = try await send("/enumerations/time_entry_activities.json")
        return try JSONDecoder().decode(Wrapper.self, from: data)
            .time_entry_activities.filter { $0.active ?? true }
    }

    func logTime(issueId: Int, hours: Double, day: Date, activityId: Int?, comments: String) async throws {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        var entry: [String: Any] = [
            "issue_id": issueId,
            "hours": (hours * 100).rounded() / 100,
            "spent_on": df.string(from: day),
            "comments": comments,
        ]
        if let activityId { entry["activity_id"] = activityId }
        _ = try await send("/time_entries.json", method: "POST", body: ["time_entry": entry])
    }
}
