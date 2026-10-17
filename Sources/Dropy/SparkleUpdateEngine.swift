import AppKit
import Combine
import Foundation
import Sparkle

/// The standard Sparkle UI handles authenticated archives, progress, installation,
/// and relaunch. Application termination still saves Studio and restores windows.
@MainActor
final class SparkleUpdateEngine: NSObject, ApplicationUpdateEngine, SPUUpdaterDelegate {
    var onEvent: ((ApplicationUpdateEvent) -> Void)?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false,
        updaterDelegate: self, userDriverDelegate: nil)
    private var observations: Set<AnyCancellable> = []
    private var started = false
    var canCheck: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
    var allowsAutomaticDownloads: Bool { controller.updater.allowsAutomaticUpdates }
    var lastChecked: Date? { controller.updater.lastUpdateCheckDate }

    func start() throws {
        guard !started else { return }
        try controller.updater.start()
        started = true
        for publisher in [controller.updater.publisher(for: \.canCheckForUpdates),
                          controller.updater.publisher(for: \.automaticallyChecksForUpdates),
                          controller.updater.publisher(for: \.automaticallyDownloadsUpdates)] {
            publisher.sink { [weak self] _ in self?.onEvent?(.settingsChanged) }.store(in: &observations)
        }
    }
    func check() { controller.checkForUpdates(nil) }
    func checkInBackground() { controller.updater.checkForUpdatesInBackground() }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onEvent?(.available(UpdateRelease(version: item.displayVersionString, notes: item.itemDescription ?? "")))
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { onEvent?(.current) }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain, error.code == SUError.noUpdateError.rawValue {
            onEvent?(.current)
        } else if error.domain == SUSparkleErrorDomain, error.code == SUError.installationCanceledError.rawValue {
            onEvent?(.finished)
        } else {
            onEvent?(.failed(error.localizedDescription))
        }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        onEvent?(.finished)
    }
}
