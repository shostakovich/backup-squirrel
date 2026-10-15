import Foundation

// Enums with associated values are written as one-key objects, so the JSON stays readable without `_0` keys.

extension Schedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case everyHours
        case daily
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let hours = try container.decodeIfPresent(Int.self, forKey: .everyHours) {
            self = .everyHours(hours)
        } else {
            self = .daily(at: try container.decode(TimeOfDay.self, forKey: .daily))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everyHours(let hours): try container.encode(hours, forKey: .everyHours)
        case .daily(let time): try container.encode(time, forKey: .daily)
        }
    }
}

extension Exclusion: Codable {
    private enum CodingKeys: String, CodingKey {
        case path
        case pattern
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let url = try container.decodeIfPresent(URL.self, forKey: .path) {
            self = .path(url)
        } else {
            self = .pattern(try container.decode(String.self, forKey: .pattern))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .path(let url): try container.encode(url, forKey: .path)
        case .pattern(let pattern): try container.encode(pattern, forKey: .pattern)
        }
    }
}

extension RunFailure: Codable {
    private enum CodingKeys: String, CodingKey {
        case targetUnreachable
        case other
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try container.decodeIfPresent(String.self, forKey: .other) {
            self = .other(message)
        } else {
            _ = try container.decode(Bool.self, forKey: .targetUnreachable)
            self = .targetUnreachable
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .targetUnreachable: try container.encode(true, forKey: .targetUnreachable)
        case .other(let message): try container.encode(message, forKey: .other)
        }
    }
}

extension RunDetails: Codable {
    private enum CodingKeys: String, CodingKey {
        case backup
        case check
        case prune
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let statistics = try container.decodeIfPresent(BackupStatistics.self, forKey: .backup) {
            self = .backup(statistics)
        } else if let statistics = try container.decodeIfPresent(CheckStatistics.self, forKey: .check) {
            self = .check(statistics)
        } else {
            self = .prune(try container.decode(PruneStatistics.self, forKey: .prune))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .backup(let statistics): try container.encode(statistics, forKey: .backup)
        case .check(let statistics): try container.encode(statistics, forKey: .check)
        case .prune(let statistics): try container.encode(statistics, forKey: .prune)
        }
    }
}

enum StoredJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.format))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? Self.format.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }

    private static let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
