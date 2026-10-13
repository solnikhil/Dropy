import Foundation
import Combine
import AppKit
import DropyCore

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, current, noReleases, available(PublishedRelease), unavailable(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false
    let installedVersion: String
    var repository: String { client.repository }
    var onChange: (() -> Void)?
    private let client: ReleaseUpdateClient
    private let defaults: UserDefaults
    private var cache: ReleaseCache?
    private var task: Task<Void, Never>?
    private static let cacheKey = "org.dropy.updates.cache.v1"

    init(client: ReleaseUpdateClient = ReleaseUpdateClient(repository:
             Bundle.main.object(forInfoDictionaryKey: "DropyUpdateRepository") as? String ?? ReleaseUpdateClient.defaultRepository),
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         defaults: UserDefaults = .standard) {
        self.client = client; self.installedVersion = installedVersion; self.defaults = defaults
        if let data = defaults.data(forKey: Self.cacheKey), let saved = try? JSONDecoder().decode(ReleaseCache.self, from: data) {
            cache = client.validated(saved)
            lastChecked = cache?.checkedAt
        }
    }

    var availableRelease: PublishedRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// A real request on every normal startup. Concurrent manual requests coalesce.
    func check() {
        guard task == nil, !isChecking else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.checkNow()
            self.task = nil
        }
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true; state = .checking
        defer { isChecking = false; onChange?() }
        guard let current = ReleaseVersion(installedVersion) else {
            state = .unavailable("This build has no valid release version."); return
        }
        do {
            let result = try await client.fetch(cache: cache)
            try Task.checkCancellation()
            lastChecked = Date()
            if let release = result.release, let version = ReleaseVersion(release.version) {
                cache = ReleaseCache(repository: client.repository, release: release, etag: result.etag, checkedAt: lastChecked!)
                if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
                state = version > current ? .available(release) : .current
            } else {
                cache = nil; defaults.removeObject(forKey: Self.cacheKey); state = .noReleases
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    func openRelease() {
        guard let release = availableRelease else { return }
        NSWorkspace.shared.open(release.url)
    }

    func cancel() { task?.cancel() }
}
