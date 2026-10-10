import Foundation
import ScreenCaptureKit

/// Shadow only catalog IO while compiling the unmodified top-edge probe.
enum SCShareableContent {
    static func excludingDesktopWindows(_ excluded: Bool, onScreenWindowsOnly: Bool) async throws
        -> ScreenCaptureKit.SCShareableContent {
        throw NSError(domain: "probe-startup-fixture", code: 1)
    }
}
