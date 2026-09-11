import XCTest
@testable import KildeCore

final class ParseDurationTests: XCTestCase {
    func testParseDurationAcceptsSecondsMinutesHoursAndFractions() {
        XCTAssertEqual(parseDuration("30"), 30)
        XCTAssertEqual(parseDuration("30s"), 30)
        XCTAssertEqual(parseDuration("5m"), 300)
        XCTAssertEqual(parseDuration("1h"), 3_600)
        XCTAssertEqual(parseDuration("1.5m"), 90)
    }

    func testParseDurationRejectsMalformedValues() {
        XCTAssertNil(parseDuration("10xyz"))
        XCTAssertNil(parseDuration("1mfoo"))
        XCTAssertNil(parseDuration(""))
        XCTAssertNil(parseDuration("s"))
    }
}
