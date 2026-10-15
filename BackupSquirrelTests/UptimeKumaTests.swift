import Foundation
import Synchronization
import Testing

@testable import BackupSquirrel

struct UptimeKumaTests {
    private let statistics = BackupStatistics(filesNew: 214, filesChanged: 87, bytesAdded: 312_427_000)

    @Test func thePushReplacesStatusMessageAndPingButKeepsTheToken() throws {
        let url = try #require(
            UptimeKuma.url(
                " https://uptime.example.com/api/push/abc?status=down&msg=OK&ping=&extra=1 ", message: "214 neu",
                ping: 1500))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/push/abc")
        #expect(
            components.queryItems == [
                URLQueryItem(name: "extra", value: "1"), URLQueryItem(name: "status", value: "up"),
                URLQueryItem(name: "msg", value: "214 neu"), URLQueryItem(name: "ping", value: "1500"),
            ])
    }

    @Test(arguments: ["", "not a url", "ftp://uptime.example.com/x", "/api/push/abc"])
    func anUnusablePushURLBuildsNothing(pushURL: String) {
        #expect(UptimeKuma.url(pushURL, message: "x", ping: 0) == nil)
    }

    @Test func theMessageSummarizesTheBackupInGerman() {
        #expect(UptimeKuma.message(for: statistics) == "214 neu, 87 geändert, 312,4 MB")
    }

    @Test(arguments: [
        (200, #"{"ok":true}"#, PushFailure?.none),
        (200, "", nil),
        (200, #"{"ok":false,"msg":"Monitor not found or not active."}"#, .rejected(statusCode: 200)),
        (404, #"{"ok":false}"#, .rejected(statusCode: 404)),
        (500, "", .rejected(statusCode: 500)),
    ])
    func answersMapToPushFailures(statusCode: Int, body: String, expected: PushFailure?) {
        #expect(UptimeKuma.failure(statusCode: statusCode, body: Data(body.utf8)) == expected)
    }

    @Test func aPushCallsTheURLWithTheDurationInMilliseconds() async {
        let requested = Mutex<[URL]>([])
        let kuma = UptimeKuma { url in
            requested.withLock { $0.append(url) }
            return (Data(#"{"ok":true}"#.utf8), 200)
        }
        let failure = await kuma.push(
            to: "https://uptime.example.com/api/push/abc", statistics: statistics, duration: 12.3456)
        #expect(failure == nil)
        let query = requested.withLock { $0 }.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        #expect(query?.queryItems?.first { $0.name == "ping" }?.value == "12346")
        #expect(query?.queryItems?.first { $0.name == "status" }?.value == "up")
    }

    @Test func aTransportErrorMeansUnreachable() async {
        let kuma = UptimeKuma { _ in throw URLError(.notConnectedToInternet) }
        #expect(
            await kuma.push(to: "https://uptime.example.com/api/push/abc", statistics: statistics, duration: 1)
                == .unreachable)
    }
}
