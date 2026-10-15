import Foundation
import Testing

@testable import BackupSquirrel

struct ScheduleTests {
    private let calendar = Fixture.calendar
    private let threeAM = TimeOfDay(hour: 3, minute: 0)

    @Test func hourlyRunsOneIntervalAfterTheLastStart() {
        let next = Schedule.everyHours(1).nextRun(
            after: Fixture.date(2026, 10, 14, 13, 2), now: Fixture.now, calendar: calendar)
        #expect(next == Fixture.date(2026, 10, 14, 14, 2))
    }

    @Test func intervalRunIsDueNowWhenMissed() {
        let next = Schedule.everyHours(3).nextRun(
            after: Fixture.date(2026, 10, 14, 8, 0), now: Fixture.now, calendar: calendar)
        #expect(next == Fixture.now)
    }

    @Test func intervalPlanThatNeverRanIsDueNow() {
        #expect(Schedule.everyHours(6).nextRun(after: nil, now: Fixture.now, calendar: calendar) == Fixture.now)
    }

    @Test func dailyRunsTomorrowAfterTodaysRun() {
        let next = Schedule.daily(at: threeAM).nextRun(
            after: Fixture.date(2026, 10, 14, 3, 0), now: Fixture.now, calendar: calendar)
        #expect(next == Fixture.date(2026, 10, 15, 3, 0))
    }

    @Test func dailyPlanThatNeverRanWaitsForItsTime() {
        let schedule = Schedule.daily(at: threeAM)
        #expect(schedule.nextRun(after: nil, now: Fixture.now, calendar: calendar) == Fixture.date(2026, 10, 15, 3, 0))
        #expect(
            schedule.nextRun(after: nil, now: Fixture.date(2026, 10, 14, 2, 0), calendar: calendar)
                == Fixture.date(2026, 10, 14, 3, 0))
    }

    @Test func dailyRunIsDueNowWhenItsTimePassedWhileTheMacWasAsleep() {
        let next = Schedule.daily(at: threeAM).nextRun(
            after: Fixture.date(2026, 10, 12, 3, 0), now: Fixture.now, calendar: calendar)
        #expect(next == Fixture.now)
    }

    @Test func dailyTimeSkippedByDaylightSavingMovesToTheNextValidTime() {
        let next = Schedule.daily(at: TimeOfDay(hour: 2, minute: 30)).nextRun(
            after: Fixture.date(2026, 3, 28, 2, 30), now: Fixture.date(2026, 3, 28, 13, 0), calendar: calendar)
        #expect(next == Fixture.date(2026, 3, 29, 3, 0))
    }

    @Test func nominalIntervals() {
        #expect(Schedule.everyHours(6).nominalInterval == 6 * 3600)
        #expect(Schedule.daily(at: threeAM).nominalInterval == 24 * 3600)
    }
}
