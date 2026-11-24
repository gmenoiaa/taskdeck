import SwiftUI
import Charts

/// The overview's chart: a bar per day for a week or a month, stacked by space, or for a single
/// day the stretches worked on each task along the hours.
struct OverviewChart: View {
    @Environment(AppStore.self) private var store
    let period: OverviewPeriod
    let days: [OverviewDay]
    let spaceId: UUID?
    let now: Date
    /// Seconds aimed at per working day; 0 for none.
    let dailyTarget: TimeInterval
    /// A click on a day's bar.
    let onDay: (Date) -> Void

    @State private var hovered: Date?

    var body: some View {
        if period.scale == .day { timeline } else { bars }
    }

    // MARK: Days

    private struct Segment: Identifiable {
        let day: Date
        let space: UUID?
        let seconds: TimeInterval
        let color: Color
        var id: String { "\(day.timeIntervalSince1970)-\(space?.uuidString ?? "none")" }
    }

    private func segments(today: Date) -> [Segment] {
        // In the spaces' own order, so a space sits at the same height in every bar.
        let order: [UUID?] = store.projects.map { Optional($0.id) } + [nil]
        return days.flatMap { day in
            order.compactMap { space -> Segment? in
                guard let seconds = day.bySpace[space], seconds > 0 else { return nil }
                let color: Color
                if spaceId != nil {
                    // One space: its colour says nothing, so today stands out instead.
                    color = day.start == today ? Theme.accent : Color.primary.opacity(0.25)
                } else {
                    color = space.flatMap { store.project($0)?.color } ?? .gray
                }
                return Segment(day: day.start, space: space, seconds: seconds, color: color)
            }
        }
    }

    private var bars: some View {
        let today = Calendar.current.startOfDay(for: now)
        let week = period.scale == .week
        return Chart {
            ForEach(segments(today: today)) { segment in
                BarMark(x: .value("Day", segment.day, unit: .day),
                        y: .value("Hours", segment.seconds / 3600))
                    .foregroundStyle(segment.color)
                    .cornerRadius(3)
            }
            // The day's total over its bar: always in a week, under the pointer in a month,
            // where thirty labels would not fit.
            ForEach(days) { day in
                if day.total >= 60, week || day.start == hovered {
                    PointMark(x: .value("Day", day.start, unit: .day), y: .value("Hours", day.total / 3600))
                        .symbolSize(0)
                        .annotation(position: .top, spacing: 3) {
                            Text(Fmt.short(day.total)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                }
            }
            if dailyTarget > 0 {
                RuleMark(y: .value("Target", dailyTarget / 3600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Target \(Fmt.short(dailyTarget))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: period.interval.start...period.interval.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: week ? 1 : 2)) { value in
                let isToday = value.as(Date.self) == today
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        Text(week ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.day()))
                            .foregroundStyle(isToday ? Color.primary : Color.secondary)
                            .fontWeight(isToday ? .semibold : .regular)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let hours = value.as(Double.self) { Text("\(hours.formatted(.number.precision(.fractionLength(0...1))))h") }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                // One layer for both the pointer and the click, so neither takes the other's events.
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = day(at: point, proxy, geometry)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { point in
                        if let day = day(at: point, proxy, geometry) { onDay(day) }
                    }
            }
        }
        .frame(height: 170)
        .help("Click a day to open it")
    }

    private func day(at point: CGPoint, _ proxy: ChartProxy, _ geometry: GeometryProxy) -> Date? {
        guard let frame = proxy.plotFrame else { return nil }
        let x = point.x - geometry[frame].origin.x
        guard let date = proxy.value(atX: x, as: Date.self), period.contains(date) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    // MARK: One day

    private struct Row: Identifiable {
        let id: UUID
        let label: String
        let start: Date
        let end: Date
        let color: Color
    }

    @ViewBuilder
    private var timeline: some View {
        let interval = period.interval
        let stretches = store.stretches(in: interval, project: spaceId, now: now)
        if stretches.isEmpty {
            Text("No time tracked on this day.").foregroundStyle(.secondary)
        } else {
            let rows = stretches.map { stretch -> Row in
                let name = "\(stretch.task.displayRef) \(stretch.task.title)".trimmingCharacters(in: .whitespaces)
                return Row(id: stretch.id, label: name.count > 34 ? name.prefix(33) + "…" : name,
                           start: stretch.start, end: stretch.end,
                           color: store.project(stretch.task.projectId)?.color ?? .gray)
            }
            let labels = Set(rows.map(\.label)).count
            // From the hour of the first stretch to the hour after the last: a day of two
            // stretches in the afternoon should not be drawn against 24 empty hours.
            let calendar = Calendar.current
            let from = calendar.dateInterval(of: .hour, for: rows[0].start)?.start ?? interval.start
            let last = rows.map(\.end).max() ?? interval.end
            let to = min(interval.end, calendar.dateInterval(of: .hour, for: last.addingTimeInterval(-1))?.end ?? interval.end)
            Chart(rows) { row in
                BarMark(xStart: .value("Start", row.start), xEnd: .value("End", row.end),
                        y: .value("Task", row.label), height: .fixed(12))
                    .foregroundStyle(row.color)
                    .cornerRadius(3)
            }
            .chartXScale(domain: from...max(to, from.addingTimeInterval(3600)))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in AxisValueLabel() }
            }
            .frame(height: CGFloat(labels) * 26 + 30)
        }
    }
}
