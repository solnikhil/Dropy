import Foundation

/// Reserves window operations synchronously, before their callers can suspend.
/// A session owns only the adoption admitted for it; closing that session cannot
/// act on a later selection, even when snapshotting or adoption is still awaiting IO.
@MainActor
final class WindowSessionQueue {
    private var tail: Task<Void, Never>?
    private var active: UUID?
    private var owner: UUID?

    func enqueue<T: Sendable>(_ body: @escaping @MainActor @Sendable () async throws -> T) -> Task<T, Error> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return task
    }

    func adopt(_ session: UUID, _ body: @escaping @MainActor @Sendable () async throws -> Void) -> Task<Void, Error> {
        active = session
        return enqueue { [self] in
            guard active == session else { throw CancellationError() }
            owner = session
            try await body()
        }
    }

    func perform<T: Sendable>(_ session: UUID,
                             _ body: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await enqueue { [self] in
            guard active == session, owner == session else { throw CancellationError() }
            return try await body()
        }.value
    }

    /// Invalidates further work immediately and queues cleanup even if adoption has
    /// not produced a window yet. An adoption already in progress settles first.
    func finish(_ session: UUID, ifUnowned: @escaping @MainActor @Sendable () -> Void = {},
                _ body: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        if active == session { active = nil }
        let cleanup = enqueue { [self] in
            guard owner == session else { ifUnowned(); return }
            await body()
            owner = nil
        }
        return Task { _ = try? await cleanup.value }
    }
}
