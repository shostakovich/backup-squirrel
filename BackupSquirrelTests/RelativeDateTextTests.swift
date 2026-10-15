import Foundation
import Testing

@testable import BackupSquirrel

struct RelativeDateTextTests {
    private let text = RelativeDateText(calendar: Fixture.calendar)

    @Test func today() {
        #expect(text.string(for: Fixture.date(2026, 10, 14, 13, 2), now: Fixture.now) == "heute, 13:02")
    }

    @Test func yesterdayAndTomorrow() {
        #expect(text.string(for: Fixture.date(2026, 10, 13, 3, 0), now: Fixture.now) == "gestern, 03:00")
        #expect(text.string(for: Fixture.date(2026, 10, 15, 3, 0), now: Fixture.now) == "morgen, 03:00")
    }

    @Test func otherDaysShowWeekdayAndDateSoPastAndFutureCannotBeConfused() {
        #expect(text.string(for: Fixture.date(2026, 10, 12, 4, 0), now: Fixture.now) == "Mo., 12.10., 04:00")
        #expect(text.string(for: Fixture.date(2026, 10, 19, 4, 0), now: Fixture.now) == "Mo., 19.10., 04:00")
    }

    @Test func otherYearsIncludeTheYear() {
        #expect(text.string(for: Fixture.date(2025, 12, 31, 23, 59), now: Fixture.now) == "Mi., 31.12.2025, 23:59")
    }

    @Test func standaloneValuesAreCapitalised() {
        #expect(text.standalone(for: Fixture.date(2026, 10, 14, 13, 2), now: Fixture.now) == "Heute, 13:02")
        #expect(text.standalone(for: Fixture.date(2026, 10, 13, 3, 0), now: Fixture.now) == "Gestern, 03:00")
        #expect(text.standaloneDay(for: Fixture.date(2026, 10, 12, 4, 0), now: Fixture.now) == "Mo., 12.10.")
    }

    @Test func comparesCalendarDaysNotTwentyFourHourSpans() {
        let justAfterMidnight = Fixture.date(2026, 10, 14, 0, 5)
        #expect(text.string(for: Fixture.date(2026, 10, 13, 23, 55), now: justAfterMidnight) == "gestern, 23:55")
    }
}
