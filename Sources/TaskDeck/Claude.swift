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
    // MARK: Where a goal stands

    static let goalSystem = """
    You write a short status report on one goal for the developer who looks after it. A goal \
    groups several tickets, from one or more issue trackers. You get the goal, its tickets with \
    their board column, tracker status, time tracked and agent sessions, and the description and \
    latest comments of the tickets the developer has opened in the app.

    Use plain English: short sentences, active voice, common words, one idea per sentence. Keep \
    ticket numbers, names and technical terms exactly as written.

    Use only what you are given. Do not invent progress, dates or reasons. When the tickets do not \
    say something, say that it is not known. A ticket in a done column, or closed or merged in its \
    tracker, is finished.

    Answer in Markdown with these sections, in this order. Leave out a section that has nothing to say:

    ## Where it stands
    Two or three sentences: how far the goal is, and whether it is on track for its due date if it has one.

    ## Done
    Finished tickets, as a short list.

    ## In progress
    Tickets being worked on, and what each one waits for.

    ## Blocked or waiting
    Tickets that wait for a person, a decision or another ticket, and on whom.

    ## Next steps
    What the developer should do next, most important first. At most five items.

    Start directly with the first heading.
    """

    /// The goal as plain text for the model. Private notes are left out: the goal's own notes and
    /// every task's notes. The goal's links, mails and documents go by their titles only.
    @MainActor
    static func goalText(_ goal: Goal, store: AppStore) -> String {
        func clip(_ text: String, _ limit: Int) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > limit ? String(trimmed.prefix(limit)) + " […]" : trimmed
        }
        let now = Date()
        var out = "Goal: \(goal.displayName)\nStatus: \(goal.status.label)\nToday: \(now.formatted(date: .complete, time: .omitted))\n"
        if let due = goal.due { out += "Due: \(due.formatted(date: .complete, time: .omitted))\n" }
        if !goal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "About the goal:\n\(clip(goal.summary, 2000))\n"
        }
        let pointers = goal.items.filter { $0.kind != .note }
        if !pointers.isEmpty {
            out += "\nLinks, mails and documents kept with the goal (titles only):\n"
            for item in pointers { out += "- \(item.kind.rawValue): \(item.displayTitle)\n" }
        }
        let tasks = store.tasks(of: goal.id)
        out += "\nTickets (\(tasks.count)):\n"
        for task in tasks {
            let space = store.project(task.projectId)
            out += "\n### \(task.displayRef.isEmpty ? "(no ticket)" : task.displayRef) \(task.title)\n"
            var facts: [String] = []
            if let space { facts.append("Tracker: \(space.kind.label) (\(space.name))") }
            facts.append("Board column: " + (task.archived ? "archived" : store.column(task.status)?.displayName ?? task.status)
                         + (store.isDone(task) ? " (finished)" : ""))
            if let status = task.remoteStatus { facts.append("Tracker status: \(status)") }
            if let type = task.remoteType { facts.append("Type: \(type)") }
            if let assignee = task.remoteAssignee { facts.append("Assigned to: \(assignee)") }
            if let due = task.due { facts.append("Due: \(due.formatted(date: .abbreviated, time: .omitted))") }
            let total = task.total(now: now)
            if total >= 60 { facts.append("Time tracked: \(Fmt.short(total))" + (task.isRunning ? " (timer running)" : "")) }
            for session in store.sessions(of: task) {
                if let status = store.status(of: session) {
                    facts.append("Agent session: \(sessionState(status.kind))")
                }
            }
            out += facts.map { "- \($0)" }.joined(separator: "\n") + "\n"
            // Only what was already read from the tracker; nothing is fetched for this.
            if let detail = TicketCache.load(task.id)?.detail {
                if !detail.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out += "Description:\n\(clip(detail.description, 1500))\n"
                }
                for comment in detail.comments.suffix(3) {
                    out += "Comment by \(comment.author), \(comment.date):\n\(clip(comment.body, 600))\n"
                }
            }
        }
        return out
    }

    /// An agent session's state in words, for the model.
    static func sessionState(_ kind: Orca.Status.Kind) -> String {
        switch kind {
        case .working: return "working"
        case .yourTurn: return "waiting for the developer"
        case .prOpen: return "pull request open"
        case .prMerged: return "pull request merged"
        case .prClosed: return "pull request closed"
        case .idle: return "idle"
        case .gone: return "ended"
        }
    }

    // MARK: Daily standup

    static let standupSystem = """
    You write a developer's daily standup update for one team: what they did since the last \
    standup, what they will do today, and what blocks them. The developer pastes it into a chat \
    (Slack, Teams or similar) or reads it out in the meeting, so it must read as their own words.

    You get the facts the developer's task app knows for this team only: tickets with time \
    tracked, column moves and agent sessions in the period, the board as it is now, tickets that \
    wait, tickets newly assigned, and sometimes the developer's previous update.

    - Write in the first person, as the developer ("Fixed…", "Reviewing…"). Plain English: short \
    sentences, common words, active voice.
    - Use only the facts given. Do not invent work, progress, reasons or people. A ticket with time \
    tracked was worked on; say it was finished only when it is in a finished column, or closed or \
    merged in its tracker.
    - Name each ticket by its reference and a few words of its title, so the team knows which one.
    - Group small items; leave out a ticket with only a few minutes and nothing else to say.
    - Today: the work in progress and the timer that is running, then what is due soon. If the \
    previous update planned something that is still open, it belongs in Today. Do not repeat \
    finished work there.
    - Blockers: only real waits: on a person, a decision, a review or another ticket. Write "None" \
    when there are none. An agent session that waits for the developer is not a blocker.
    - Comments are dated; use only those from the period, and only for what they say about progress \
    or blockers.
    - No time figures unless the instructions below ask for them.
    - Keep it short: at most five bullets per part.

    Format, so it pastes cleanly into any chat: three parts with the labels "Yesterday:", "Today:" \
    and "Blockers:" on their own lines, each followed by bullets that start with "- ". No headings, \
    bold, tables or links. Start directly with "Yesterday:" and add nothing after the last bullet.
    """

    /// The base instructions, the user's standing instructions, and then one space's own
    /// instructions, which win over both.
    static func system(_ base: String, custom: String, space: String) -> String {
        let general = system(base, custom: custom)
        let own = space.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { return general }
        return general + """


        The user set the instructions below for this team's update only. Where they conflict with \
        anything above, including the format and the user's standing instructions, follow these.

        <space_instructions>
        \(own)
        </space_instructions>
        """
    }

    static let logCommentSystem = """
        You write the comment of a time entry (work log) that a developer adds to a ticket in an issue tracker.
        You get the ticket (title, status, description, comments), sometimes the developer's user name and \
        their earlier log comments on this ticket, and the hours to log.

        Write one short line that says what the work on this ticket was, as the developer would write it.
        - Very short: 3 to 6 words, maximum 50 characters. A label, not a sentence: no subject, no articles if the language allows.
        - No quotes, no ticket number, no trailing period, no preamble. Do not restate the ticket title.
        - Use the same language and style as the earlier log comments. If there are none, use the language of the ticket.
        - If you get the developer's own comments of the logged day, base the line on them only: they say what was done.
        - Otherwise base it on the current state of the ticket: the latest comments and the status.
        - Do not repeat an earlier log comment word for word.
        - Do not invent details that the ticket does not support. If you know little, stay general \
        (for example: Checkout error investigation).
        Reply with the comment text only.
        """

    static let estimateSystem = """
        You estimate software tickets for the developer who will do the work. You get one ticket: \
        its description and its comments.
        - "Dev estimate" is the hours of development work only.
        - "Estimate" is the hours for the whole ticket: development plus review, testing, deployment \
        and communication. It is never lower than the dev estimate.
        - If the description or a comment already states an estimate, a number of hours or days, or a \
        budget, use that figure and say who gave it. A day is 8 hours.
        - Otherwise judge from the scope described, and from work the comments show is already done \
        or still open. Estimate the whole ticket, not only what is left.
        - Use quarter hours. If the ticket says too little to estimate, answer 0 for both and say what is missing.
        Reply with exactly three lines and nothing else:
        ESTIMATE: <hours as a number>
        DEV: <hours as a number>
        WHY: <one or two plain sentences>
        """

    struct EstimateSuggestion {
        var estimate: Double?
        var dev: Double?
        var why: String
    }

    /// Asks for an estimate from the ticket's description and comments. Private notes are not part
    /// of `ticketText`, so they are not sent.
    static func suggestEstimate(task: TaskItem, project: Project?, detail: TicketDetail,
                                model: String, instructions: String) async throws -> EstimateSuggestion {
        guard let key = apiKey() else {
            throw RedmineError(message: "Set a Claude API key in Settings to get a suggestion.")
        }
        var answer = ""
        for try await piece in stream(apiKey: key, model: model, system: system(estimateSystem, custom: instructions),
                                      user: ticketText(task: task, project: project, detail: detail)) {
            answer += piece
        }
        func value(_ label: String) -> String? {
            answer.split(whereSeparator: \.isNewline)
                .first { $0.uppercased().hasPrefix(label) }
                .map { String($0.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
        }
        func hours(_ label: String) -> Double? {
            guard let text = value(label)?.replacingOccurrences(of: ",", with: "."),
                  let number = Double(text.prefix { $0.isNumber || $0 == "." }), number > 0 else { return nil }
            return number
        }
        let why = value("WHY:") ?? ""
        if hours("ESTIMATE:") == nil && hours("DEV:") == nil && why.isEmpty {
            throw RedmineError(message: "Claude's answer could not be read as an estimate.")
        }
        return EstimateSuggestion(estimate: hours("ESTIMATE:"), dev: hours("DEV:"), why: why)
    }

    // MARK: Draft a new ticket

    static let draftSystem = """
        You turn a developer's rough note into a ticket for an issue tracker. You get the note, which \
        may include pasted context such as messages, logs or code, and sometimes a title and a \
        description the developer already wrote.

        Write a short, specific title and a clear description.
        - Write in the language of the developer's note, not of the pasted context. If the note \
        itself has no clear language, use the language of the context.
        - Title: at most 80 characters, no ticket number, no trailing period. Name the change or the \
        problem, not the activity ("Checkout fails for saved cards", not "Investigate checkout").
        - Description in Markdown, as short as the note allows. Use these sections when the note \
        gives something for them, and leave out the rest: context or problem, what to do (a list), \
        done when (a list). For a bug, add steps to reproduce and expected versus actual behaviour \
        when the note gives them.
        - Keep technical names, error messages, links and numbers exactly as written. Put code \
        identifiers in backticks and longer logs or code in fenced blocks, shortened to the lines \
        that matter.
        - Use only what the note and context say. Do not invent requirements, causes, estimates or \
        people. If something important is missing, end with a short "Open questions" list.
        - If the developer already wrote a title or a description, keep what is right in it and \
        improve the rest.
        Reply in exactly this form and nothing else:
        TITLE: <the title>
        ---
        <the description>
        """

    struct TicketDraft {
        var title: String
        var description: String
    }

    /// Writes a ticket's title and description from the user's note. Only the note, the title and
    /// the description typed in the form are sent: a task's private notes are not.
    static func draftTicket(note: String, title: String, description: String, tracker: TrackerKind?,
                            model: String, instructions: String) async throws -> TicketDraft {
        guard let key = apiKey() else {
            throw RedmineError(message: "Set a Claude API key in Settings to draft with Claude.")
        }
        var user: [String] = []
        if let tracker, tracker != .other { user.append("Tracker: \(tracker.label)") }
        user.append("<note>\n\(note)\n</note>")
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user.append("<current_title>\n\(title)\n</current_title>")
        }
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user.append("<current_description>\n\(description)\n</current_description>")
        }
        var answer = ""
        for try await piece in stream(apiKey: key, model: model, system: system(draftSystem, custom: instructions),
                                      user: user.joined(separator: "\n\n")) {
            answer += piece
        }
        let lines = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.first, first.uppercased().hasPrefix("TITLE:") else {
            throw RedmineError(message: "Claude's answer could not be read as a ticket.")
        }
        var rest = Array(lines.dropFirst())
        if rest.first?.trimmingCharacters(in: .whitespaces) == "---" { rest.removeFirst() }
        return TicketDraft(title: first.dropFirst("TITLE:".count).trimmingCharacters(in: .whitespaces),
                           description: rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

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
