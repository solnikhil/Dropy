/// Apps that stop or refuse playback the moment anything on the Mac captures the
/// screen, even a single other window for a fraction of a second: macOS reports
/// every ScreenCaptureKit stream and screenshot system-wide ("screen capture added"),
/// and these players treat that as recording. While one is running, Dropy captures
/// nothing: a docked window moves without its snapshot cover, and the preview and
/// Live mode (both streams) are not offered.
public enum CaptureGuard {
    /// Bundle identifiers, each observed stopping playback when Dropy captured.
    /// Prime Video: 2026-10-11, on opening and closing a docked window (two
    /// screenshots of 20–50 ms each).
    public static let sensitiveBundleIdentifiers: Set<String> = [
        "com.amazon.aiv.AIVApp",
    ]

    /// The first running app (bundle identifier, name) that capture would interrupt.
    public static func blocker(in running: [(bundleIdentifier: String?, name: String?)]) -> String? {
        running.first { $0.bundleIdentifier.map(sensitiveBundleIdentifiers.contains) ?? false }
            .map { $0.name ?? "A video app" }
    }
}
