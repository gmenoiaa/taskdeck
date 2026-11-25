import SwiftUI

/// Where the time of the period went: by task, by space or by goal, most first.
struct OverviewBreakdown: View {
    @Environment(AppStore.self) private var store
    let period: OverviewPeriod
    let days: [OverviewDay]
    let spaceId: UUID?
    let now: Date
    let onDetails: (TaskItem) -> Void
    let onGoal: (UUID) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case task, space, goal
        var id: String { rawValue }
        var label: String { "By \(rawValue)" }
    }

    @State private var mode: Mode = .task
    @State private var showAll = false

    private struct Row: Identifiable {
        let id: UUID
        let label: String
        let color: Color
        let seconds: TimeInterval
        let help: String
        let open: (() -> Void)?
    }

    private var rows: [Row] {
        let span = period.interval
        let mine = store.tasks.filter { spaceId == nil || $0.projectId == spaceId }
        let rows: [Row]
        switch mode {
        case .task:
            rows = mine.map { task in
                Row(id: task.id, label: "\(task.displayRef) \(task.title)".trimmingCharacters(in: .whitespaces),
                    color: store.project(task.projectId)?.color ?? .gray,
                    seconds: task.tracked(in: span, now: now), help: "Open the ticket") { onDetails(task) }
            }
        case .space:
            rows = store.projects.filter { spaceId == nil || $0.id == spaceId }.map { space in
                Row(id: space.id, label: space.name, color: space.color,
                    seconds: days.reduce(0) { $0 + ($1.bySpace[space.id] ?? 0) }, help: "", open: nil)
            }
        case .goal:
            // Only the goal's tasks in the space shown, so the figures add up to the period's total.
            rows = store.goals(in: spaceId).map { goal in
                Row(id: goal.id, label: goal.displayName, color: Theme.accent,
                    seconds: mine.filter { $0.goalId == goal.id }.reduce(0) { $0 + $1.tracked(in: span, now: now) },
                    help: "Open the goal") { onGoal(goal.id) }
            }
        }
        return rows.filter { $0.seconds >= 60 }.sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        let rows = rows
        let most = max(rows.first?.seconds ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Group", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if rows.isEmpty {
                Text(mode == .goal ? "No time on a goal in this period." : "No time tracked in this period.")
                    .foregroundStyle(.secondary)
            }
            ForEach(showAll ? rows : Array(rows.prefix(6))) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    if let open = row.open {
                        Button(action: open) { Text(row.label).lineLimit(1).contentShape(Rectangle()) }
                            .buttonStyle(.plain).help(row.help)
                    } else {
                        Text(row.label).lineLimit(1)
                    }
                    Spacer(minLength: 16)
                    // Against the largest row, so the eye compares lengths before reading figures.
                    ProgressView(value: row.seconds, total: most).tint(row.color).frame(width: 90)
                    Text(Fmt.short(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
            if rows.count > 6 {
                Button(showAll ? "Show fewer" : "Show all \(rows.count)") { showAll.toggle() }
                    .buttonStyle(.link).tint(Theme.accent).font(.callout)
            }
        }
    }
}
