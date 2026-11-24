import Foundation

/// The stretch of time the overview's time widgets cover: a day, a week or a month around a date.
struct OverviewPeriod {
    enum Scale: String, CaseIterable, Identifiable {
        case day, week, month

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    let scale: Scale
    let anchor: Date

    var interval: DateInterval {
        let calendar = Calendar.current
        return calendar.dateInterval(of: scale.component, for: anchor)
            ?? DateInterval(start: calendar.startOfDay(for: anchor), duration: 86_400)
    }

    /// A date in the period this many steps away.
    func stepped(_ steps: Int) -> Date {
        Calendar.current.date(byAdding: scale.component, value: steps, to: anchor) ?? anchor
    }

    /// The start of each day in the period.
    var days: [Date] {
        let calendar = Calendar.current
        let interval = interval
        var out: [Date] = []
        var day = interval.start
        while day < interval.end {
            out.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// Monday to Friday in the period: the days a daily target counts on.
    var workdays: Int { days.filter { !Calendar.current.isDateInWeekend($0) }.count }

    func contains(_ date: Date) -> Bool {
        let interval = interval
        return date >= interval.start && date < interval.end
    }

    /// "this week", "yesterday", "last month": how the period reads from now, when it is near enough.
    func phrase(now: Date) -> String? {
        let start = interval.start
        let around = OverviewPeriod(scale: scale, anchor: now)
        let names: [String]
        switch scale {
        case .day: names = ["yesterday", "today", "tomorrow"]
        case .week: names = ["last week", "this week", "next week"]
        case .month: names = ["last month", "this month", "next month"]
        }
        for (index, steps) in [-1, 0, 1].enumerated()
        where OverviewPeriod(scale: scale, anchor: around.stepped(steps)).interval.start == start {
            return names[index]
        }
        return nil
    }

    /// The period by its dates: "Mon 23 Nov", "22 – 28 Nov", "November 2026".
    var dates: String {
        let interval = interval
        switch scale {
        case .day: return interval.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            let last = interval.end.addingTimeInterval(-1)
            return (interval.start..<last).formatted(.interval.day().month(.abbreviated))
        case .month: return interval.start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// "This week" when it is near, its dates otherwise.
    func title(now: Date) -> String {
        guard let phrase = phrase(now: now) else { return dates }
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }
}

/// The time tracked on one day, split by space (nil for tasks with no space).
struct OverviewDay: Identifiable {
    let start: Date
    var bySpace: [UUID?: TimeInterval] = [:]
    var id: Date { start }
    var total: TimeInterval { bySpace.values.reduce(0, +) }
}

/// One tracked stretch inside a period, cut to it.
struct OverviewStretch: Identifiable {
    let id: UUID
    let task: TaskItem
    let start: Date
    let end: Date
}

extension AppStore {
    /// Time per day and space over a period, in one pass over the entries rather than one
    /// `tracked(in:)` per day and space. Archived tasks count, as everywhere time is added up.
    func trackedByDay(in period: OverviewPeriod, project: UUID?, now: Date) -> [OverviewDay] {
        let calendar = Calendar.current
        let interval = period.interval
        var days = period.days.map { OverviewDay(start: $0) }
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.start, $0) })
        for task in tasks where project == nil || task.projectId == project {
            for entry in task.entries {
                var start = max(entry.start, interval.start)
                let end = min(entry.end ?? now, interval.end)
                // An entry can cross midnight: each day gets its own part.
                while start < end {
                    let day = calendar.startOfDay(for: start)
                    let next = calendar.date(byAdding: .day, value: 1, to: day) ?? end
                    let cut = min(end, next)
                    if let i = index[day] { days[i].bySpace[task.projectId, default: 0] += cut.timeIntervalSince(start) }
                    start = cut
                }
            }
        }
        return days
    }

    /// The tracked stretches inside a period, earliest first.
    func stretches(in interval: DateInterval, project: UUID?, now: Date) -> [OverviewStretch] {
        tasks.filter { project == nil || $0.projectId == project }.flatMap { task in
            task.entries.compactMap { entry -> OverviewStretch? in
                let start = max(entry.start, interval.start)
                let end = min(entry.end ?? now, interval.end)
                return end > start ? OverviewStretch(id: entry.id, task: task, start: start, end: end) : nil
            }
        }
        .sorted { $0.start < $1.start }
    }

    /// The hours aimed at per working day, in seconds: the space's own, or every space's added up.
    func dailyTarget(project: UUID?) -> TimeInterval {
        projects.filter { project == nil || $0.id == project }
            .reduce(0) { $0 + max(0, $1.dailyTargetHours ?? 0) * 3600 }
    }
}
