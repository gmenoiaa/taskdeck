import Foundation

/// Claude's proposal for the comment of a Redmine time entry.
enum LogComment {
    struct Proposal {
        var text: String
        /// Where it came from, to finish the sentence "Proposed by Claude from …".
        var source: String
    }

    struct MissingKey: LocalizedError {
        var errorDescription: String? { "Set your Claude API key in Settings → AI (⌘,)." }
    }

    static func clean(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
    }

    /// Proposes a short comment from what I wrote on the ticket on the logged day(s); without such a
    /// comment, from the whole ticket. `onPartial` gets the text as it is written.
    @MainActor
    static func propose(task: TaskItem, project: Project, days: Set<Date>, hours: Double,
                        model: String, instructions: String,
                        onPartial: (String) -> Void = { _ in }) async throws -> Proposal {
        guard let key = Claude.apiKey() else { throw MissingKey() }
        guard let id = Int(task.ref), let client = RedmineClient(project: project) else {
            throw RedmineError(message: "Set the project's base URL and API key in Settings → Projects.")
        }
        let issue = try await client.issue(id: id)
        let cal = Calendar.current
        let wanted = Set(days.map { cal.startOfDay(for: $0) })
        let me = try? await client.currentUserId()
        let mine = (issue.journals ?? []).filter { journal in
            guard let me, journal.user?.id == me,
                  !(journal.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let date = RedmineDate.date(journal.created_on) else { return false }
            return wanted.contains(cal.startOfDay(for: date))
        }
        var user: String
        let source: String
        if mine.isEmpty {
            let detail = try await TicketFetcher.fetch(project: project, ref: task.ref, url: task.url)
            user = Claude.ticketText(task: task, project: project, detail: detail)
            source = "the ticket (no comment of yours on that day)"
        } else {
            user = "Ticket title (context only): \(issue.subject)\n\n"
                + "<my_comments_on_the_logged_day order=\"oldest first\">\n"
                + mine.map { "<comment>\n\($0.notes ?? "")\n</comment>" }.joined(separator: "\n")
                + "\n</my_comments_on_the_logged_day>\n\n"
                + "Summarise the work these comments report. The latest comment matters most."
            source = mine.count == 1 ? "your comment of that day" : "your \(mine.count) comments of that day"
        }
        if let old = try? await client.myTimeEntries(issueId: id) {
            let lines = old.compactMap(\.comments).filter { !$0.isEmpty }.suffix(8)
            if !lines.isEmpty {
                user += "\n\n<my_earlier_log_comments>\n" + lines.joined(separator: "\n") + "\n</my_earlier_log_comments>"
            }
        }
        user += String(format: "\n\nTime to log now: %.2f h", hours)
        var text = ""
        let system = Claude.system(Claude.logCommentSystem, custom: instructions)
        for try await chunk in Claude.stream(apiKey: key, model: model, system: system, user: user) {
            text += chunk
            onPartial(clean(text))
        }
        return Proposal(text: clean(text), source: source)
    }
}
