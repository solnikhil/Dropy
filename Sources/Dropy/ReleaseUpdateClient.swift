import Foundation
import DropyCore

struct PublishedRelease: Codable, Equatable, Sendable {
    let version: String
    let name: String
    let notes: String
    let url: URL
}

struct ReleaseCache: Codable, Sendable {
    let repository: String
    let release: PublishedRelease
    let etag: String?
    let checkedAt: Date
}

struct ReleaseHTTPReply: Sendable {
    let status: Int
    let url: URL
    let data: Data
    let etag: String?
}

protocol ReleaseTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ReleaseHTTPReply
}

struct PublicReleaseTransport: ReleaseTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }
    func send(_ request: URLRequest) async throws -> ReleaseHTTPReply {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else { throw ReleaseCheckError.invalidResponse }
        return ReleaseHTTPReply(status: response.statusCode, url: url, data: data,
                                etag: response.value(forHTTPHeaderField: "ETag"))
    }
}

enum ReleaseCheckError: LocalizedError {
    case invalidRepository, invalidResponse, invalidVersion, inaccessible, rateLimited, server(Int)
    var errorDescription: String? {
        switch self {
        case .invalidRepository: "The release repository is not configured correctly."
        case .invalidResponse: "The release server returned an invalid response. Try again later."
        case .invalidVersion: "The release has no supported version tag. Use a version such as v1.2.3."
        case .inaccessible: "The release source is not publicly accessible. Private repositories cannot supply public update checks."
        case .rateLimited: "GitHub has temporarily limited update checks. Try again later."
        case .server(let code): "The release server is unavailable (HTTP \(code)). Try again later."
        }
    }
}

struct ReleaseUpdateClient: Sendable {
    static let defaultRepository = "solnikhil/Dropy"
    let repository: String
    private let transport: any ReleaseTransport

    init(repository: String = Self.defaultRepository, transport: any ReleaseTransport = PublicReleaseTransport()) {
        self.repository = repository
        self.transport = transport
    }

    /// A nil release means a confirmed public repository without a stable release.
    func fetch(cache: ReleaseCache?) async throws -> (release: PublishedRelease?, etag: String?) {
        let cache = validated(cache)
        let response = try await request("/releases/latest", etag: cache?.etag)
        switch response.status {
        case 304:
            guard let cache else { throw ReleaseCheckError.invalidResponse }
            return (cache.release, cache.etag)
        case 200:
            guard response.data.count <= 1_048_576,
                  let item = try? JSONDecoder().decode(GitHubRelease.self, from: response.data),
                  !item.draft, !item.prerelease,
                  validReleaseURL(item.html_url) else { throw ReleaseCheckError.invalidResponse }
            guard let version = ReleaseVersion(item.tag_name), version.prerelease.isEmpty else { throw ReleaseCheckError.invalidVersion }
            let release = PublishedRelease(version: version.description,
                name: String((item.name ?? "Dropy \(version)").prefix(200)),
                notes: String((item.body ?? "").prefix(20_000)), url: item.html_url)
            return (release, response.etag)
        case 404:
            // GitHub also returns 404 for private repositories. Verify the repository
            // before interpreting this as "no releases"; never report false success.
            let repo = try await request("")
            if repo.status == 200 {
                guard let facts = try? JSONDecoder().decode(GitHubRepository.self, from: repo.data),
                      facts.full_name.lowercased() == repository.lowercased(), !facts.isPrivate else {
                    throw ReleaseCheckError.inaccessible
                }
                return (nil, nil)
            }
            if repo.status == 404 { throw ReleaseCheckError.inaccessible }
            throw statusError(repo.status)
        default: throw statusError(response.status)
        }
    }

    func validated(_ cache: ReleaseCache?) -> ReleaseCache? {
        guard let cache, cache.repository == repository,
              let version = ReleaseVersion(cache.release.version), version.prerelease.isEmpty,
              validReleaseURL(cache.release.url), cache.checkedAt <= Date().addingTimeInterval(300) else { return nil }
        return cache
    }

    private func validReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/tag/")
            && url.pathComponents.count >= 6
    }

    private func request(_ suffix: String, etag: String? = nil) async throws -> ReleaseHTTPReply {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        }), let url = URL(string: "https://api.github.com/repos/\(repository)\(suffix)") else { throw ReleaseCheckError.invalidRepository }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Dropy", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let response = try await transport.send(request)
        guard response.url.scheme == "https", response.url.host == "api.github.com",
              response.url.path == url.path else { throw ReleaseCheckError.invalidResponse }
        return response
    }

    private func statusError(_ status: Int) -> ReleaseCheckError {
        status == 403 || status == 429 ? .rateLimited : .server(status)
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: URL
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
    }
    private struct GitHubRepository: Decodable {
        let full_name: String
        let isPrivate: Bool
        enum CodingKeys: String, CodingKey { case full_name; case isPrivate = "private" }
    }
}
