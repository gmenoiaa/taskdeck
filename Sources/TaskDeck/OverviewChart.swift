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

    /// A task's stretches on the day, as fractions of it.
    private struct Row: Identifiable {
        let id: UUID
        let label: String
        let color: Color
        var spans: [(from: Double, to: Double)]
        var seconds: TimeInterval
    }

    private func rows(_ interval: DateInterval) -> [Row] {
        var rows: [Row] = []
        // Earliest first, so the rows read down the day.
        for stretch in store.stretches(in: interval, project: spaceId, now: now) {
            let span = (from: stretch.start.timeIntervalSince(interval.start) / interval.duration,
                        to: stretch.end.timeIntervalSince(interval.start) / interval.duration)
            let seconds = stretch.end.timeIntervalSince(stretch.start)
            if let index = rows.firstIndex(where: { $0.id == stretch.task.id }) {
                rows[index].spans.append(span)
                rows[index].seconds += seconds
            } else {
                rows.append(Row(id: stretch.task.id,
                                label: "\(stretch.task.displayRef) \(stretch.task.title)".trimmingCharacters(in: .whitespaces),
                                color: store.project(stretch.task.projectId)?.color ?? .gray,
                                spans: [span], seconds: seconds))
            }
        }
        return rows
    }

    /// The whole day, midnight to midnight, a row per task. Drawn by hand: a chart's own axis put
    /// the task names over the bars, and a name needs a column of its own to be read.
    @ViewBuilder
    private var timeline: some View {
        let rows = rows(period.interval)
        let hours = [0, 3, 6, 9, 12, 15, 18, 21, 24]
        let rowHeight: CGFloat = 24
        if rows.isEmpty {
            Text("No time tracked on this day.").foregroundStyle(.secondary)
        } else {
            GeometryReader { geometry in
                // The names get a good third of the width, and no more than they can use.
                let names = min(300, geometry.size.width * 0.36)
                let figures: CGFloat = 58
                let track = max(40, geometry.size.width - names - figures - 20)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Text(row.label).lineLimit(1).truncationMode(.tail)
                                .frame(width: names, alignment: .leading)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.05)).frame(width: track, height: 12)
                                ForEach(hours.dropFirst().dropLast(), id: \.self) { hour in
                                    Rectangle().fill(Color.primary.opacity(0.08))
                                        .frame(width: 1, height: rowHeight)
                                        .offset(x: track * Double(hour) / 24)
                                }
                                ForEach(Array(row.spans.enumerated()), id: \.offset) { _, span in
                                    RoundedRectangle(cornerRadius: 3).fill(row.color)
                                        // A stretch of a minute would be invisible at this scale.
                                        .frame(width: max(3, track * (span.to - span.from)), height: 12)
                                        .offset(x: track * span.from)
                                }
                            }
                            .frame(width: track, height: rowHeight, alignment: .leading)
                            Text(Fmt.short(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: figures, alignment: .trailing)
                        }
                        .help("\(row.label) · \(Fmt.short(row.seconds))")
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(hours, id: \.self) { hour in
                            Text(String(format: "%02d", hour)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: 30)
                                .offset(x: track * Double(hour) / 24 - 15)
                        }
                    }
                    .frame(width: track, height: 18, alignment: .topLeading)
                    .padding(.leading, names + 10).padding(.top, 2)
                }
            }
            .frame(height: CGFloat(rows.count) * rowHeight + 20)
        }
    }
}
