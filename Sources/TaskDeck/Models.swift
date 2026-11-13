import Foundation
import SwiftUI

enum TrackerKind: String, Codable, CaseIterable, Identifiable {
    case redmine, jira, github, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .redmine: return "Redmine"
        case .jira: return "Jira"
        case .github: return "GitHub"
        case .other: return "Other"
        }
    }

    var urlHint: String {
        switch self {
        case .redmine: return "https://redmine.company.com"
        case .jira: return "https://company.atlassian.net"
        case .github: return "https://github.com/org  or  https://github.com/org/repo"
        case .other: return "https://…"
        }
    }

    var ticketHint: String {
        switch self {
        case .redmine: return "12345 or link"
        case .jira: return "PROJ-123 or link"
        case .github: return "123, repo#123 or link"
        case .other: return "reference or link"
        }
    }
}

/// What a board column means for timers, archiving and the menu bar suggestions.
enum ColumnRole: String, Codable, CaseIterable, Identifiable {
    case backlog, inProgress, normal, watching, done
    var id: String { rawValue }

    var label: String {
        switch self {
        case .backlog: return "Not started"
        case .inProgress: return "In progress"
        case .normal: return "Other work"
        case .watching: return "Watching"
        case .done: return "Done"
        }
    }

    var hint: String {
        switch self {
        case .backlog: return "Starting a timer moves the task to the In progress column."
        case .inProgress: return "Where tasks go when you start a timer on a not-started or done task."
        case .normal: return "A normal work step, such as review or testing."
        case .watching: return "Tasks you only follow. Not suggested in the menu bar; timers leave them here."
        case .done: return "Moving a task here stops its timer. Tasks here can be archived."
        }
    }
}

/// One column of the board. Tasks point at a column by its id.
struct BoardColumn: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var role: ColumnRole = .normal

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// The original fixed columns. Their ids match the status values saved by earlier versions.
    static let defaults = [
        BoardColumn(id: "todo", name: "To Do", role: .backlog),
        BoardColumn(id: "inProgress", name: "In Progress", role: .inProgress),
        BoardColumn(id: "review", name: "Review", role: .normal),
        BoardColumn(id: "done", name: "Done", role: .done),
    ]
}

/// Called a "space" everywhere the user can see. The type and the saved keys keep the older name so
/// existing data files load unchanged.
struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var kind: TrackerKind = .redmine
    var baseURL = ""
    var colorIndex = 0
    var defaultActivityId: Int?
    /// Jira Cloud: account e-mail (empty = Bearer token, for Server/Data Center).
    var username: String?
    /// Redmine: "textile" (default) or "markdown", matching the instance's setting.
    var textFormat: String?
    /// Orca repository last used to start a session for this space; preselected next time.
    var orcaRepoId: String?
    /// The Orca repositories that belong to this space. Nil in files saved before a space could have
    /// more than one; `repoIds` covers both.
    var orcaRepoIds: [String]?
    /// Claude Code's home directory for this project's agent sessions (e.g. "~/.claude-work"), as typed.
    /// Empty or nil means Claude's own default.
    var claudeHome: String?
    /// The `gh` account this project's agent sessions use. Empty or nil means gh's active account.
    var githubAccount: String?

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]
    var color: Color { Project.palette[abs(colorIndex) % Project.palette.count] }
    var keychainAccount: String { "apikey-\(id.uuidString)" }
    var repoIds: [String] { orcaRepoIds ?? [orcaRepoId].compactMap { $0 } }
}

struct TimeEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var start: Date
    var end: Date?
    var loggedAt: Date?

    func duration(now: Date) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

struct TaskItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectId: UUID?
    var ref = ""
    var title = ""
    var url = ""
    /// Id of the board column the task is in.
    var status: String = "todo"
    var entries: [TimeEntry] = []
    var notes = ""
    var createdAt = Date()
    var archived = false
    /// The ticket's own status in its tracker (e.g. "Assigned", "In Review", "merged"), when known.
    var remoteStatus: String?
    /// Who the ticket is assigned to in its tracker, when known.
    var remoteAssignee: String?
    /// Last plain-language explanation of the ticket written by Claude (Markdown).
    var explanation: String?
    /// Agent sessions started in Orca for this task, oldest first. Optional so older files still load.
    var sessions: [AgentSession]?
    var order: Double = 0

    var isRunning: Bool { entries.contains { $0.end == nil } }

    func total(now: Date) -> TimeInterval {
        entries.reduce(0) { $0 + $1.duration(now: now) }
    }

    /// Time already stopped and not yet logged to the tracker.
    var unloggedSeconds: TimeInterval {
        entries.filter { $0.end != nil && $0.loggedAt == nil }
            .reduce(0) { $0 + $1.duration(now: Date()) }
    }

    var displayRef: String {
        guard !ref.isEmpty else { return "" }
        return ref.allSatisfy(\.isNumber) ? "#\(ref)" : ref
    }
}

enum LinkResolver {
    /// Accepts a ticket number/key or a full link and returns (ref, url).
    static func resolve(_ raw: String, kind: TrackerKind, base rawBase: String) -> (ref: String, url: String) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !input.isEmpty else { return ("", "") }

        if input.lowercased().hasPrefix("http") {
            let parts = (URLComponents(string: input)?.path ?? "")
                .split(separator: "/").map(String.init)
            func after(_ names: [String]) -> String? {
                guard let i = parts.firstIndex(where: { names.contains($0) }), i + 1 < parts.count else { return nil }
                return parts[i + 1]
            }
            let ref: String
            switch kind {
            case .redmine:
                ref = after(["issues"]) ?? parts.last ?? input
            case .jira:
                ref = after(["browse", "issues"]) ?? parts.last ?? input
            case .github:
                if let n = after(["issues", "pull"]), parts.count >= 2 {
                    ref = "\(parts[1])#\(n)"
                } else {
                    ref = parts.last ?? input
                }
            case .other:
                ref = parts.last ?? input
            }
            return (ref, input)
        }

        let ref = input.hasPrefix("#") ? String(input.dropFirst()) : input
        guard !base.isEmpty else { return (ref, "") }
        switch kind {
        case .redmine:
            return (ref, "\(base)/issues/\(ref)")
        case .jira:
            return (ref.uppercased(), "\(base)/browse/\(ref.uppercased())")
        case .github:
            if let hash = ref.firstIndex(of: "#") {
                let repo = ref[..<hash]
                let number = ref[ref.index(after: hash)...]
                return (ref, "\(base)/\(repo)/issues/\(number)")
            }
            return (ref, "\(base)/issues/\(ref)")
        case .other:
            return (ref, "")
        }
    }
}

enum Fmt {
    /// "1:23:45" — for running timers.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "1h 23m" — for totals.
    static func short(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m == 0 { return seconds > 0 ? "<1m" : "0m" }
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    /// "1:23" (h:mm) — for the menu bar.
    static func hm(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func hours(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds / 3600)
    }
}
