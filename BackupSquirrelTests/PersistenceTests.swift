import Foundation
import Testing

@testable import BackupSquirrel

@MainActor
struct PersistenceTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "BackupSquirrelTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var store: BackupStore { BackupStore(directory: directory) }

    private var configuration: StoredConfiguration {
        var target = Fixture.target()
        target.uploadLimitKiBPerSecond = 2441
        target.connectedAt = Fixture.date(2026, 10, 10, 9, 30)
        target.sshKey.isInstalled = true
        var data = Fixture.plan(
            id: Fixture.dataID, name: "Daten", automatic: false,
            sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)],
            schedule: .daily(at: TimeOfDay(hour: 3, minute: 0)), uptimeKumaPushURL: "https://uptime.example.com/x")
        data.exclusions = [.path(URL(fileURLWithPath: "/Volumes/Daten/Cache", isDirectory: true)), .pattern("*.tmp")]
        return StoredConfiguration(hostName: "roberts-mac", targets: [target], plans: [Fixture.plan(), data])
    }

    private let runs: [Run] = [
        Fixture.backup(
            at: Fixture.date(2026, 10, 14, 13, 2),
            statistics: BackupStatistics(
                filesNew: 1, bytesAdded: 2, snapshotID: "9b31d2c7", unreadableFiles: ["/a"], snapshotsForgotten: 3),
            monitorPush: MonitorPush(sentAt: Fixture.date(2026, 10, 14, 13, 6), failure: .rejected(statusCode: 404))
        ),
        Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 12, 2), failure: .other("Repository gesperrt")),
        Fixture.backup(status: .failed, at: Fixture.date(2026, 10, 14, 11, 2)),
        Fixture.check(status: .failed, at: Fixture.date(2026, 10, 12, 4, 0), errorCount: 2),
        Fixture.prune(at: Fixture.date(2026, 10, 11, 5, 0)),
    ]

    @Test func targetsPlansAndRunsSurviveARoundTrip() throws {
        try store.save(configuration)
        try store.saveHistory(runs, now: Fixture.now, calendar: Fixture.calendar)
        let loaded = store.load(now: Fixture.now)
        #expect(loaded.configuration == configuration)
        #expect(loaded.runs == runs)
        #expect(loaded.problems.isEmpty)
    }

    @Test func theFilesAreReadableJSONWithISODatesAndNoSecrets() throws {
        try store.save(configuration)
        let text = try String(contentsOf: store.configurationURL, encoding: .utf8)
        #expect(text.contains(#""hostName" : "roberts-mac""#))
        #expect(text.contains(#""createdAt" : "2026-10-09T22:00:00.000Z""#))
        #expect(text.contains(#""daily" : {"#))
        #expect(text.contains(#""everyHours" : 1"#))
        #expect(text.contains(#""pattern" : "*.tmp""#))
        #expect(!text.contains("_0"))
        #expect(!text.contains("geheim"))
    }

    @Test func historyOlderThanTwelveMonthsIsDroppedOnSave() throws {
        let old = Fixture.backup(at: Fixture.date(2025, 10, 14, 13, 0))
        let kept = Fixture.backup(at: Fixture.date(2025, 10, 14, 13, 30))
        try store.saveHistory([old, kept], now: Fixture.now, calendar: Fixture.calendar)
        #expect(store.load(now: Fixture.now).runs == [kept])
    }

    @Test func aRunStillMarkedRunningFailedByTheQuitSoItsRetryIsDue() throws {
        let daily = Fixture.plan(schedule: .daily(at: TimeOfDay(hour: 3, minute: 0)))
        let running = Fixture.backup(status: .running, at: Fixture.date(2026, 10, 14, 3, 0))
        try store.saveHistory([running], now: Fixture.now, calendar: Fixture.calendar)
        let run = try #require(store.load(now: Fixture.now).runs.first)
        #expect(run.status == .failed)
        #expect(run.failure == .interrupted)
        #expect(run.finishedAt == Fixture.date(2026, 10, 14, 3, 0))
        let status = StatusEvaluator(calendar: Fixture.calendar).status(
            of: daily, in: Fixture.state(plans: [daily], runs: [run]))
        #expect(status.nextRun == .catchUp)
    }

    @Test func nothingSavedYetLoadsEmptyWithoutProblems() {
        let loaded = store.load(now: Fixture.now)
        #expect(loaded.configuration == nil)
        #expect(loaded.runs.isEmpty)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.savesConfiguration && loaded.savesHistory)
    }

    @Test func anUnreadableFileIsMovedAsideAndReported() throws {
        try store.saveHistory(runs, now: Fixture.now, calendar: Fixture.calendar)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.configurationURL)

        let loaded = store.load(now: Fixture.now)
        #expect(loaded.configuration == nil)
        #expect(loaded.runs == runs)
        let problem = try #require(loaded.problems.first)
        #expect(problem.file == store.configurationURL)
        let movedTo = try #require(problem.movedTo)
        #expect(try String(contentsOf: movedTo, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: store.configurationURL.path))
        #expect(loaded.savesConfiguration)
        #expect(BackupStore.report(loaded.problems).contains("configuration.json wurde als configuration.unreadable-"))
    }

    @Test func anUnreadableFileThatCannotBeMovedIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("kaputt".utf8).write(to: store.historyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let loaded = store.load(now: Fixture.now)
        #expect(loaded.problems == [StoreProblem(file: store.historyURL, movedTo: nil)])
        #expect(!loaded.savesHistory)
        #expect(loaded.savesConfiguration)
        #expect(BackupStore.report(loaded.problems) == "history.json bleibt unverändert und wird nicht überschrieben.")
    }

    @Test func theModelIsSavedWhenItChanges() async throws {
        let model = AppModel(
            targets: [Fixture.target()], plans: [Fixture.plan()], passwords: InMemoryPasswordStore(),
            connection: MockConnection(), keys: MockKeys(), calendar: Fixture.calendar, currentDate: { Fixture.now },
            executor: MockRunExecutor())
        let persistence = ModelPersistence(model: model, store: store, hostName: "roberts-mac")
        persistence.flush()
        #expect(store.load(now: Fixture.now).configuration?.plans == [Fixture.plan()])

        model.plans[0].name = "Umbenannt"
        await eventually {
            persistence.flush()
            return store.load(now: Fixture.now).configuration?.plans.first?.name == "Umbenannt"
        }
        #expect(store.load(now: Fixture.now).configuration?.plans.first?.name == "Umbenannt")
        #expect(store.load(now: Fixture.now).configuration?.hostName == "roberts-mac")

        model.start(.backup(Fixture.homeID))
        await eventually {
            persistence.flush()
            return store.load(now: Fixture.now).runs.count == 1
        }
        #expect(store.load(now: Fixture.now).runs.first?.failure == .interrupted)
    }

    @Test func flushingWritesAChangeBeforeItsObserverRuns() {
        let model = AppModel(
            targets: [Fixture.target()], plans: [Fixture.plan()], passwords: InMemoryPasswordStore(),
            connection: MockConnection(), keys: MockKeys(), calendar: Fixture.calendar, currentDate: { Fixture.now },
            executor: MockRunExecutor())
        let persistence = ModelPersistence(model: model, store: store, hostName: "roberts-mac")
        model.plans[0].name = "Umbenannt"
        persistence.flush()
        #expect(store.load(now: Fixture.now).configuration?.plans.first?.name == "Umbenannt")
    }

    @Test func aFileThatMustNotBeOverwrittenIsNotSaved() async throws {
        let model = AppModel(
            plans: [Fixture.plan()], passwords: InMemoryPasswordStore(), connection: MockConnection(),
            keys: MockKeys(), calendar: Fixture.calendar, currentDate: { Fixture.now }, executor: MockRunExecutor())
        let persistence = ModelPersistence(
            model: model, store: store, hostName: "roberts-mac", savesConfiguration: false)
        persistence.flush()
        #expect(!FileManager.default.fileExists(atPath: store.configurationURL.path))
        #expect(FileManager.default.fileExists(atPath: store.historyURL.path))
    }

    @Test func theHostNameIsTheMacsNameWithoutSpacesOrPunctuation() {
        #expect(HostName.sanitized("Roberts-MacBook-Pro.local") == "Roberts-MacBook-Pro")
        #expect(HostName.sanitized("Robert’s Mac mini") == "Robert-s-Mac-mini")
        #expect(HostName.sanitized("Mäc  Studio!") == "M-c-Studio")
        #expect(HostName.sanitized("…") == "mac")
        #expect(!HostName.ofThisMac().isEmpty)
    }
}
