import Foundation

enum GermanFormat {
    static func count(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: ".")
    }

    static func decimal(_ value: Double, fractionDigits: Int) -> String {
        let scale = pow(10, Double(fractionDigits))
        let rounded = (value * scale).rounded() / scale
        let integer = Int(rounded.rounded(.towardZero))
        guard fractionDigits > 0 else { return count(integer) }
        let fraction = Int((abs(rounded - Double(integer)) * scale).rounded())
        let paddedFraction =
            String(repeating: "0", count: max(0, fractionDigits - String(fraction).count))
            + String(fraction)
        return "\(count(integer)),\(paddedFraction)"
    }

    /// Decimal units like the Finder: 1 KB = 1000 bytes.
    static func bytes(_ value: Int64) -> String {
        guard value >= 1000 else { return "\(value) Byte" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var scaled = Double(value) / 1000
        var unitIndex = 0
        while (scaled * 10).rounded() / 10 >= 1000, unitIndex < units.count - 1 {
            scaled /= 1000
            unitIndex += 1
        }
        return "\(decimal(scaled, fractionDigits: 1)) \(units[unitIndex])"
    }

    static func rate(megabytesPerSecond: Double) -> String {
        let isWhole = megabytesPerSecond == megabytesPerSecond.rounded()
        return "\(decimal(megabytesPerSecond, fractionDigits: isWhole ? 0 : 1)) MB/s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded())) %"
    }

    /// Rounded to whole minutes from one minute on, for lists: "31 Sek.", "3 Min.", "1 Std. 5 Min.".
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) Sek." }
        return hoursAndMinutes(Int((Double(seconds) / 60).rounded()))
    }

    /// With seconds below one hour, for details: "3 Min. 17 Sek.".
    static func preciseDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) Sek." }
        if seconds < 3600 {
            let remainder = seconds % 60
            return remainder == 0 ? "\(seconds / 60) Min." : "\(seconds / 60) Min. \(remainder) Sek."
        }
        return hoursAndMinutes(seconds / 60)
    }

    private static func hoursAndMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) Min." }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) Std." : "\(minutes / 60) Std. \(remainder) Min."
    }

    static func hours(_ interval: TimeInterval) -> String {
        let hours = Int((interval / 3600).rounded())
        return hours == 1 ? "1 Stunde" : "\(count(hours)) Stunden"
    }

    static func remaining(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "noch weniger als 1 Min." }
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "noch ca. \(minutes) Min." }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "noch ca. \(hours) Std." : "noch ca. \(hours) Std. \(remainder) Min."
    }

    /// Ends a sentence, without doubling the dot of a date like "So., 11.10.".
    static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }

    static func quoted(_ text: String) -> String {
        "„\(text)“"
    }
}
