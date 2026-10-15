import Foundation

struct TimeOfDay: Hashable, Sendable, Codable {
    var hour: Int
    var minute: Int
}

enum Schedule: Hashable, Sendable {
    static let intervalHours = [1, 2, 4, 6, 12]

    case everyHours(Int)
    case daily(at: TimeOfDay)

    /// The nominal gap between two runs, used to decide when a plan is overdue.
    var nominalInterval: TimeInterval {
        switch self {
        case .everyHours(let hours): TimeInterval(hours) * 3600
        case .daily: 24 * 3600
        }
    }

    /// When the next run is due, never earlier than `now`; a missed run is due immediately.
    func nextRun(after lastRun: Date?, now: Date, calendar: Calendar) -> Date {
        switch self {
        case .everyHours(let hours):
            guard let lastRun else { return now }
            let due = lastRun.addingTimeInterval(TimeInterval(hours) * 3600)
            return max(due, now)
        case .daily(let time):
            let components = DateComponents(hour: time.hour, minute: time.minute)
            if let lastRun,
                let dueAfterLastRun = calendar.nextDate(
                    after: lastRun, matching: components, matchingPolicy: .nextTime),
                dueAfterLastRun <= now
            {
                return now
            }
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now
        }
    }
}
