import Foundation

/// Claude API client (Messages API over raw HTTP — there is no official Swift SDK).
/// One API key for the whole app, stored in the Keychain and set in Settings.
enum Claude {
    static let defaultModel = "claude-opus-5-5"

    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
        /// Whether the API can re-run a declined request on a fallback model for this model.
        let serverFallback: Bool
    }

    static let models: [Model] = [
        Model(id: "claude-opus-5-5", name: "Claude Opus 5.5", note: "Default. Strong and reasonably priced.", serverFallback: true),
        Model(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", note: "Faster and about half the price of Opus.", serverFallback: true),
        Model(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", note: "Fastest and by far the cheapest.", serverFallback: false),
        Model(id: "claude-fable-5-2", name: "Claude Fable 5.2", note: "Most capable, twice the price of Opus. Not available to zero-data-retention organizations.", serverFallback: true),
    ]
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let keyAccount = "claude-api-key"

    /// Where a key was stored while keys were still per project.
    static func legacyKeyAccount(_ project: Project) -> String { "claude-\(project.id.uuidString)" }

    static func apiKey() -> String? {
        guard let key = Keychain.get(account: keyAccount), !key.isEmpty else { return nil }
        return key
    }

    /// Moves a key saved under a project (the earlier design) to the app-wide setting.
    static func adoptLegacyKey(from projects: [Project]) {
        for project in projects {
            let account = legacyKeyAccount(project)
            guard let old = Keychain.get(account: account), !old.isEmpty else { continue }
            if apiKey() == nil { Keychain.set(old, account: keyAccount) }
            Keychain.delete(account: account)
        }
    }

    /// Streams the text of one response, chunk by chunk.
    static func stream(apiKey: String, model: String, system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 16000,
                        "stream": true,
                        // Rewriting a ticket in plain words is a simple task: low effort keeps it fast and cheap.
                        "output_config": ["effort": "low"],
                        "system": system,
                        "messages": [["role": "user", "content": user]],
                    ]
                    // Lets the API re-run a request the safety classifiers decline on a fallback model.
                    // Unknown model ids (a future addition) are treated like the default model.
                    if models.first(where: { $0.id == model })?.serverFallback ?? true {
                        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                        body["fallbacks"] = "default"
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw RedmineError(message: errorMessage(code: code, body: data))
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        switch event["type"] as? String {
                        case "content_block_delta":
                            let delta = event["delta"] as? [String: Any]
                            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_delta":
                            let stop = (event["delta"] as? [String: Any])?["stop_reason"] as? String
                            if stop == "refusal" {
                                throw RedmineError(message: "Claude declined to answer this request.")
                            }
                            if stop == "max_tokens" {
                                continuation.yield("\n\n*(The answer was cut off because it reached the length limit.)*")
                            }
                        case "error":
                            let message = (event["error"] as? [String: Any])?["message"] as? String
                            throw RedmineError(message: message ?? "The Claude API reported an error mid-response.")
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func errorMessage(code: Int, body: Data) -> String {
        let detail = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        switch code {
        case 401: return "401 — invalid Claude API key.\(suffix)"
        case 403: return "403 — this Claude API key is not allowed to do this.\(suffix)"
        case 429: return "429 — Claude rate limit reached. Try again in a moment.\(suffix)"
        case 529: return "529 — the Claude API is overloaded. Try again in a moment."
        default: return "Claude API error (HTTP \(code))\(suffix)"
        }
    }

    // MARK: Explain a ticket in simple words

    /// The base instructions for a feature plus the user's own standing instructions from Settings.
    static func system(_ base: String, custom: String) -> String {
        let extra = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return base }
        return base + """


        The user of this app has set the standing instructions below. They apply to every answer. \
        Where they conflict with the style or format rules above, follow the user's instructions.

        <user_instructions>
        \(extra)
        </user_instructions>
        """
    }

    static let explainSystem = """
    You rewrite software tickets so they are easy to read. The reader is the developer who will work \
    on the ticket. English may not be the reader's first language, and the reader may read while tired \
    or in a hurry, so plain wording matters more than elegance.

    Write in the style of ASD-STE100 Simplified Technical English:
    - Use short sentences: at most 20 words for an instruction, at most 25 words for a description.
    - Put one idea or one instruction in each sentence.
    - Use the active voice and the simple present, simple past or simple future tense.
    - Use common, simple words. Use each word with one meaning only, and use the same word for the \
    same thing every time.
    - Do not use idioms, metaphors, phrasal verbs or abbreviations that the ticket does not define.
    - Write instructions as commands ("Add the field."). Use lists for steps and for sets of items.
    - Keep technical names exactly as written in the ticket: identifiers, file names, endpoints, \
    error messages, product names and ticket numbers. Put code identifiers in backticks.

    Use only what the ticket says. Do not add requirements, causes or solutions that are not in it. \
    If the ticket is unclear or contradicts itself, say so plainly instead of guessing. When comments \
    change or overrule the description, give the current state and say that it changed.

    Answer in Markdown with these sections, in this order. Leave out a section that has nothing to say:

    ## Summary
    Two or three sentences: what the ticket is about and why it exists.

    ## What to do
    The work that the ticket asks for, as a list.

    ## Done when
    The conditions that show the work is complete, if the ticket gives them.

    ## Current state
    What the comments add: decisions, progress, and who waits for whom.

    ## Not clear
    Questions the ticket leaves open and that the reader must ask someone.

    Start directly with the Summary heading. Write in English, even if the ticket is in another language.
    """

    /// The ticket as plain text for the model: every field, the full description and all comments.
    static func ticketText(task: TaskItem, project: Project?, detail: TicketDetail) -> String {
        var lines: [String] = []
        lines.append("Ticket: \([detail.kindLabel, task.displayRef].compactMap { $0 }.joined(separator: " "))")
        if let project { lines.append("Tracker: \(project.kind.label)") }
        lines.append("Title: \(detail.subject)")
        if let status = detail.status { lines.append("Status: \(status)") }
        for (label, value) in detail.meta { lines.append("\(label): \(value)") }
        lines.append("")
        lines.append("<description>")
        lines.append(detail.description.isEmpty ? "(no description)" : detail.description)
        lines.append("</description>")
        let comments = detail.comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !comments.isEmpty {
            lines.append("")
            lines.append("<comments order=\"oldest first\">")
            for c in comments {
                lines.append("<comment author=\"\(c.author)\" date=\"\(c.date)\">")
                lines.append(c.body)
                lines.append("</comment>")
            }
            lines.append("</comments>")
        }
        return lines.joined(separator: "\n")
    }
}
