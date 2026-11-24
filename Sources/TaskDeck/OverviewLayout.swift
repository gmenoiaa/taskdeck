import Foundation

/// A section of the overview. The user orders and hides them; see `AppStore.overviewPlacements`.
enum OverviewWidget: String, CaseIterable, Identifiable {
    case standup, time, chart, sessions, goals, bySpace, topTasks, board

    var id: String { rawValue }

    /// The widget's name. On the overview the time widgets are titled by the period shown instead.
    var title: String {
        switch self {
        case .standup: "Daily standup"
        case .time: "Time"
        case .chart: "Chart"
        case .sessions: "Agent sessions"
        case .goals: "Goals"
        case .bySpace: "By space"
        case .topTasks: "Most time"
        case .board: "On the board"
        }
    }

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
}

struct OverviewPlacement: Identifiable, Hashable {
    let widget: OverviewWidget
    var hidden: Bool
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
            out.append(OverviewPlacement(widget: widget, hidden: slot.hidden))
        }
        let all = OverviewWidget.allCases
        for (index, widget) in all.enumerated() where !out.contains(where: { $0.widget == widget }) {
            let before = index > 0 ? out.firstIndex { $0.widget == all[index - 1] } : nil
            out.insert(OverviewPlacement(widget: widget, hidden: false), at: before.map { $0 + 1 } ?? 0)
        }
        return out
    }

    private func setOverview(_ placements: [OverviewPlacement]) {
        overviewLayout = placements.map { OverviewSlot(id: $0.widget.rawValue, hidden: $0.hidden) }
        save()
    }

    func setOverviewWidget(_ widget: OverviewWidget, hidden: Bool) {
        var placements = overviewPlacements
        guard let index = placements.firstIndex(where: { $0.widget == widget }) else { return }
        placements[index].hidden = hidden
        setOverview(placements)
    }

    /// Puts a widget where another one is; that one and those between shift by one.
    func moveOverviewWidget(_ widget: OverviewWidget, to target: OverviewWidget) {
        var placements = overviewPlacements
        guard widget != target,
              let from = placements.firstIndex(where: { $0.widget == widget }),
              let to = placements.firstIndex(where: { $0.widget == target }) else { return }
        placements.insert(placements.remove(at: from), at: to)
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
