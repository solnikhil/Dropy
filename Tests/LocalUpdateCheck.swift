import Foundation
import DropyCore

actor UpdateFixtureTransport: ReleaseTransport {
    struct Fixture: Sendable {
        let status: Int
        let data: Data
        var etag: String? = nil
    }
    var requests: [URLRequest] = []
    private var fixtures: [Fixture]
    init(_ fixtures: [Fixture]) { self.fixtures = fixtures }
    func send(_ request: URLRequest) async throws -> ReleaseHTTPReply {
        requests.append(request)
        try await Task.sleep(for: .milliseconds(10))
        guard !fixtures.isEmpty else { throw URLError(.notConnectedToInternet) }
        let fixture = fixtures.removeFirst()
        return ReleaseHTTPReply(status: fixture.status, url: request.url!, data: fixture.data, etag: fixture.etag)
    }
}

@main
struct UpdateChecks {
    @MainActor static func main() async throws {
        let suite = "DropyUpdateChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func payload(_ version: String = "v1.2.0", url: String = "https://github.com/solnikhil/Dropy/releases/tag/v1.2.0", preview: Bool = false) -> Data {
            try! JSONSerialization.data(withJSONObject: ["tag_name": version, "html_url": url,
                "name": "Dropy", "body": "Release notes", "draft": false, "prerelease": preview])
        }
        let transport = UpdateFixtureTransport([.init(status: 200, data: payload(), etag: "\"release-1\""),
                                               .init(status: 304, data: Data())])
        let checker = UpdateChecker(client: ReleaseUpdateClient(transport: transport), installedVersion: "1.1.0", defaults: defaults)
        await checker.checkNow()
        precondition(checker.availableRelease?.version == "1.2.0")
        let firstChecked = checker.lastChecked
        precondition(firstChecked != nil && !checker.isChecking)
        await checker.checkNow()
        let requests = await transport.requests
        precondition(requests.count == 2 && requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"release-1\"")
        precondition(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil }, "public checks must not need credentials")
        precondition(checker.availableRelease?.version == "1.2.0", "304 must revalidate a known release")
        let successful = checker.lastChecked
        await checker.checkNow()
        if case .unavailable = checker.state {} else { preconditionFailure("offline must not report up to date") }
        precondition(checker.lastChecked == successful && !checker.isChecking)

        let reloadedTransport = UpdateFixtureTransport([.init(status: 304, data: Data())])
        let reloaded = UpdateChecker(client: ReleaseUpdateClient(transport: reloadedTransport), installedVersion: "1.1.0", defaults: defaults)
        await reloaded.checkNow()
        precondition(reloaded.availableRelease?.version == "1.2.0", "a fresh launch must check and validate its persisted cache")
        defaults.removePersistentDomain(forName: suite)

        let cases: [(fixtures: [UpdateFixtureTransport.Fixture], current: String, expected: String)] = [
            ([.init(status: 200, data: payload("v1.9.9"))], "1.10.0", "current"),
            ([.init(status: 200, data: payload("v1.2.0"))], "1.2.0+local.1", "current"),
            ([.init(status: 404, data: Data()), .init(status: 404, data: Data())], "1.0.0", "unavailable"),
            ([.init(status: 404, data: Data()), .init(status: 200, data: Data(#"{"full_name":"solnikhil/Dropy","private":false}"#.utf8))], "1.0.0", "none"),
            ([.init(status: 200, data: payload(url: "https://github.com/other/repo/releases/tag/v1.2.0"))], "1.0.0", "unavailable"),
            ([.init(status: 200, data: payload(url: "http://github.com/solnikhil/Dropy/releases/tag/v1.2.0"))], "1.0.0", "unavailable"),
            ([.init(status: 200, data: payload(preview: true))], "1.0.0", "unavailable"),
            ([.init(status: 200, data: payload("v1.2.0-beta"))], "1.0.0", "unavailable"),
            ([.init(status: 200, data: payload("release-name"))], "1.0.0", "unavailable"),
            ([.init(status: 200, data: Data("not JSON".utf8))], "1.0.0", "unavailable"),
            ([.init(status: 403, data: Data())], "1.0.0", "unavailable"),
            ([.init(status: 503, data: Data())], "1.0.0", "unavailable"),
            ([.init(status: 304, data: Data())], "1.0.0", "unavailable"),
        ]
        for test in cases {
            defaults.removePersistentDomain(forName: suite)
            let transport = UpdateFixtureTransport(test.fixtures)
            let checker = UpdateChecker(client: ReleaseUpdateClient(transport: transport), installedVersion: test.current, defaults: defaults)
            await checker.checkNow()
            switch (test.expected, checker.state) {
            case ("current", .current), ("none", .noReleases), ("unavailable", .unavailable): break
            default: preconditionFailure("Incorrect state: \(checker.state)")
            }
            precondition(!checker.isChecking)
            if test.expected == "unavailable" { precondition(checker.lastChecked == nil) }
        }
        defaults.removePersistentDomain(forName: suite)
        let concurrent = UpdateFixtureTransport([.init(status: 200, data: payload())])
        let coalesced = UpdateChecker(client: ReleaseUpdateClient(transport: concurrent), installedVersion: "1.0.0", defaults: defaults)
        async let first: Void = coalesced.checkNow()
        async let second: Void = coalesced.checkNow()
        _ = await (first, second)
        let count = await concurrent.requests.count
        precondition(count == 1, "concurrent manual/startup checks must coalesce")
        print("Release update checks passed (versions, cache, offline, private source, untrusted URLs, concurrency)")
    }
}
