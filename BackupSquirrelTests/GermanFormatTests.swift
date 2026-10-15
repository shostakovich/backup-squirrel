import Testing

@testable import BackupSquirrel

struct GermanFormatTests {
    @Test(
        arguments: [
            (0, "0"), (999, "999"), (1_000, "1.000"), (12_345, "12.345"), (1_234_567, "1.234.567"), (-1_234, "-1.234"),
        ] as [(Int, String)])
    func groupsThousandsWithDots(value: Int, expected: String) {
        #expect(GermanFormat.count(value) == expected)
    }

    @Test(
        arguments: [
            (812, "812 Byte"),
            (1_000, "1,0 KB"),
            (312_427_000, "312,4 MB"),
            (2_104_000_000, "2,1 GB"),
            (999_960, "1,0 MB"),
            (41_215_000_000_000, "41,2 TB"),
        ] as [(Int64, String)])
    func formatsBytesInDecimalUnitsWithDecimalComma(bytes: Int64, expected: String) {
        #expect(GermanFormat.bytes(bytes) == expected)
    }

    @Test(arguments: [(0.4271, "43 %"), (0, "0 %"), (1, "100 %"), (1.2, "100 %"), (-0.1, "0 %")] as [(Double, String)])
    func formatsWholePercent(fraction: Double, expected: String) {
        #expect(GermanFormat.percent(fraction) == expected)
    }

    @Test(
        arguments: [
            (31, "31 Sek."), (197, "3 Min."), (210, "4 Min."), (720, "12 Min."), (725, "12 Min."),
            (3_600, "1 Std."), (3_900, "1 Std. 5 Min."),
        ] as [(Double, String)])
    func roundsDurationsForListsSoTheyCannotBeMistakenForClockTimes(seconds: Double, expected: String) {
        #expect(GermanFormat.duration(seconds) == expected)
    }

    @Test(
        arguments: [
            (42, "42 Sek."), (197, "3 Min. 17 Sek."), (180, "3 Min."), (725, "12 Min. 5 Sek."),
            (3_725, "1 Std. 2 Min."),
        ] as [(Double, String)])
    func keepsSecondsInDetails(seconds: Double, expected: String) {
        #expect(GermanFormat.preciseDuration(seconds) == expected)
    }

    @Test(
        arguments: [
            (30, "noch weniger als 1 Min."), (1_100, "noch ca. 18 Min."), (3_900, "noch ca. 1 Std. 5 Min."),
            (7_200, "noch ca. 2 Std."),
        ] as [(Double, String)])
    func formatsRemainingTime(seconds: Double, expected: String) {
        #expect(GermanFormat.remaining(seconds) == expected)
    }

    @Test func formatsHoursAndRates() {
        #expect(GermanFormat.hours(7_200) == "2 Stunden")
        #expect(GermanFormat.hours(172_800) == "48 Stunden")
        #expect(GermanFormat.rate(megabytesPerSecond: 1) == "1 MB/s")
        #expect(GermanFormat.rate(megabytesPerSecond: 2.5) == "2,5 MB/s")
    }

    @Test func quotesWithGermanQuotationMarks() {
        #expect(GermanFormat.quoted("Daten") == "„Daten“")
    }
}
