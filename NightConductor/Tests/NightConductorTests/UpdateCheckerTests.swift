import XCTest

@testable import NightConductor

final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionDetected() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.2", than: "1.0.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
    }

    func testSameOrOlderIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.1", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.9", than: "2.0.0"))
    }

    func testToleratesVPrefixAndMissingParts() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.2", than: "1.0.1"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.1", than: "v1.0.1"))
    }

    // Must compare numerically, not lexically: "1.0.10" > "1.0.9".
    func testNumericNotLexical() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.9", than: "1.0.10"))
    }
}
