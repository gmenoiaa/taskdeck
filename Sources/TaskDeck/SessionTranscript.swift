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

        var last = Last()
        var newest = true
        for line in lines.reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = entry["type"] as? String, type == "assistant" || type == "user",
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
