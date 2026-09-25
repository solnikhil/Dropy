import AppKit
import DropyCore
import ScreenCaptureKit

struct CapturableWindow {
    let window: SCWindow
    let applicationName: String
    let processID: pid_t
    let processLaunchDate: Date?
    let bundleIdentifier: String?
    let title: String

    var identity: WindowIdentity {
        WindowIdentity(processID: processID,
                       processLaunchDate: processLaunchDate,
                       windowID: window.windowID,
                       bundleIdentifier: bundleIdentifier)
    }

    var displayName: String {
        title.isEmpty ? applicationName : "\(applicationName) — \(title)"
    }
}

enum WindowCatalog {
    /// Resolve against a fresh system snapshot, including untitled and small
    /// windows that are omitted from the picker. Never fall back to a title or
    /// bundle-ID match: either can select the wrong document after relaunch.
    static func resolve(_ identity: WindowIdentity) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        return content.windows.first { window in
            guard let owner = window.owningApplication else { return false }
            return identity.matches(WindowIdentity(processID: owner.processID,
                                                   processLaunchDate: NSRunningApplication(processIdentifier: owner.processID)?.launchDate,
                                                   windowID: window.windowID,
                                                   bundleIdentifier: owner.bundleIdentifier))
        }
    }

    static func availableWindows() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        let candidates: [CapturableWindow] = content.windows.compactMap { window in
            guard let owner = window.owningApplication,
                  owner.processID != getpid(),
                  NSRunningApplication(processIdentifier: owner.processID)?.activationPolicy == .regular,
                  window.frame.width >= 160,
                  window.frame.height >= 100 else { return nil }
            let appName = owner.applicationName
            guard !appName.isEmpty else { return nil }
            return CapturableWindow(window: window,
                                    applicationName: appName,
                                    processID: owner.processID,
                                    processLaunchDate: NSRunningApplication(processIdentifier: owner.processID)?.launchDate,
                                    bundleIdentifier: owner.bundleIdentifier,
                                    title: (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let byApp = Dictionary(grouping: candidates) { $0.window.owningApplication?.processID ?? 0 }
        let useful = byApp.values.flatMap { windows -> [CapturableWindow] in
            let titled = windows.filter { !$0.title.isEmpty }
            if !titled.isEmpty { return titled }
            return windows.max(by: { $0.window.frame.width * $0.window.frame.height <
                                     $1.window.frame.width * $1.window.frame.height }).map { [$0] } ?? []
        }
        return useful.sorted { lhs, rhs in
            if lhs.applicationName == rhs.applicationName {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.applicationName.localizedStandardCompare(rhs.applicationName) == .orderedAscending
        }
    }
}
