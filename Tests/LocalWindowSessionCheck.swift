import Foundation

// Exercise the production session queue with controllable window IO. These checks
// never create a display, move a foreign window, or require capture permissions.
@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func entered() async {
        for _ in 0..<10_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        preconditionFailure("Operation never reached its IO gate")
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor private final class Windows {
    var current: Int?
    var restored: [Int] = []
    func restore() {
        if let current { restored.append(current) }
        current = nil
    }
}

@main struct WindowSessionChecks {
    @MainActor static func main() async throws {
        try await closeThenReopen()
        try await closeDuringAdoption()
        try await closeBeforeAdoptionStarts()
        try await failedAdoptionStillRestores()
        try await previewRestorationPrecedesAnotherSelection()
        try await systemReleasePrecedesFavoriteReopening()
        print("Window session ownership checks passed")
    }

    @MainActor static func closeThenReopen() async throws {
        let queue = WindowSessionQueue(), windows = Windows(), snapshot = Gate()
        let old = UUID(), new = UUID()
        try await queue.adopt(old) { windows.current = 1 }.value
        let closing = queue.finish(old) {
            await snapshot.wait()
            windows.restore()
        }
        await snapshot.entered()
        let reopening = queue.adopt(new) { windows.current = 2 }
        precondition(windows.current == 1)
        snapshot.resume()
        await closing.value
        try await reopening.value
        precondition(windows.restored == [1] && windows.current == 2)
        do {
            try await queue.perform(old) { windows.current = 99 }
            preconditionFailure("Old placement must be refused")
        } catch is CancellationError {}
        // A second old close is harmless and does not invalidate the new session.
        await queue.finish(old) { windows.restore() }.value
        try await queue.perform(new) { precondition(windows.current == 2) }
    }

    @MainActor static func closeDuringAdoption() async throws {
        let queue = WindowSessionQueue(), windows = Windows(), adoptionIO = Gate()
        let session = UUID()
        let adopting = queue.adopt(session) {
            await adoptionIO.wait()
            windows.current = 1
        }
        await adoptionIO.entered()
        let closing = queue.finish(session) { windows.restore() }
        adoptionIO.resume()
        try await adopting.value
        await closing.value
        precondition(windows.current == nil && windows.restored == [1])
    }

    @MainActor static func closeBeforeAdoptionStarts() async throws {
        let queue = WindowSessionQueue(), windows = Windows()
        let session = UUID()
        let adopting = queue.adopt(session) { windows.current = 1 }
        var closed = false
        let closing = queue.finish(session, ifUnowned: { closed = true }) { windows.restore() }
        do {
            try await adopting.value
            preconditionFailure("Cancelled adoption must not start")
        } catch is CancellationError {}
        await closing.value
        precondition(closed && windows.current == nil && windows.restored.isEmpty)
    }

    @MainActor static func failedAdoptionStillRestores() async throws {
        enum Failure: Error { case placement }
        let queue = WindowSessionQueue(), windows = Windows()
        let session = UUID()
        do {
            try await queue.adopt(session) {
                windows.current = 1
                throw Failure.placement
            }.value
            preconditionFailure("Expected placement failure")
        } catch Failure.placement {}
        await queue.finish(session) { windows.restore() }.value
        precondition(windows.current == nil && windows.restored == [1])
        // A failed operation does not poison the rest of the queue.
        try await queue.adopt(UUID()) { windows.current = 2 }.value
        precondition(windows.current == 2)
    }

    @MainActor static func previewRestorationPrecedesAnotherSelection() async throws {
        let queue = WindowSessionQueue(), windows = Windows(), restoreIO = Gate()
        let live = UUID(), next = UUID()
        try await queue.adopt(live) { windows.current = 1 }.value
        let fallback = queue.finish(live) {
            await restoreIO.wait()
            windows.restore()
        }
        await restoreIO.entered()
        let nextAdoption = queue.adopt(next) {
            precondition(windows.current == nil)
            windows.current = 2
        }
        restoreIO.resume()
        await fallback.value
        try await nextAdoption.value
        precondition(windows.restored == [1] && windows.current == 2)
    }
    @MainActor static func systemReleasePrecedesFavoriteReopening() async throws {
        let queue = WindowSessionQueue(), windows = Windows(), closingIO = Gate()
        let old = UUID(), next = UUID()
        try await queue.adopt(old) { windows.current = 1 }.value
        let close = queue.finish(old) {
            await closingIO.wait()
            windows.restore()
        }
        await closingIO.entered()
        // A display transition queues release after close, and a favorite selected
        // meanwhile must be adopted only after that system cleanup completes.
        let release = queue.enqueue { windows.restore() }
        let adoption = queue.adopt(next) {
            precondition(windows.current == nil)
            windows.current = 2
        }
        closingIO.resume()
        await close.value
        try await release.value
        try await adoption.value
        precondition(windows.restored == [1] && windows.current == 2)
        await queue.finish(old) { windows.restore() }.value
        precondition(windows.current == 2, "An obsolete favorite's dismissal cannot release the new one")
    }

}
