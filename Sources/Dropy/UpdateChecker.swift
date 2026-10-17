import AppKit
import Combine
import Foundation
import DropyCore

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let notes: String
}

enum ApplicationUpdateEvent {
    case checking, current, available(UpdateRelease), failed(String), settingsChanged, finished
}

/// Sparkle owns downloading, signature verification, installation and its persisted
/// scheduling preferences. This boundary keeps app presentation and tests independent.
@MainActor
protocol ApplicationUpdateEngine: AnyObject {
    var onEvent: ((ApplicationUpdateEvent) -> Void)? { get set }
    var canCheck: Bool { get }
    var automaticallyChecks: Bool { get set }
    var automaticallyDownloads: Bool { get set }
    var allowsAutomaticDownloads: Bool { get }
    var lastChecked: Date? { get }
    func start() throws
    func check()
    func checkInBackground()
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, current, available(UpdateRelease), unavailable(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticDownloads = false
    let installedVersion: String
    let channel: UpdateChannelConfiguration
    var onChange: (() -> Void)?
    private let engine: any ApplicationUpdateEngine
    private var started = false

    init(engine: any ApplicationUpdateEngine,
         channel: UpdateChannelConfiguration = .init(
            feed: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "",
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""),
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.engine = engine
        self.channel = channel
        self.installedVersion = installedVersion
        engine.onEvent = { [weak self] event in self?.receive(event) }
    }

    var availableRelease: UpdateRelease? {
        if case .available(let release) = state { return release }
        return nil
    }
    var isChecking: Bool { state == .checking }
    var isConfigured: Bool { channel.isValid }

    func start() {
        guard !started else { return }
        guard channel.isValid else {
            state = .unavailable("Updates aren’t configured for this build.")
            onChange?()
            return
        }
        do {
            try engine.start()
            started = true
            refreshSettings()
            // Sparkle schedules future checks. A startup check runs only if the
            // person has automatic checks enabled; their choice is never reset.
            if engine.automaticallyChecks { engine.checkInBackground() }
        } catch {
            state = .unavailable(error.localizedDescription)
            onChange?()
        }
    }

    func check() {
        if !started { start() }
        guard started, engine.canCheck else { return }
        state = .checking
        engine.check()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard started else { return }
        engine.automaticallyChecks = enabled
        refreshSettings()
    }
    func setAutomaticDownloads(_ enabled: Bool) {
        guard started, engine.allowsAutomaticDownloads else { return }
        engine.automaticallyDownloads = enabled
        refreshSettings()
    }

    /// Show Sparkle's verified download/install flow, including an update already
    /// downloaded in the background. Never open an arbitrary release-page URL.
    func installUpdate() { check() }
    func cancel() { engine.onEvent = nil }

    private func receive(_ event: ApplicationUpdateEvent) {
        switch event {
        case .checking: state = .checking
        case .current: state = .current
        case .available(let release): state = .available(release)
        case .failed(let reason): state = .unavailable(reason)
        case .finished:
            if state == .checking { state = .idle }
        case .settingsChanged: break
        }
        refreshSettings()
    }
    private func refreshSettings() {
        canCheck = started && engine.canCheck
        automaticallyChecks = engine.automaticallyChecks
        automaticallyDownloads = engine.automaticallyDownloads
        allowsAutomaticDownloads = started && engine.allowsAutomaticDownloads
        lastChecked = engine.lastChecked
        onChange?()
    }
}
