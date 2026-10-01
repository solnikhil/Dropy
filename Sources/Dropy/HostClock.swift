import Darwin
import Foundation
import QuartzCore

/// The one clock Dropy measures elapsed time on. ScreenCaptureKit's `displayTime` and
/// `mach_absolute_time` share the mach clock, so frame ages, capture latencies and the
/// hidden-source frame rate are all read from here; Core Animation's media time is
/// checked against it at runtime rather than assumed to match.
///
/// It lives in its own file so that a check can compile the clock without the capture
/// stack around it: Tests/LocalFrameStampCheck.swift asserts that what this returns and
/// what a frame stamp carries are the same epoch, which nothing else would notice.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func milliseconds(fromMach value: UInt64) -> Double {
        Double(value) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    static func nowMilliseconds() -> Double { milliseconds(fromMach: mach_absolute_time()) }

    /// The same monotonic clock in seconds, for rates measured over seconds.
    static func nowSeconds() -> TimeInterval { nowMilliseconds() / 1_000 }

    /// Core Animation media time minus converted mach time, taking the tightest of
    /// several paired reads.
    static func coreAnimationOffsetMilliseconds() -> Double {
        (0..<5).map { _ -> Double in
            let before = nowMilliseconds()
            let media = CACurrentMediaTime() * 1_000
            let after = nowMilliseconds()
            return media - (before + after) / 2
        }.min { abs($0) < abs($1) } ?? .infinity
    }
}
