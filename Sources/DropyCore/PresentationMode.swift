import Foundation

/// Which presentation path the preview uses to get a drawn frame onto the screen.
///
/// The 2026-09-30 idle latency trace (docs/BENCHMARK.md) measured input-to-present at
/// 125–136 ms p50, of which about 60 ms is the first two drawables after a quiet period
/// being reported never shown. The candidate fixes are hypotheses, so each one is a mode
/// here and `default` reproduces exactly the behaviour that was measured. A run can then
/// be compared against that baseline instead of against an unrecorded earlier build.
///
/// Selected by the `DROPY_PRESENT_MODE` environment variable; unset means `default`.
public enum PresentationMode: String, CaseIterable, Sendable {
    /// Draw on demand, and when the compositor reports a drawable was never shown,
    /// draw again. The behaviour the trace measured.
    case retry
    /// As `retry`, and additionally run the view's display link for a short bounded
    /// window after input, after a frame that follows a quiet gap, and after a reported
    /// drawable miss, so the layer is already presenting when the response frame lands.
    case warm
    /// As `retry`, and additionally present through Core Animation
    /// (`presentsWithTransaction`), so the layer's contents change inside the
    /// transaction that commits them rather than through a bare surface swap.
    case transaction
    /// Both `warm` and `transaction`.
    case warmTransaction = "warm-transaction"

    /// The environment variable that selects a mode.
    public static let environmentKey = "DROPY_PRESENT_MODE"

    /// The measured baseline. Any new path is opt-in until it has been measured.
    public static let measuredDefault = PresentationMode.retry

    /// Run the display link briefly so the presentation path stays warm.
    public var keepsDisplayLinkWarm: Bool {
        switch self {
        case .warm, .warmTransaction: true
        case .retry, .transaction: false
        }
    }

    /// Hand presentation to Core Animation instead of committing it with the drawable.
    public var presentsWithTransaction: Bool {
        switch self {
        case .transaction, .warmTransaction: true
        case .retry, .warm: false
        }
    }

    /// Every mode keeps the redraw-after-miss fallback: a drawable can also be
    /// unavailable while the panel is opening or covered, which no mode here changes.
    public var retriesAfterDrawableMiss: Bool { true }

    /// The mode a run will use, and the request that was not understood, if any.
    public struct Resolution: Equatable, Sendable {
        public var mode: PresentationMode
        /// The requested value when it was not a known mode; nil when it was known or absent.
        public var unrecognized: String?

        public init(mode: PresentationMode, unrecognized: String? = nil) {
            self.mode = mode
            self.unrecognized = unrecognized
        }
    }

    /// Reads the mode from an environment. An unknown or empty value keeps the measured
    /// default and is reported, so a typo in a benchmark run cannot silently look like
    /// the experiment it meant to select.
    public static func resolve(_ environment: [String: String]) -> Resolution {
        guard let raw = environment[environmentKey] else { return Resolution(mode: measuredDefault) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Resolution(mode: measuredDefault, unrecognized: raw) }
        guard let mode = PresentationMode(rawValue: trimmed.lowercased()) else {
            return Resolution(mode: measuredDefault, unrecognized: trimmed)
        }
        return Resolution(mode: mode)
    }
}
