import Foundation
import XCTest
import DropyCore

final class HiddenSourceWatchTests: XCTestCase {
    func testHidingArmsTheMonitorOnceAndShowingDisarmsItOnce() {
        var watch = HiddenSourceWatch()
        XCTAssertFalse(watch.hidden)
        XCTAssertFalse(watch.runsLoop, "nothing polls until a source is hidden")
        XCTAssertEqual(watch.update(concealment: .visible, capturing: true), nil,
                       "a visible source was never hidden, so there is nothing to tell")
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), true)
        XCTAssertTrue(watch.hidden)
        XCTAssertTrue(watch.runsLoop)
        // Re-reading the same concealment must not re-arm: that would move the baseline
        // onto the already-throttled rate and the drop could never be seen again.
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), nil)
        XCTAssertEqual(watch.update(concealment: .visible, capturing: true), false)
        XCTAssertFalse(watch.hidden)
        XCTAssertFalse(watch.runsLoop)
        XCTAssertEqual(watch.update(concealment: .visible, capturing: true), nil)
    }

    func testAWindowThatIsNotBeingDrawnNeverArmsTheMonitor() {
        // The mutation this catches: `hidden = concealment != .visible`. A minimized
        // window, a window whose app was hidden and a window the window server does not
        // list all read `.notRendering` and deliver no frames for reasons that have
        // nothing to do with throttling; arming on them would report "slowed" for a
        // source nobody is drawing.
        var watch = HiddenSourceWatch()
        XCTAssertEqual(watch.update(concealment: .notRendering, capturing: true), nil)
        XCTAssertFalse(watch.hidden)
        XCTAssertFalse(watch.runsLoop)
        // And a source that stops being drawn while hidden disarms it.
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), true)
        XCTAssertEqual(watch.update(concealment: .notRendering, capturing: true), false)
        XCTAssertFalse(watch.hidden)
    }

    func testNoStreamAndNoReadingEndTheWatch() {
        var watch = HiddenSourceWatch()
        // A paused or stopped preview: frames are not arriving, so no rate means anything.
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: false), nil)
        XCTAssertFalse(watch.hidden)
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), true)
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: false), false,
                       "capture stopping ends the watch as surely as a restore does")
        XCTAssertFalse(watch.hidden)
        // No source to read at all (no selection, or the read failed).
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), true)
        XCTAssertEqual(watch.update(concealment: nil, capturing: true), false)
        XCTAssertFalse(watch.hidden)
    }

    func testResetTellsTheMonitorExactlyWhenItWasArmed() {
        var watch = HiddenSourceWatch()
        XCTAssertEqual(watch.reset(), nil, "a watch that armed nothing has nothing to undo")
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), true)
        XCTAssertEqual(watch.reset(), false)
        XCTAssertFalse(watch.hidden)
        XCTAssertFalse(watch.runsLoop)
        XCTAssertEqual(watch.reset(), nil, "and a second reset is not a second event")
        XCTAssertEqual(watch, HiddenSourceWatch(), "a reset watch is a new watch")
    }

    func testHidingAgainAfterAResetIsAFreshEvent() {
        // A new stream on the same source: the monitor must be armed again, because
        // `reset` disarmed it and its baseline is measured afresh from then on.
        var watch = HiddenSourceWatch()
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), true)
        XCTAssertEqual(watch.reset(), false)
        XCTAssertEqual(watch.update(concealment: .hidden, capturing: true), true)
        XCTAssertTrue(watch.runsLoop)
    }
}
