import Foundation

/// A section of the overview. The user orders and hides them; see `AppStore.overviewPlacements`.
enum OverviewWidget: String, CaseIterable, Identifiable {
    case standup, time, review, chart, calendar, breakdown, sessions, goals, due, unlogged, bySpace, topTasks, board

    var id: String { rawValue }

    /// The widget's name. On the overview the time widgets are titled by the period shown instead.
    var title: String {
        switch self {
        case .standup: "Daily standup"
        case .time: "Time"
        case .review: "Review"
        case .chart: "Chart"
        case .calendar: "Calendar"
        case .breakdown: "Where the time went"
        case .sessions: "Agent sessions"
        case .goals: "Goals"
        case .due: "Due soon"
        case .unlogged: "Time to log"
        case .bySpace: "By space"
        case .topTasks: "Most time"
        case .board: "On the board"
        }
    }

    /// Hidden until the user asks for it. The two lists say what the chart and "Where the time
    /// went" already say; they stay for whoever prefers them. A layout the user arranged keeps
    /// what it had.
    /// "Time to log" repeats the toolbar's time-to-push button, for whoever wants the list in view.
    var hiddenByDefault: Bool { self == .bySpace || self == .topTasks || self == .unlogged }

    /// What a widget being dragged carries. Prefixed so a task card dropped on the overview, which
    /// carries a bare UUID string, is never taken for a widget.
    var dragToken: String { "overview-widget:" + rawValue }

    init?(dragToken: String) {
        guard dragToken.hasPrefix("overview-widget:") else { return nil }
        self.init(rawValue: String(dragToken.dropFirst("overview-widget:".count)))
    }
}

/// One widget's place in the saved layout. The id is a string rather than the enum so a file
/// written by a newer build, with a widget this build does not know, still loads.
struct OverviewSlot: Codable, Hashable {
    var id: String
    var hidden = false
    /// "left" or "right" for a widget in one of the two columns; nil for the whole width, which
    /// is also what files saved before widgets had a width say.
    var column: String?
}

struct OverviewPlacement: Identifiable, Hashable {
    let widget: OverviewWidget
    var hidden: Bool
    var width = OverviewWidth.full
    var id: String { widget.rawValue }
}

extension AppStore {
    /// Every widget in the user's order. A widget the saved layout does not mention (added in a
    /// later version) goes after the one it follows by default, rather than being lost or sent
    /// to the bottom.
    var overviewPlacements: [OverviewPlacement] {
        var out: [OverviewPlacement] = []
        for slot in overviewLayout {
            guard let widget = OverviewWidget(rawValue: slot.id), !out.contains(where: { $0.widget == widget }) else { continue }
            out.append(OverviewPlacement(widget: widget, hidden: slot.hidden,
                                         width: slot.column.flatMap(OverviewWidth.init(rawValue:)) ?? .full))
        }
        let all = OverviewWidget.allCases
        for (index, widget) in all.enumerated() where !out.contains(where: { $0.widget == widget }) {
            let before = index > 0 ? out.firstIndex { $0.widget == all[index - 1] } : nil
            out.insert(OverviewPlacement(widget: widget, hidden: widget.hiddenByDefault), at: before.map { $0 + 1 } ?? 0)
        }
        return out
    }

    private func setOverview(_ placements: [OverviewPlacement]) {
        overviewLayout = placements.map { OverviewSlot(id: $0.widget.rawValue, hidden: $0.hidden,
                         column: $0.width == .full ? nil : $0.width.rawValue)
        }
        save()
    }

    func setOverviewWidget(_ widget: OverviewWidget, hidden: Bool) {
        var placements = overviewPlacements
        guard let index = placements.firstIndex(where: { $0.widget == widget }) else { return }
        placements[index].hidden = hidden
        setOverview(placements)
    }

    func setOverviewWidget(_ widget: OverviewWidget, width: OverviewWidth) {
        var placements = overviewPlacements
        guard let index = placements.firstIndex(where: { $0.widget == widget }) else { return }
        placements[index].width = width
        setOverview(placements)
    }

    /// Puts a widget where another one is; that one and those between shift by one. A dragged
    /// widget also takes the column of the one it is dropped on: dropped on a card of the right
    /// column, it is meant to go there.
    func moveOverviewWidget(_ widget: OverviewWidget, to target: OverviewWidget, takingColumn: Bool = false) {
        var placements = overviewPlacements
        guard widget != target,
              let from = placements.firstIndex(where: { $0.widget == widget }),
              let to = placements.firstIndex(where: { $0.widget == target }) else { return }
        var moved = placements.remove(at: from)
        if takingColumn { moved.width = placements.first { $0.widget == target }?.width ?? moved.width }
        placements.insert(moved, at: to)
        setOverview(placements)
    }

    /// The shown widget a step up (-1) or down (+1) from this one, among `candidates`.
    func overviewNeighbour(of widget: OverviewWidget, by step: Int, among candidates: [OverviewWidget]) -> OverviewWidget? {
        guard let index = candidates.firstIndex(of: widget), candidates.indices.contains(index + step) else { return nil }
        return candidates[index + step]
    }

    func resetOverviewLayout() {
        overviewLayout = []
        save()
    }
}
