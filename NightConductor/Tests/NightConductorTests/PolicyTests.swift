import XCTest

@testable import NightConductor

final class PolicyTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, day: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }

    private func snapshot(
        fiveHour: Double = 10, weekly: Double = 10, resetsInDays: Double = 3, now: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: fiveHour, resetsAt: nil),
            sevenDay: UsageWindow(
                utilization: weekly,
                resetsAt: now.addingTimeInterval(resetsInDays * 86_400)
            ),
            fetchedAt: now
        )
    }

    func testActiveHoursMidnightWrap() {
        XCTAssertTrue(Policy.inActiveHours(hour: 2, start: 23, end: 7))
        XCTAssertTrue(Policy.inActiveHours(hour: 23, start: 23, end: 7))
        XCTAssertFalse(Policy.inActiveHours(hour: 12, start: 23, end: 7))
        XCTAssertTrue(Policy.inActiveHours(hour: 5, start: 0, end: 0)) // always
    }

    func testFiveHourCeilingHolds() {
        let now = date(hour: 2)
        let decision = Policy.shouldResume(
            usage: snapshot(fiveHour: 90, now: now),
            config: PolicyConfig(), now: now, calendar: utc
        )
        XCTAssertFalse(decision.resume)
        XCTAssertTrue(decision.reason.contains("5-hour"))
    }

    func testMorningProtectionHoldsWithinFiveHoursOfWake() {
        let fiveAM = date(hour: 5) // wake at 7 -> window would be hot until 10
        let decision = Policy.shouldResume(
            usage: snapshot(now: fiveAM), config: PolicyConfig(),
            now: fiveAM, calendar: utc
        )
        XCTAssertFalse(decision.resume)
        XCTAssertTrue(decision.reason.contains("Morning protection"))
    }

    func testTwoAMIsTheLastSafeStart() {
        let twoAM = date(hour: 2) // exactly 5h before wake -> resets by 07:00
        let decision = Policy.shouldResume(
            usage: snapshot(now: twoAM), config: PolicyConfig(),
            now: twoAM, calendar: utc
        )
        XCTAssertTrue(decision.resume)
    }

    func testBurningTooFastHolds() {
        let now = date(hour: 2)
        let decision = Policy.shouldResume(
            usage: snapshot(weekly: 70, resetsInDays: 5, now: now),
            config: PolicyConfig(), now: now, calendar: utc
        )
        XCTAssertFalse(decision.resume)
        XCTAssertTrue(decision.reason.contains("too fast"))
    }

    func testHighUsageNearResetResumes() {
        let now = date(hour: 2)
        let decision = Policy.shouldResume(
            usage: snapshot(weekly: 70, resetsInDays: 0.5, now: now),
            config: PolicyConfig(), now: now, calendar: utc
        )
        XCTAssertTrue(decision.resume)
    }

    func testManualTickBypassesHoursButNotBudget() {
        let noon = date(hour: 12)
        let underBudget = Policy.shouldResume(
            usage: snapshot(now: noon), config: PolicyConfig(),
            now: noon, calendar: utc, ignoreActiveHours: true
        )
        XCTAssertTrue(underBudget.resume)

        let overBudget = Policy.shouldResume(
            usage: snapshot(fiveHour: 95, now: noon), config: PolicyConfig(),
            now: noon, calendar: utc, ignoreActiveHours: true
        )
        XCTAssertFalse(overBudget.resume)
    }

    func testISOParsingHandlesBothPrecisions() {
        XCTAssertNotNil(ISO.parse("2026-06-12T05:00:00.772121+00:00")) // usage API
        XCTAssertNotNil(ISO.parse("2026-06-09T03:42:18.186Z")) // Conductor DB
    }
}
