import SwiftUI

/// A month at a glance: each day shaded by the time tracked on it, with a mark where something
/// is due. A click opens the day. Its own arrows look at other months without moving the
/// overview's period, so next month's due dates can be checked while staying on this week.
struct OverviewCalendar: View {
    @Environment(AppStore.self) private var store
    let period: OverviewPeriod
    let spaceId: UUID?
    let now: Date
    let onDay: (Date) -> Void

    /// A date in the month shown; nil follows the overview's period.
    @State private var browsed: Date?

    private var month: OverviewPeriod {
        // A week can start in the month before: the day the period is about decides.
        let own = period.contains(now) ? now : period.interval.start
        return OverviewPeriod(scale: .month, anchor: browsed ?? own)
    }

    /// Days on which an open task or an active goal is due.
    private var dueDays: Set<Date> {
        let calendar = Calendar.current
        let tasks = store.tasks.filter { (spaceId == nil || $0.projectId == spaceId) && !store.isDone($0) }.compactMap(\.due)
        let goals = store.goals(in: spaceId).filter { $0.status == .active }.compactMap(\.due)
        return Set((tasks + goals).map { calendar.startOfDay(for: $0) })
    }

    var body: some View {
        let calendar = Calendar.current
        let month = month
        let days = store.trackedByDay(in: month, project: spaceId, now: now)
        let most = max(days.map(\.total).max() ?? 0, 1)
        let due = dueDays
        let today = calendar.startOfDay(for: now)
        // Empty cells before the 1st, so it falls under its weekday.
        let lead = days.first.map { (calendar.component(.weekday, from: $0.start) - calendar.firstWeekday + 7) % 7 } ?? 0
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(month.dates).fontWeight(.medium)
                Spacer(minLength: 12)
                if browsed != nil {
                    Button("Back") { browsed = nil }.help("Back to the month of the period shown")
                }
                Button { browsed = month.stepped(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous month").accessibilityLabel("Previous month")
                Button { browsed = month.stepped(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next month").accessibilityLabel("Next month")
            }
            .buttonStyle(.borderless).tint(nil).controlSize(.small)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 42) }
                ForEach(days) { day in
                    cell(day, most: most, isToday: day.start == today, due: due.contains(day.start),
                         // A month selects every day: marking them all would say nothing.
                         selected: period.scale != .month && period.contains(day.start))
                }
            }
        }
        // The period moved: the calendar goes back to showing where it is.
        .onChange(of: period.interval.start) { browsed = nil }
    }

    private func cell(_ day: OverviewDay, most: TimeInterval, isToday: Bool, due: Bool, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        return Button { onDay(day.start) } label: {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(day.start.formatted(.dateTime.day()))
                        .font(.callout.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Theme.accent : .primary)
                    if due { Circle().fill(.orange).frame(width: 5, height: 5) }
                }
                Text(day.total >= 60 ? Fmt.short(day.total) : " ")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 42)
            // Darker with more time; a day with none stays almost clear. The days of the period
            // shown are tinted red instead of grey: an outline around each made the row too loud.
            .background(selected
                        ? Theme.accent.opacity(day.total >= 60 ? 0.10 + 0.16 * day.total / most : 0.07)
                        : Color.primary.opacity(day.total >= 60 ? 0.05 + 0.17 * day.total / most : 0.02), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(day.start.formatted(date: .complete, time: .omitted)
              + (day.total >= 60 ? " · \(Fmt.short(day.total))" : "")
              + (due ? " · something is due" : ""))
    }
}
