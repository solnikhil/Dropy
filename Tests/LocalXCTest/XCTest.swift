// A minimal stand-in for XCTest so Tests/DropyCoreTests also run through
// Scripts/test-local.sh on toolchains without XCTest (e.g. Command Line Tools
// without Xcode). It implements only the assertions the suite uses; CI runs the
// same files with the real XCTest through `swift test`.
// Scripts/test-local.sh generates the runner that calls each `test…` method.
@_exported import Foundation

nonisolated(unsafe) public var xctestFailures: [String] = []

open class XCTestCase {
    public required init() {}
}

private func record(_ message: String, _ file: StaticString, _ line: UInt) {
    xctestFailures.append("\(file):\(line): \(message)")
    FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message)\n".utf8))
}

public func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try lhs(), try rhs())
        if a != b { record("XCTAssertEqual \(a) != \(b) \(message())", file, line) }
    } catch { record("threw \(error)", file, line) }
}

public func XCTAssertEqual<T: FloatingPoint>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                             accuracy: T, _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try lhs(), try rhs())
        if abs(a - b) > accuracy { record("XCTAssertEqual \(a) != \(b) ± \(accuracy) \(message())", file, line) }
    } catch { record("threw \(error)", file, line) }
}

public func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                            _ message: @autoclosure () -> String = "",
                                            file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (a, b) = (try lhs(), try rhs())
        if a == b { record("XCTAssertNotEqual \(a) == \(b) \(message())", file, line) }
    } catch { record("threw \(error)", file, line) }
}

public func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { record("XCTAssertTrue \(message())", file, line) } }
    catch { record("threw \(error)", file, line) }
}

public func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { record("XCTAssertFalse \(message())", file, line) } }
    catch { record("threw \(error)", file, line) }
}

public func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    do { if let found = try value() { record("XCTAssertNil got \(found) \(message())", file, line) } }
    catch { record("threw \(error)", file, line) }
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    record("XCTFail \(message)", file, line)
}

/// Runs one test method, reporting a thrown error as a failure.
public func xctestRun(_ name: String, _ body: () throws -> Void) {
    let before = xctestFailures.count
    do { try body() } catch { xctestFailures.append("\(name): threw \(error)") }
    print(xctestFailures.count == before ? "pass \(name)" : "FAIL \(name)")
}

public struct XCTUnwrapError: Error, CustomStringConvertible {
    public var description: String
}

public func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let unwrapped = try value() else {
        record("XCTUnwrap found nil \(message())", file, line)
        throw XCTUnwrapError(description: "XCTUnwrap found nil at \(file):\(line)")
    }
    return unwrapped
}

public func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() == nil { record("XCTAssertNotNil \(message())", file, line) } }
    catch { record("threw \(error)", file, line) }
}
