import SwiftUI

/// Where a widget sits across the overview: the whole width, or one of two columns.
enum OverviewWidth: String, CaseIterable, Identifiable {
    case full, left, right

    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: "Full Width"
        case .left: "Left Column"
        case .right: "Right Column"
        }
    }
    var symbol: String {
        switch self {
        case .full: "rectangle"
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        }
    }
}

/// Lays the overview's widgets out top to bottom. Widgets given a column that follow each other
/// form a block of two columns, each piled in its own column in their order, so a short widget
/// can sit under another beside a tall one. A widget with nothing to show takes no room.
struct OverviewGrid: Layout {
    var spacing: CGFloat = 22
    var gutter: CGFloat = 20
    /// Whether a block with widgets on one side only spreads over the whole width. Off while
    /// customising, where a card has to show the column it was given.
    var expandsLone = true

    struct Column: LayoutValueKey {
        static let defaultValue = OverviewWidth.full
    }

    private struct Placed {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (placed: [Placed], height: CGFloat) {
        let half = max(0, (width - gutter) / 2)
        var placed: [Placed] = []
        var y: CGFloat = 0
        // The block being gathered: the widgets of each column, in order.
        var left: [Int] = [], right: [Int] = []

        func height(_ index: Int, _ width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        /// Piles the widgets from `y` down and returns how tall the pile is.
        func pile(_ indices: [Int], x: CGFloat, width: CGFloat) -> CGFloat {
            var offset: CGFloat = 0
            for index in indices {
                placed.append(Placed(index: index, x: x, y: y + offset, width: width))
                offset += height(index, width) + spacing
            }
            return max(0, offset - spacing)
        }
        func flush() {
            guard !left.isEmpty || !right.isEmpty else { return }
            let tall: CGFloat
            if expandsLone, left.isEmpty || right.isEmpty {
                // Nobody on the other side: half a row of nothing helps no one.
                tall = pile(left + right, x: 0, width: width)
            } else {
                tall = max(pile(left, x: 0, width: half), pile(right, x: half + gutter, width: half))
            }
            y += tall + spacing
            left = []
            right = []
        }

        for index in subviews.indices {
            switch subviews[index][Column.self] {
            case .left: if height(index, half) > 0.5 { left.append(index) }
            case .right: if height(index, half) > 0.5 { right.append(index) }
            case .full:
                let tall = height(index, width)
                guard tall > 0.5 else { continue }
                flush()
                placed.append(Placed(index: index, x: 0, y: y, width: width))
                y += tall + spacing
            }
        }
        flush()
        return (placed, max(0, y - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(subviews, width: bounds.width).placed
        for item in placed {
            subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + item.y), anchor: .topLeading,
                                       proposal: ProposedViewSize(width: item.width, height: nil))
        }
        // An empty widget still has to be placed somewhere; it has no size to show.
        let done = Set(placed.map(\.index))
        for index in subviews.indices where !done.contains(index) {
            subviews[index].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
    }
}
