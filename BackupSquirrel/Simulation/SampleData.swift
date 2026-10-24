import Foundation

enum SampleScenario: String, CaseIterable, Sendable {
    case idle
    case running
    case warning
    case error
    case overdue
    case manual
    case incomplete
    case checkErrors = "check-errors"
    case checkFailed = "check-failed"
    case checkOverdue = "check-overdue"
    case noFullDiskAccess = "no-full-disk-access"
    case noLoginItem = "no-login-item"
    case notificationsDenied = "notifications-denied"
    case empty

    /// The overdue plan backs up an external volume that is not connected.
    var system: SystemState {
        SystemState(
            hasFullDiskAccess: self != .noFullDiskAccess, opensAtLogin: self != .noLoginItem,
            notifications: self == .notificationsDenied ? .denied : .allowed,
            mountedVolumes: self == .overdue ? ["/"] : nil)
    }
}

/// Example values only: no real hosts, users or tokens.
struct SampleData {
    static let storageBoxID = UUID(uuidString: "5B5B0001-0000-4000-8000-000000000001")!
    static let homePlanID = UUID(uuidString: "5B5B0002-0000-4000-8000-000000000001")!
    static let dataPlanID = UUID(uuidString: "5B5B0002-0000-4000-8000-000000000002")!

    static let runningProgress = OperationProgress(
        fractionCompleted: 12_345.0 / 28_901.0,
        filesDone: 12_345,
        filesTotal: 28_901,
        bytesDone: 17_604_000_000,
        bytesTotal: 41_215_000_000,
        secondsRemaining: 18 * 60
    )

    let scenario: SampleScenario
    let now: Date
    let calendar: Calendar

    var targets: [Target] {
        guard scenario != .empty else { return [] }
        return [
            Target(
                id: Self.storageBoxID,
                name: "Storage Box",
                host: "u123456.your-storagebox.de",
                user: "u123456-sub1",
                port: 23,
                path: "/home/restic/mac",
                uploadLimitKiBPerSecond: UploadLimit.kibPerSecond(megabytesPerSecond: 2.5),
                sshKey: SSHKey(
                    publicKey:
                        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq7Lw2bXf9VtR3pZ8Hn4kQwE6sDfGhJ1aQ5uYxT0oPm backup-squirrel",
                    publicKeyPath: "Library/Application Support/Backup-Squirrel/Keys/storage-box.pub",
                    isInstalled: true
                ),
                createdAt: now.addingTimeInterval(-120 * 24 * 3600)
            )
        ]
    }

    var repositoryPasswords: [Target.ID: String] {
        scenario == .empty ? [:] : [Self.storageBoxID: "beispiel-passwort-nicht-verwenden"]
    }

    var plans: [Plan] {
        guard scenario != .empty else { return [] }
        let created = now.addingTimeInterval(-90 * 24 * 3600)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            Plan(
                id: Self.homePlanID,
                name: "Home-Verzeichnis",
                targetID: Self.storageBoxID,
                sourceFolders: [home],
                exclusions: [
                    .path(home.appendingPathComponent("Library/Caches", isDirectory: true)),
                    .path(home.appendingPathComponent(".Trash", isDirectory: true)),
                    .pattern("*.tmp"),
                    .pattern("node_modules"),
                ],
                schedule: .everyHours(1),
                uptimeKumaPushURL: "https://uptime.example.com/api/push/abc123?status=up&msg=OK&ping=",
                createdAt: created
            ),
            Plan(
                id: Self.dataPlanID,
                name: "Daten",
                targetID: scenario == .incomplete ? nil : Self.storageBoxID,
                backsUpAutomatically: scenario != .manual,
                sourceFolders: [URL(fileURLWithPath: "/Volumes/Daten", isDirectory: true)],
                exclusions: [.pattern(".Spotlight-V100"), .pattern(".fseventsd"), .pattern(".DocumentRevisions-V100")],
                schedule: .daily(at: TimeOfDay(hour: 3, minute: 0)),
                uptimeKumaPushURL: "https://uptime.example.com/api/push/def456?status=up&msg=OK&ping=",
                createdAt: created
            ),
        ]
    }

    /// The running backup is started separately so it can progress.
    var runs: [Run] {
        guard scenario != .empty, let target = targets.first else { return [] }
        let plans = plans
        var runs = homeRuns(plan: plans[0], target: target) + dataRuns(plan: plans[1], target: target)
        runs += maintenanceRuns(target: target)
        return runs.sorted { $0.startedAt < $1.startedAt }
    }

    var runningBackupStart: Date { latest(minute: 2) }

    private func homeRuns(plan: Plan, target: Target) -> [Run] {
        let latestStart = latest(minute: 2)
        var runs = (0..<10).compactMap { hoursAgo -> Run? in
            if hoursAgo == 0, scenario == .running || scenario == .error { return nil }
            let start = latestStart.addingTimeInterval(-Double(hoursAgo) * 3600)
            let seed = hoursAgo + 1
            let unreadable =
                hoursAgo == 3 || (hoursAgo == 0 && (scenario == .warning || scenario == .noFullDiskAccess))
                ? [
                    "\(NSHomeDirectory())/Library/Mail/V10/MailData/Envelope Index-wal",
                    "\(NSHomeDirectory())/Library/Safari/History.db-lock",
                    "\(NSHomeDirectory())/Library/Containers/com.apple.Notes/Data/Library/Notes/NotesV7.storedata",
                ] : []
            if hoursAgo == 6 {
                return Run(
                    planID: plan.id, targetID: target.id, status: .cancelled, startedAt: start,
                    finishedAt: start.addingTimeInterval(74), details: .backup(BackupStatistics()),
                    output: "open repository\nlock repository\nload index files\nstart scan on [\(NSHomeDirectory())]\n"
                        + "signal interrupt received, cleaning up"
                )
            }
            return backupRun(
                plan: plan, target: target, start: start, seed: seed,
                filesTotal: 28_901, bytesProcessed: 41_215_000_000, duration: 180 + Double(seed * 17 % 90),
                unreadableFiles: unreadable
            )
        }
        if scenario == .error {
            // The scheduled run and its first retry 15 minutes later both failed.
            let firstAttempt = latestStart
            let retry = firstAttempt.addingTimeInterval(31 + 15 * 60)
            for start in [firstAttempt, retry] {
                runs.append(
                    Run(
                        planID: plan.id, targetID: target.id, status: .failed, startedAt: start,
                        finishedAt: start.addingTimeInterval(31), details: .backup(BackupStatistics()),
                        failure: .targetUnreachable, output: SampleOutput.unreachable(target)))
            }
        }
        return runs
    }

    private func dataRuns(plan: Plan, target: Target) -> [Run] {
        let latestStart = latest(hour: 3, minute: 0)
        let skippedDays =
            switch scenario {
            case .overdue: 3
            case .manual: 2
            case .incomplete: 1
            default: 0
            }
        return (skippedDays..<14).map { daysAgo in
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: latestStart) ?? latestStart
            if daysAgo == 5 {
                return Run(
                    planID: plan.id, targetID: target.id, status: .failed, startedAt: start,
                    finishedAt: start.addingTimeInterval(31), details: .backup(BackupStatistics()),
                    failure: .targetUnreachable, output: SampleOutput.unreachable(target)
                )
            }
            var run = backupRun(
                plan: plan, target: target, start: start, seed: daysAgo + 20,
                filesTotal: 4_120, bytesProcessed: 182_400_000_000, duration: 720 + Double(daysAgo * 53 % 600),
                unreadableFiles: daysAgo == 9 ? ["/Volumes/Daten/Fotos/2019/IMG_4711.HEIC"] : []
            )
            if daysAgo == 0, scenario == .warning, let finishedAt = run.finishedAt {
                run.monitorPush = MonitorPush(sentAt: finishedAt, failure: .rejected(statusCode: 404))
            }
            return run
        }
    }

    private func maintenanceRuns(target: Target) -> [Run] {
        let lastCheck = latest(hour: 4, minute: 0)
        let lastPrune = latest(weekday: 1, hour: 5)
        var runs: [Run] = []
        let checks = scenario == .checkOverdue ? [(3, 5), (4, 4)] : [(0, 7), (1, 6)]
        for (daysAgo, subset) in checks {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: lastCheck) ?? lastCheck
            let duration: TimeInterval = 1_420 + Double(daysAgo * 31)
            if daysAgo == 0, scenario == .checkFailed {
                runs += failedChecks(target: target, from: latest(hour: 12, minute: 50))
                continue
            }
            let errors = daysAgo == 0 && scenario == .checkErrors ? 3 : 0
            let statistics = CheckStatistics(subset: subset, errorCount: errors)
            runs.append(
                Run(
                    targetID: target.id, status: errors > 0 ? .failed : .success, startedAt: start,
                    finishedAt: start.addingTimeInterval(duration), details: .check(statistics),
                    output: SampleOutput.check(statistics, packs: 412 - daysAgo * 9, duration: duration)
                )
            )
        }
        if scenario == .checkOverdue {
            runs.append(
                Run(
                    targetID: target.id, status: .cancelled, startedAt: lastCheck,
                    finishedAt: lastCheck.addingTimeInterval(41), details: .check(CheckStatistics(subset: 6)),
                    output: "create exclusive lock for repository\nload indexes\nsignal interrupt received, cleaning up"
                ))
        }
        for (weeksAgo, removed) in [(0, 14), (1, 12)] {
            let start = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: lastPrune) ?? lastPrune
            let statistics = PruneStatistics(
                snapshotsRemoved: removed, bytesFreed: Int64(2_104_000_000 - weeksAgo * 391_000_000))
            runs.append(
                Run(
                    targetID: target.id, status: .success, startedAt: start,
                    finishedAt: start.addingTimeInterval(97 + Double(weeksAgo * 12)),
                    details: .prune(statistics), output: SampleOutput.prune(statistics)
                )
            )
        }
        return runs
    }

    /// The day's check, caught up at midday, and its first retry 15 minutes later could not reach the target.
    private func failedChecks(target: Target, from start: Date) -> [Run] {
        let retry = start.addingTimeInterval(31 + 15 * 60)
        return [start, retry].map { attempt in
            Run(
                targetID: target.id, status: .failed, startedAt: attempt, finishedAt: attempt.addingTimeInterval(31),
                details: .check(CheckStatistics(subset: 7)), failure: .targetUnreachable,
                output: SampleOutput.unreachable(target))
        }
    }

    private func backupRun(
        plan: Plan, target: Target, start: Date, seed: Int, filesTotal: Int, bytesProcessed: Int64,
        duration: TimeInterval, unreadableFiles: [String]
    ) -> Run {
        let filesNew = 40 + seed * 37 % 260
        let filesChanged = 20 + seed * 23 % 140
        let statistics = BackupStatistics(
            filesNew: filesNew,
            filesChanged: filesChanged,
            filesUnmodified: filesTotal - filesNew - filesChanged,
            bytesAdded: Int64(18_000_000 + seed * 41_300_000 % 520_000_000),
            bytesProcessed: bytesProcessed,
            snapshotID: String(format: "%08x", (seed &* 2_654_435_761) & 0xffff_ffff),
            unreadableFiles: unreadableFiles
        )
        let finishedAt = start.addingTimeInterval(duration)
        return Run(
            planID: plan.id,
            targetID: target.id,
            status: unreadableFiles.isEmpty ? .success : .warning,
            startedAt: start,
            finishedAt: finishedAt,
            details: .backup(statistics),
            output: SampleOutput.backup(
                sources: plan.sourceFolders, statistics: statistics, duration: duration,
                parentSnapshot: String(format: "%08x", ((seed + 1) &* 2_654_435_761) & 0xffff_ffff)
            ),
            monitorPush: plan.reportsToUptimeKuma ? MonitorPush(sentAt: finishedAt) : nil
        )
    }

    private func latest(minute: Int) -> Date {
        latest(matching: DateComponents(minute: minute))
    }

    private func latest(hour: Int, minute: Int) -> Date {
        latest(matching: DateComponents(hour: hour, minute: minute))
    }

    private func latest(weekday: Int, hour: Int) -> Date {
        latest(matching: DateComponents(hour: hour, minute: 0, weekday: weekday))
    }

    private func latest(matching components: DateComponents) -> Date {
        calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, direction: .backward) ?? now
    }
}

extension SampleScenario {
    @MainActor
    /// Launched two hours ago, so the catch-up grace period is over and overdue plans show.
    func makeModel(
        now: Date = Date(),
        calendar: Calendar = .current,
        currentDate: @escaping () -> Date = Date.init,
        inspectSystem: (() -> SystemState)? = nil,
        executor: SimulatedRunExecutor = SimulatedRunExecutor()
    ) -> AppModel {
        let data = SampleData(scenario: self, now: now, calendar: calendar)
        let system = self.system
        let model = AppModel(
            targets: data.targets,
            plans: data.plans,
            runs: data.runs,
            passwords: InMemoryPasswordStore(data.repositoryPasswords),
            connection: SimulatedConnection(),
            keys: SimulatedSSHKeys(),
            calendar: calendar,
            currentDate: currentDate,
            awakeSince: now.addingTimeInterval(-2 * 3600),
            inspectSystem: inspectSystem ?? { system },
            executor: executor
        )
        if self == .running {
            executor.resumeProgress = SampleData.runningProgress
            model.start(.backup(SampleData.homePlanID), startedAt: data.runningBackupStart)
        }
        return model
    }
}
