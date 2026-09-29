import Foundation
import XCTest
import DropyCore

final class FrameTraceTests: XCTestCase {
    func testStagesSplitTheFrameAgeAndPutRetriesInDraw() {
        var trace = FrameTrace(display: 1_000, callback: 1_001)
        trace.compared = 1_001.5
        trace.forwarded = 1_001.6
        trace.delivered = 1_003
        trace.draws = [.init(committed: 1_004, presented: nil), .init(committed: 1_036, presented: 1_060)]
        trace.input = 900
        let stages = Dictionary(uniqueKeysWithValues: trace.stages)
        XCTAssertEqual(stages["capture"], 1)
        XCTAssertEqual(stages["compare"], 0.5)
        XCTAssertEqual(stages["main"]!, 1.4, accuracy: 0.001)
        XCTAssertEqual(stages["draw"], 33)
        XCTAssertEqual(stages["compose"], 24)
        XCTAssertEqual(trace.stages.map(\.milliseconds).reduce(0, +), trace.presented! - trace.display!, accuracy: 0.001)
        XCTAssertEqual(trace.misses, 1)
        XCTAssertTrue(trace.logLine.contains("age=60.0"))
        XCTAssertTrue(trace.logLine.contains("inputToPresent=160.0"))
    }

    func testUnpresentedFrameSaysSo() {
        var trace = FrameTrace(display: nil, callback: 10)
        trace.draws = [.init(committed: 11, presented: nil)]
        XCTAssertNil(trace.presented)
        XCTAssertTrue(trace.logLine.contains("outcome=notPresented"))
        XCTAssertFalse(trace.logLine.contains("age="))
    }
}
