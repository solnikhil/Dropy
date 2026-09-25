import Foundation

/// Identifies one window within one running process. These values are session-local:
/// a saved app preference must never be treated as a saved window selection.
public struct WindowIdentity: Equatable, Sendable {
    public let processID: Int32
    public let processLaunchDate: Date?
    public let windowID: UInt32
    public let bundleIdentifier: String?

    public init(processID: Int32, processLaunchDate: Date?, windowID: UInt32,
                bundleIdentifier: String?) {
        self.processID = processID
        self.processLaunchDate = processLaunchDate
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
    }

    /// An ID reused by another process, or another app in the same process,
    /// must not resolve to the old selection. Titles are deliberately excluded.
    public func matches(_ candidate: WindowIdentity) -> Bool {
        self == candidate
    }
}
