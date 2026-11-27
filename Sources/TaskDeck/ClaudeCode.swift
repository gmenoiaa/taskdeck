import Foundation

/// Asks Claude through the Claude Code command (`claude -p`) instead of the API key, so the request
/// is charged to the login of a Claude home: the same usage limits its sessions draw from.
/// One question, one structured answer, no tools.
enum ClaudeCode {
    /// The models offered for the review, by the names the command accepts for "the current one".
    static let models: [(id: String, label: String)] = [
        ("haiku", "Haiku — fastest, lightest on the usage limits"),
        ("sonnet", "Sonnet — balanced"),
        ("opus", "Opus — most careful, heaviest on the usage limits"),
    ]
    static let defaultModel = "sonnet"

    struct Answer<Value: Decodable> {
        var value: Value
        /// Everything read, cached parts included.
        var inputTokens: Int
        var outputTokens: Int
        /// What the command says the request would cost at API prices. With a subscription login
        /// nothing is billed; the figure only shows the size.
        var cost: Double?
        var model: String?
    }

    enum Failure: LocalizedError {
        case notInstalled
        case homeMissing(String)
        case notSignedIn(String)
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "The claude command was not found on this Mac."
            case .homeMissing(let home): return "The Claude home “\(home)” is not a directory on this Mac."
            case .notSignedIn(let home): return "Claude Code is not signed in for \(home). Run claude there and use /login."
            case .timedOut: return "Claude did not answer in time."
            case .failed(let text): return text
            }
        }
    }

    static var executable: String? { Shell.find("claude") }
    static var isInstalled: Bool { executable != nil }

    /// What the command needs besides this app's own environment to run as the given Claude home
    /// ("~/.claude-work" as typed; empty for the default one).
    static func environment(home: String) throws -> [String: String] {
        let typed = home.trimmingCharacters(in: .whitespaces)
        // Found here: the folders that hold node, which the login's own hooks may call.
        var environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
        if !typed.isEmpty {
            guard let directory = Sessions.resolvedHome(typed) else { throw Failure.homeMissing(typed) }
            // The default home is not a config directory in the variable's sense: its settings file
            // sits beside it, and naming it makes the command report that nobody is signed in.
            if !isStandardHome(directory) { environment["CLAUDE_CONFIG_DIR"] = directory }
        }
        return environment
    }

    static func isStandardHome(_ directory: String) -> Bool {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        return URL(fileURLWithPath: directory).standardizedFileURL.path == standard
    }

    /// `home` is a Claude home as typed ("~/.claude-work"); empty means the default one.
    /// `schema` is the JSON Schema the answer has to match.
    static func ask<Value: Decodable>(_ type: Value.Type, home: String, model: String, system: String,
                                      user: String, schema: [String: Any]) async throws -> Answer<Value> {
        guard let executable else { throw Failure.notInstalled }
        let typed = home.trimmingCharacters(in: .whitespaces)
        let environment = try environment(home: home)
        let schemaText = String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8) ?? "{}"
        // An empty folder of its own: no project instructions or settings are picked up from it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskdeck-review", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = try await Shell.run(executable, [
            "-p", "--output-format", "json", "--json-schema", schemaText,
            // No tools and no MCP servers: the model only reads what it is given.
            "--tools", "", "--strict-mcp-config", "--no-session-persistence",
            "--model", model, "--system-prompt", system,
        ], environment: environment, input: Data(user.utf8), directory: folder, timeout: 120)
        if result.timedOut { throw Failure.timedOut }

        guard let reply = (try? JSONSerialization.jsonObject(with: result.out)) as? [String: Any] else {
            let raw = [result.err, result.out].compactMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw Failure.failed(raw.map { String($0.prefix(300)) } ?? "claude exited with status \(result.status).")
        }
        if reply["is_error"] as? Bool == true {
            let text = reply["result"] as? String ?? "Claude reported an error."
            if text.localizedCaseInsensitiveContains("not logged in") || text.contains("/login") {
                throw Failure.notSignedIn(typed.isEmpty ? "the default Claude home" : typed)
            }
            throw Failure.failed(text)
        }
        // The structured answer; older versions of the command give it only as text in `result`.
        let payload: Data
        if let structured = reply["structured_output"], !(structured is NSNull) {
            payload = try JSONSerialization.data(withJSONObject: structured)
        } else {
            payload = Data((reply["result"] as? String ?? "").utf8)
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: payload) else {
            throw Failure.failed("Claude's answer was not in the expected form.")
        }
        let usage = reply["usage"] as? [String: Any] ?? [:]
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return Answer(value: value,
                      inputTokens: count("input_tokens") + count("cache_creation_input_tokens") + count("cache_read_input_tokens"),
                      outputTokens: count("output_tokens"),
                      cost: (reply["total_cost_usd"] as? NSNumber)?.doubleValue,
                      model: (reply["modelUsage"] as? [String: Any])?.keys.sorted().first)
    }
}
