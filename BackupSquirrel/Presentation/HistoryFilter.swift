import Foundation

enum HistoryScope: Hashable, Sendable {
    case all
    case plan(Plan.ID)
    case target(Target.ID)
}

struct HistoryFilter: Hashable, Sendable {
    var scope: HistoryScope = .all
    var kind: RunKind?
    var onlyProblems = false

    var isActive: Bool { scope != .all || kind != nil || onlyProblems }

    func apply(to runs: [Run]) -> [Run] {
        runs.filter { run in
            let inScope =
                switch scope {
                case .all: true
                case .plan(let id): run.planID == id
                case .target(let id): run.targetID == id
                }
            return inScope && (kind == nil || run.kind == kind) && (!onlyProblems || RunText.isProblem(run))
        }
    }
}

struct HistoryDay: Identifiable, Hashable, Sendable {
    var id: Date
    var title: String
    /// Empty for a day on which a plan was due but nothing ran.
    var runs: [Run]

    /// A heading row per day, because section headers make SwiftUI tables reload reentrantly.
    var rows: [HistoryRow] {
        [.day(self)] + runs.map(HistoryRow.run)
    }
}

enum HistoryRow: Identifiable, Hashable, Sendable {
    case day(HistoryDay)
    case run(Run)

    var id: String {
        switch self {
        case .day(let day): "day-\(day.id.timeIntervalSinceReferenceDate)"
        case .run(let run): run.id.uuidString
        }
    }

    var date: Date {
        switch self {
        case .day(let day): day.id
        case .run(let run): run.startedAt
        }
    }

    var run: Run? {
        if case .run(let run) = self { run } else { nil }
    }
}

extension HistoryDay {
    /// Keeps the order of `runs`, so a reversed sort also reverses the days.
    static func group(_ runs: [Run], calendar: Calendar, now: Date) -> [HistoryDay] {
        let dates = RelativeDateText(calendar: calendar)
        var days: [HistoryDay] = []
        for run in runs {
            let day = calendar.startOfDay(for: run.startedAt)
            if days.last?.id == day {
                days[days.count - 1].runs.append(run)
            } else {
                days.append(HistoryDay(id: day, title: dates.standaloneDay(for: run.startedAt, now: now), runs: [run]))
            }
        }
        return days
    }

    /// Also lists the past days on which nothing ran although an automatic plan was due, so a gap cannot hide.
    static func group(
        _ runs: [Run], calendar: Calendar, now: Date, dueSince: Date?, daysWithRuns: Set<Date>
    ) -> [HistoryDay] {
        let days = group(runs, calendar: calendar, now: now)
        guard let dueSince, let first = days.first?.id, let last = days.last?.id else { return days }
        let dates = RelativeDateText(calendar: calendar)
        let shown = Set(days.map(\.id))
        var day = max(min(first, last), calendar.startOfDay(for: dueSince))
        let today = calendar.startOfDay(for: now)
        var gaps: [HistoryDay] = []
        while day < today {
            if !shown.contains(day), !daysWithRuns.contains(day) {
                gaps.append(HistoryDay(id: day, title: dates.standaloneDay(for: day, now: now), runs: []))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let ascending = first <= last
        return (days + gaps).sorted { ascending ? $0.id < $1.id : $0.id > $1.id }
    }
}

extension HistoryFilter {
    /// The earliest day an automatic plan in this filter was due, if backups are shown at all.
    func dueSince(plans: [Plan]) -> Date? {
        guard kind == nil || kind == .backup else { return nil }
        let automatic = plans.filter { plan in
            guard plan.backsUpAutomatically, plan.targetID != nil, !plan.sourceFolders.isEmpty else { return false }
            switch scope {
            case .all: return true
            case .plan(let id): return plan.id == id
            case .target(let id): return plan.targetID == id
            }
        }
        return automatic.map(\.createdAt).min()
    }
}
