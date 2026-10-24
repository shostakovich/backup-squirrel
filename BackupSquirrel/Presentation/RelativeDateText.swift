import Foundation

struct RelativeDateText {
    private static let weekdays = ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."]

    let calendar: Calendar

    /// Lowercase, for use inside a sentence: "zuletzt gesichert heute, 13:02".
    func string(for date: Date, now: Date) -> String {
        "\(day(for: date, now: now)), \(time(date))"
    }

    /// Capitalised, for values that stand alone such as table cells: "Heute, 13:02".
    func standalone(for date: Date, now: Date) -> String {
        Self.capitalized(string(for: date, now: now))
    }

    func standaloneDay(for date: Date, now: Date) -> String {
        Self.capitalized(day(for: date, now: now))
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "heute geprüft", but "am Mo., 12.10. geprüft".
    func onDay(for date: Date, now: Date) -> String {
        abs(days(from: now, to: date)) <= 1 ? day(for: date, now: now) : "am \(day(for: date, now: now))"
    }

    func day(for date: Date, now: Date) -> String {
        switch days(from: now, to: date) {
        case 0: return "heute"
        case -1: return "gestern"
        case 1: return "morgen"
        default:
            let parts = calendar.dateComponents([.day, .month, .year, .weekday], from: date)
            let weekday = Self.weekdays[(parts.weekday ?? 1) - 1]
            let dayAndMonth = String(format: "%02d.%02d.", parts.day ?? 0, parts.month ?? 0)
            let year = parts.year == calendar.component(.year, from: now) ? "" : String(parts.year ?? 0)
            return "\(weekday), \(dayAndMonth)\(year)"
        }
    }

    private func days(from now: Date, to date: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date))
            .day ?? 0
    }

    func time(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
