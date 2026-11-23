import SwiftUI

/// Lays its views out left to right and starts a new line when the next one does not fit, like
/// words in a paragraph. A view wider than the whole line gets the line's width and may cut its
/// text short.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(width limit: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > limit { size = view.sizeThatFits(ProposedViewSize(width: limit, height: nil)) }
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty, needed > limit {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(width: proposal.width ?? .infinity, subviews: subviews)
        guard !lines.isEmpty else { return .zero }
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(lines.count - 1)
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                // Centred in the line, so a shorter pill sits level with a taller one beside it.
                subviews[item.index].place(at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
