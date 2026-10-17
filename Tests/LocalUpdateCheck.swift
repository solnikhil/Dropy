import Foundation
import DropyCore

@MainActor final class UpdateFixtureEngine: ApplicationUpdateEngine {
    var onEvent: ((ApplicationUpdateEvent) -> Void)?
    var canCheck = true
    var automaticallyChecks = true
    var automaticallyDownloads = true
    var allowsAutomaticDownloads: Bool { automaticallyChecks }
    var lastChecked: Date?
    var starts = 0
    var checks = 0
    var backgrounds = 0
    var startError: Error?
    func start() throws { starts += 1; if let startError { throw startError } }
    func check() { checks += 1 }
    func checkInBackground() { backgrounds += 1 }
}

@main struct UpdateChecks {
    @MainActor static func main() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let channel = UpdateChannelConfiguration(feed: "https://example.com/appcast.xml", publicKey: key)
        precondition(channel.isValid)
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:secret@example.com/feed", "https://example.com/feed?token=secret", "https://example.com/feed#x"] {
            precondition(!UpdateChannelConfiguration(feed: feed, publicKey: key).isValid)
        }
        precondition(!UpdateChannelConfiguration(feed: channel.feed, publicKey: "not-a-key").isValid)
        let engine = UpdateFixtureEngine()
        let checker = UpdateChecker(engine: engine, channel: channel, installedVersion: "0.1.1")
        checker.start(); checker.start()
        precondition(engine.starts == 1 && engine.backgrounds == 1 && checker.canCheck)
        checker.check()
        precondition(engine.checks == 1 && checker.isChecking)
        engine.onEvent?(.finished)
        precondition(checker.state == .idle, "Closing a manual check must not leave a stuck spinner")
        checker.check()
        engine.lastChecked = Date(timeIntervalSince1970: 10)
        engine.onEvent?(.current)
        precondition(checker.state == .current && checker.lastChecked == engine.lastChecked)
        engine.onEvent?(.available(UpdateRelease(version: "0.1.2", notes: "Changes")))
        precondition(checker.availableRelease?.version == "0.1.2")
        checker.installUpdate()
        precondition(engine.checks == 3, "Install must use the verified updater rather than opening a browser")
        checker.setAutomaticDownloads(false)
        precondition(!engine.automaticallyDownloads && !checker.automaticallyDownloads)
        checker.setAutomaticChecks(false)
        precondition(!engine.automaticallyChecks && !checker.allowsAutomaticDownloads)
        checker.setAutomaticDownloads(true)
        precondition(!engine.automaticallyDownloads, "Automatic downloads cannot be enabled when Sparkle refuses them")
        engine.onEvent?(.failed("Signature verification failed"))
        precondition(checker.state == .unavailable("Signature verification failed"))
        let last = checker.lastChecked
        engine.onEvent?(.finished)
        precondition(checker.lastChecked == last && checker.state != .current)
        engine.canCheck = false
        let checks = engine.checks
        checker.check()
        precondition(engine.checks == checks)
        checker.cancel()
        precondition(engine.onEvent == nil)

        let disabled = UpdateFixtureEngine()
        disabled.automaticallyChecks = false
        let disabledChecker = UpdateChecker(engine: disabled, channel: channel)
        disabledChecker.start()
        precondition(disabled.backgrounds == 0 && !disabled.automaticallyChecks,
                     "Startup must preserve a user's disabled automatic checks")
        disabledChecker.check()
        precondition(disabled.checks == 1)
        let invalid = UpdateFixtureEngine()
        let invalidChecker = UpdateChecker(engine: invalid, channel: .init(feed: "", publicKey: ""))
        invalidChecker.start(); invalidChecker.check()
        precondition(invalid.starts == 0 && invalid.checks == 0 && !invalidChecker.canCheck)
        if case .unavailable = invalidChecker.state {} else { preconditionFailure("Unconfigured updates must be explicit") }
        let broken = UpdateFixtureEngine()
        broken.startError = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad framework configuration"])
        let brokenChecker = UpdateChecker(engine: broken, channel: channel)
        brokenChecker.start()
        precondition(brokenChecker.state == .unavailable("Bad framework configuration") && !brokenChecker.canCheck)
        print("Automatic update checks passed (configuration, scheduling, user choices, install routing, errors)")
    }
}
