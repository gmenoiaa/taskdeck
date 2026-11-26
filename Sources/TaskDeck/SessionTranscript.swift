import Foundation

/// What a Claude Code session last said and what it is waiting for, read from the transcript
/// Claude Code keeps on this Mac. Orca reports an agent's last answer only for agents its own
/// launcher started; a session with a Claude home or GitHub account is a typed command, and for
/// those the transcript is the only place the answer is written down.
enum SessionTranscript {
    struct Last: Hashable, Sendable {
        /// The agent's last piece of text in the turn it stopped in.
        var message: String?
        /// The question or permission it is stopped on, when the transcript ends on one.
        var ask: String?
        /// What it left running in the background and has not heard back from. An agent that
        /// stopped with something here is waiting on its own work, not on the user.
        var running: [Running] = []
    }

    /// A command or subagent the agent started in the background. Claude Code wakes the agent
    /// when it ends, so until then the agent carries on by itself.
    struct Running: Hashable, Sendable {
        /// The agent's own description of it, or the command when it gave none.
        var what: String
        var since: Date?
    }

    /// The default home plus the ones given, as typed ("~/.claude-work"), each once.
    static func homes(_ typed: [String]) -> [String] {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        var seen: Set<String> = []
        return ([standard] + typed.compactMap(Orca.resolvedHome)).filter { seen.insert($0).inserted }
    }

    /// The session that last wrote in a worktree, looked for in every home: a worktree created in
    /// Orca does not say which login its agent runs on. Nil when no transcript is found or it ends
    /// on something that is not an agent's turn.
    static func last(worktree path: String, homes: [String]) async -> Last? {
        await Task.detached(priority: .utility) { read(worktree: path, homes: homes) }.value
    }

    // MARK: Reading

    /// Transcripts grow to megabytes and are asked about every few seconds; the answer is kept
    /// for as long as the file is untouched.
    private struct Cached { var modified: Date; var size: Int; var last: Last? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]

    /// The end of a transcript is enough: the last turn sits there. A turn that ends in one
    /// enormous line (a pasted file) is simply not found.
    private static let tailBytes = 1_000_000

    private static func read(worktree path: String, homes: [String]) -> Last? {
        let files = FileManager.default
        // Claude Code names a project's folder after its path, with everything but letters and
        // digits turned into dashes.
        let folder = String(path.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        var candidates: [(url: URL, modified: Date, size: Int)] = []
        for home in homes {
            let directory = URL(fileURLWithPath: home).appendingPathComponent("projects/\(folder)")
            let found = (try? files.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for url in found where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                candidates.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
            }
        }
        // Newest first. A run without a terminal (a script calling `claude -p` in the same folder)
        // is passed over: nobody is waiting in it.
        for file in candidates.sorted(by: { $0.modified > $1.modified }).prefix(4) {
            lock.lock()
            let known = cache[file.url.path]
            lock.unlock()
            let parsed: Parsed
            if let known, known.modified == file.modified, known.size == file.size {
                parsed = known.last.map(Parsed.session) ?? .notInteractive
            } else {
                parsed = parse(file.url)
                lock.lock()
                if case .session(let last) = parsed {
                    cache[file.url.path] = Cached(modified: file.modified, size: file.size, last: last)
                } else {
                    cache[file.url.path] = Cached(modified: file.modified, size: file.size, last: nil)
                }
                lock.unlock()
            }
            if case .session(let last) = parsed { return last }
        }
        return nil
    }

    private enum Parsed { case session(Last), notInteractive }

    private static func parse(_ url: URL) -> Parsed {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .notInteractive }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return .notInteractive }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // Cut somewhere inside a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        let entries = lines.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        var last = Last()
        last.running = running(entries)
        var newest = true
        for entry in entries.reversed() {
            guard let type = entry["type"] as? String, type == "assistant" || type == "user",
                  entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true,
                  // The summary Claude Code writes when it compacts a long session looks like
                  // the user typing, and would hide the answer given just before it.
                  entry["isCompactSummary"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            if let entrypoint = entry["entrypoint"] as? String, entrypoint != "cli" { return .notInteractive }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if type == "user" {
                // A tool's result belongs to the agent's turn; anything else is the user typing,
                // and what the agent said before that has been answered already.
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    newest = false
                    continue
                }
                break
            }
            for block in blocks.reversed() {
                switch block["type"] as? String {
                case "tool_use":
                    // Only as the very last thing written: a tool call with nothing after it is
                    // one the agent is still waiting on.
                    if newest, last.ask == nil { last.ask = ask(block) }
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        last.message = text
                        return .session(last)
                    }
                default:
                    // Thinking is written as a line of its own before the answer; it says nothing
                    // about whether the turn went on.
                    continue
                }
                newest = false
            }
        }
        return .session(last)
    }

    /// What the agent started in the background and has not been told is finished. Claude Code
    /// tells it with a note naming the tool call; a task the agent stopped itself gets no note,
    /// only the stop, which names the task's own id. Only what started within the tail read is
    /// seen, and a session whose Claude Code was quit keeps what it had running listed here.
    private static func running(_ entries: [[String: Any]]) -> [Running] {
        var started: [String: Running] = [:]
        var order: [String] = []
        var calls: [String: String] = [:]
        for entry in entries where entry["isSidechain"] as? Bool != true {
            let type = entry["type"] as? String
            // A finished task's note is queued first and handed to the agent later; either says it ended.
            let content = (entry["message"] as? [String: Any])?["content"] ?? entry["content"]
            let blocks = content as? [[String: Any]] ?? []
            for block in blocks {
                switch (type, block["type"] as? String) {
                case ("assistant", "tool_use"):
                    guard let id = block["id"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let name = block["name"] as? String ?? ""
                    if input["run_in_background"] as? Bool == true {
                        let what = ["description", "command", "prompt"].compactMap { input[$0] as? String }
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? name
                        started[id] = Running(what: what.count > 200 ? String(what.prefix(199)) + "…" : what,
                                              since: (entry["timestamp"] as? String).flatMap(timestamp))
                        order.append(id)
                    } else if name == "TaskStop" || name == "KillShell",
                              let task = (input["task_id"] ?? input["shell_id"]) as? String, let call = calls[task] {
                        started[call] = nil
                    }
                case ("user", "tool_result"):
                    guard let call = block["tool_use_id"] as? String, started[call] != nil else { continue }
                    if block["is_error"] as? Bool == true { started[call] = nil; continue }
                    let text = block["content"] as? String
                        ?? (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if let task = matches(#"with ID: ([A-Za-z0-9_-]+)"#, in: text).first { calls[task] = call }
                default:
                    break
                }
            }
            for text in [content as? String].compactMap({ $0 }) + blocks.compactMap({ $0["text"] as? String })
            where text.contains("<task-notification>") {
                for call in matches(#"<tool-use-id>([^<]+)</tool-use-id>"#, in: text) { started[call] = nil }
                for task in matches(#"<task-id>([^<]+)</task-id>"#, in: text) {
                    if let call = calls[task] { started[call] = nil }
                }
            }
        }
        return order.compactMap { started[$0] }
    }

    /// The first group of each match.
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func timestamp(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A tool call the agent is stopped on, in words.
    private static func ask(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "a tool"
        let input = block["input"] as? [String: Any] ?? [:]
        switch name {
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { $0["question"] as? String }
            guard let first = questions.first else { return "Asks a question." }
            let options = ((input["questions"] as? [[String: Any]])?.first?["options"] as? [[String: Any]] ?? [])
                .compactMap { $0["label"] as? String }
            var text = "Asks: \(first)"
            if !options.isEmpty { text += " (\(options.joined(separator: " / ")))" }
            if questions.count > 1 { text += " and \(questions.count - 1) more" }
            return text
        case "ExitPlanMode":
            return "Has a plan waiting for your approval."
        default:
            // What a permission prompt would show: the command's own description, or the command.
            let what = ["description", "command", "file_path", "url", "query", "prompt"]
                .compactMap { input[$0] as? String }.first { !$0.isEmpty }
            let tool = name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
            return what.map { "Waiting on \(tool): \($0)" } ?? "Waiting on \(tool)."
        }
    }
}
