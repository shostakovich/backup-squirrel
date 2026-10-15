import Foundation

struct Plan: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var targetID: Target.ID?
    var backsUpAutomatically: Bool
    var sourceFolders: [URL]
    var exclusions: [Exclusion]
    var schedule: Schedule
    var uptimeKumaPushURL: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        targetID: Target.ID?,
        backsUpAutomatically: Bool = true,
        sourceFolders: [URL] = [],
        exclusions: [Exclusion] = [],
        schedule: Schedule = .everyHours(1),
        uptimeKumaPushURL: String = "",
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.targetID = targetID
        self.backsUpAutomatically = backsUpAutomatically
        self.sourceFolders = sourceFolders
        self.exclusions = exclusions
        self.schedule = schedule
        self.uptimeKumaPushURL = uptimeKumaPushURL
        self.createdAt = createdAt
    }

    var reportsToUptimeKuma: Bool {
        !uptimeKumaPushURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum Exclusion: Hashable, Sendable {
    case path(URL)
    case pattern(String)
}
