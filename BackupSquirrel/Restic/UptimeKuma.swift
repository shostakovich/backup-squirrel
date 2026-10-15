import Foundation

struct UptimeKuma: Sendable {
    var fetch: @Sendable (URL) async throws -> (Data, Int)

    static let live = UptimeKuma { url in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func push(to pushURL: String, statistics: BackupStatistics, duration: TimeInterval) async -> PushFailure? {
        let message = Self.message(for: statistics)
        guard let url = Self.url(pushURL, message: message, ping: Int((duration * 1000).rounded())) else {
            return .unreachable
        }
        do {
            let (body, statusCode) = try await fetch(url)
            return Self.failure(statusCode: statusCode, body: body)
        } catch {
            return .unreachable
        }
    }

    static func message(for statistics: BackupStatistics) -> String {
        "\(GermanFormat.count(statistics.filesNew)) neu, \(GermanFormat.count(statistics.filesChanged)) geändert, "
            + GermanFormat.bytes(statistics.bytesAdded)
    }

    /// Replaces whatever status, message and ping the owner pasted with the push URL.
    static func url(_ pushURL: String, message: String, ping: Int) -> URL? {
        guard var components = URLComponents(string: pushURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https", components.host != nil
        else { return nil }
        let replaced: Set = ["status", "msg", "ping"]
        components.queryItems =
            (components.queryItems ?? []).filter { !replaced.contains($0.name) } + [
                URLQueryItem(name: "status", value: "up"),
                URLQueryItem(name: "msg", value: message),
                URLQueryItem(name: "ping", value: String(ping)),
            ]
        return components.url
    }

    /// Uptime Kuma answers an unknown push token with HTTP 404 or with `{"ok": false}`.
    static func failure(statusCode: Int, body: Data) -> PushFailure? {
        guard (200..<300).contains(statusCode) else { return .rejected(statusCode: statusCode) }
        struct Answer: Decodable { var ok: Bool? }
        if let answer = try? JSONDecoder().decode(Answer.self, from: body), answer.ok == false {
            return .rejected(statusCode: statusCode)
        }
        return nil
    }
}
