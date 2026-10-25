import Foundation

private final class LifetimeProbe: Sendable {}

private final class ConcurrentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@MainActor private final class Counter {
    var value = 0
}

@main struct ResourceLifetimeChecks {
    @MainActor static func main() async {
        let name = Notification.Name("org.dropy.tests.lifecycle")
        let first = NotificationCenter(), second = NotificationCenter()
        let calls = Counter()
        var probe: LifetimeProbe? = LifetimeProbe()
        weak var callbackContext = probe
        var observation: NotificationObservation? = NotificationObservation(center: first, forName: name) { [probe = probe!] _ in
            withExtendedLifetime(probe) {}
            MainActor.assumeIsolated { calls.value += 1 }
        }
        probe = nil
        precondition(callbackContext != nil)
        second.post(name: name, object: nil)
        precondition(calls.value == 0)
        first.post(name: name, object: nil)
        precondition(calls.value == 1)
        observation?.cancel()
        observation?.cancel()
        first.post(name: name, object: nil)
        precondition(calls.value == 1, "Explicit cancellation must remove the registered callback")
        observation = nil
        precondition(callbackContext == nil, "The center must release a cancelled callback's context")

        for _ in 0..<1_000 {
            var context: LifetimeProbe? = LifetimeProbe()
            weak var released = context
            var token: NotificationObservation? = NotificationObservation(center: first, forName: name) { [context = context!] _ in
                withExtendedLifetime(context) {}
                MainActor.assumeIsolated { calls.value += 1 }
            }
            context = nil
            withExtendedLifetime(token) {}
            token = nil
            precondition(released == nil, "Dropping an observation must unregister it without explicit stop")
        }
        first.post(name: name, object: nil)
        precondition(calls.value == 1, "Repeated registration/destruction must not accumulate callbacks")

        let delivery = OperationQueue()
        delivery.isSuspended = true
        let queuedCalls = ConcurrentCounter()
        let queued = NotificationObservation(center: first, forName: name, queue: delivery) { _ in queuedCalls.increment() }
        let posting = Task.detached { first.post(name: name, object: nil) }
        for _ in 0..<100 where delivery.operationCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(delivery.operationCount > 0)
        queued.cancel()
        delivery.isSuspended = false
        await posting.value
        precondition(queuedCalls.value == 0, "Cancellation must also suppress deliveries that were already queued")

        let cleanups = Counter()
        var context: LifetimeProbe? = LifetimeProbe()
        weak var retainedUntilCleanup = context
        var cleanup: MainThreadCleanup? = MainThreadCleanup { [context = context!] in
            precondition(Thread.isMainThread)
            precondition(retainedUntilCleanup != nil)
            withExtendedLifetime(context) {}
            cleanups.value += 1
        }
        context = nil
        // Release the last owner from a worker. The queued cleanup must retain its
        // callback context, and run exactly once on the main thread.
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached { [resource = cleanup!] in
            for await _ in release { break }
            precondition(!Thread.isMainThread)
            withExtendedLifetime(resource) {}
        }
        cleanup = nil
        precondition(retainedUntilCleanup != nil)
        continuation.yield(())
        continuation.finish()
        await worker.value
        for _ in 0..<100 where cleanups.value == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(cleanups.value == 1 && retainedUntilCleanup == nil)

        let ticks = Counter()
        var timerContext: LifetimeProbe? = LifetimeProbe()
        weak var timerReleased = timerContext
        var timer: RepeatingTimer? = RepeatingTimer(interval: 0.01) { [timerContext = timerContext!] in
            withExtendedLifetime(timerContext) {}
            ticks.value += 1
        }
        timerContext = nil
        for _ in 0..<100 where ticks.value == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(ticks.value > 0, "The owned timer must still deliver callbacks while alive")
        withExtendedLifetime(timer) {}
        timer = nil
        precondition(timerReleased == nil, "Destruction must invalidate the timer retained by the run loop")
        let stoppedAt = ticks.value
        try? await Task.sleep(for: .milliseconds(50))
        precondition(ticks.value == stoppedAt, "A destroyed timer must not leave a repeating callback running")
        print("Resource lifetime checks passed (observer release, repeated cancellation, main-thread cleanup)")
    }
}
