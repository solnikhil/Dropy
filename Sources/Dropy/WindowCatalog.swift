import AppKit
import DropyCore
import ScreenCaptureKit

struct CapturableWindow {
    let window: SCWindow
    let applicationName: String
    let processID: pid_t
    let processLaunchDate: Date
    let bundleIdentifier: String?
    let displayName: String

    var identity: WindowIdentity {
        WindowIdentity(processID: processID,
                       processLaunchDate: processLaunchDate,
                       windowID: window.windowID,
                       bundleIdentifier: bundleIdentifier)
    }
}

enum WindowResolution {
    case available(SCWindow)
    /// The exact process is still running, but the window is gone.
    case windowClosed
    /// The exact process exited. A relaunched app is a different process.
    case processExited
}

enum WindowCatalog {
    struct PresentationFacts {
        let size: CGSize
        let visibility: SourceVisibility
    }

    /// Fresh metadata for this exact owner/window. Reads geometry only: no capture,
    /// focus changes, permissions prompt or source-window mutation.
    static func presentationFacts(for window: SCWindow) -> PresentationFacts {
        let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowID) as? [[String: Any]])?
            .first { row in
                (row[kCGWindowNumber as String] as? UInt32) == window.windowID &&
                (row[kCGWindowOwnerPID as String] as? Int32) == window.owningApplication?.processID
            }
        let bounds = (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        let validBounds = bounds.flatMap { rect -> CGSize? in
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
            return rect.size
        }
        let hidden = window.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID) }?.isHidden ?? false
        return PresentationFacts(size: validBounds ?? window.frame.size,
            visibility: SourceVisibility.resolve(appHidden: hidden,
                serverOnScreen: info?[kCGWindowIsOnscreen as String] as? Bool, captureOnScreen: window.isOnScreen))
    }

    /// Resolve against a fresh system snapshot, including untitled and small
    /// windows that are omitted from the picker. Never fall back to a title or
    /// bundle-ID match: either can select the wrong document after relaunch.
    static func resolve(_ identity: WindowIdentity) async throws -> WindowResolution {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        let match = content.windows.first { window in
            guard let owner = window.owningApplication,
                  let launchDate = NSRunningApplication(processIdentifier: owner.processID)?.launchDate
            else { return false }
            return identity.matches(WindowIdentity(processID: owner.processID,
                                                   processLaunchDate: launchDate,
                                                   windowID: window.windowID,
                                                   bundleIdentifier: owner.bundleIdentifier))
        }
        if let match { return .available(match) }
        return isRunning(identity) ? .windowClosed : .processExited
    }

    /// Checks the process by PID and launch date, so a reused PID is not mistaken
    /// for the original process.
    static func isRunning(_ identity: WindowIdentity) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: identity.processID),
              !application.isTerminated else { return false }
        return application.launchDate == identity.processLaunchDate &&
            application.bundleIdentifier == identity.bundleIdentifier
    }

    static func availableWindows() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        var eligible: [UInt32: (window: SCWindow, launchDate: Date)] = [:]
        var summaries: [WindowSummary] = []
        for window in content.windows {
            guard let owner = window.owningApplication,
                  owner.processID != getpid(),
                  let runningApplication = NSRunningApplication(processIdentifier: owner.processID),
                  runningApplication.activationPolicy == .regular,
                  let launchDate = runningApplication.launchDate else { continue }
            // A closed window the app kept around: choosing it (or remembering it)
            // led to "could not move this window" and a blank, view-only preview.
            // A hidden app's windows are left alone, since hiding takes them off every desktop.
            if !window.isOnScreen, !runningApplication.isHidden, Spaces.isOrderedOut(window.windowID) { continue }
            eligible[window.windowID] = (window, launchDate)
            summaries.append(WindowSummary(
                processID: owner.processID,
                windowID: window.windowID,
                applicationName: owner.applicationName,
                title: (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                layer: window.windowLayer,
                size: window.frame.size,
                isOnScreen: window.isOnScreen))
        }
        return WindowPicker.entries(from: summaries).compactMap { entry in
            guard let (window, launchDate) = eligible[entry.windowID],
                  let owner = window.owningApplication else { return nil }
            return CapturableWindow(window: window,
                                    applicationName: owner.applicationName,
                                    processID: owner.processID,
                                    processLaunchDate: launchDate,
                                    bundleIdentifier: owner.bundleIdentifier,
                                    displayName: entry.label)
        }
    }
}
