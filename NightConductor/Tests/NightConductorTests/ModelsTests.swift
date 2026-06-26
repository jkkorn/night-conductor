import XCTest

@testable import NightConductor

final class ModelsTests: XCTestCase {
    // ISO.parse must accept every format the three scanners actually see: the
    // usage API's fractional UTC, Conductor's millisecond UTC, a timezone
    // offset, AND a timezone-less SQLite `datetime('now')` value (assumed UTC).
    // A regression here either drops real stalls or, where a caller falls back
    // to "now", resurrects abandoned ones.
    func testISOParsesTimezoneAwareAndFractional() {
        XCTAssertNotNil(ISO.parse("2026-06-26T10:30:00Z"))
        XCTAssertNotNil(ISO.parse("2026-06-26T10:30:00.123456Z"))
        XCTAssertNotNil(ISO.parse("2026-06-26T10:30:00+02:00"))
    }

    func testISOParsesTimezonelessAsUTC() {
        // SQLite's default `datetime('now')` emits "2026-06-26 10:30:00":
        // a space separator and no timezone. Assumed UTC.
        let utc = ISO.parse("2026-06-26T10:30:00Z")
        XCTAssertNotNil(utc)
        XCTAssertEqual(ISO.parse("2026-06-26 10:30:00"), utc)
        XCTAssertEqual(ISO.parse("2026-06-26T10:30:00"), utc)
    }

    func testISORejectsGarbage() {
        XCTAssertNil(ISO.parse("not a date"))
        XCTAssertNil(ISO.parse(""))
    }

    // The two limit kinds both arrive as 429 but route differently.
    func testStallKindClassify() {
        XCTAssertEqual(
            StallKind.classify("Server is temporarily limiting requests (not your usage limit)"),
            .transient)
        XCTAssertEqual(StallKind.classify("You've hit your usage limit · resets 1pm"), .usageLimit)
        XCTAssertEqual(StallKind.classify("Claude usage limit reached"), .usageLimit)
    }
}
