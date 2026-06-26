import XCTest

@testable import NightConductor

final class UsageFetchTests: XCTestCase {
    private func should(force: Bool, hasUsage: Bool, fresh: Bool, inBackoff: Bool,
                        age: TimeInterval = 0, threshold: TimeInterval = 180) -> Bool {
        AppState.shouldFetchUsage(force: force, hasUsage: hasUsage, fresh: fresh,
                                  inBackoff: inBackoff, age: age, threshold: threshold)
    }

    // The bug: a 429 backoff stranded a stale reading, so the app held all
    // night on outdated "you're maxed" data even when there was headroom.
    func testStaleReadingBypassesBackoff() {
        // Stale data + active backoff: must retry to recover (forced or due).
        XCTAssertTrue(should(force: true, hasUsage: true, fresh: false, inBackoff: true))
        XCTAssertTrue(should(force: false, hasUsage: true, fresh: false, inBackoff: true, age: 1000))
    }

    func testBackoffStillThrottlesFreshData() {
        // Fresh data + backoff: skip, even when forced (this is the throttle).
        XCTAssertFalse(should(force: true, hasUsage: true, fresh: true, inBackoff: true))
    }

    func testFreshAndNotDueDoesNotRefetch() {
        XCTAssertFalse(should(force: false, hasUsage: true, fresh: true, inBackoff: false, age: 10))
    }

    func testDueByIntervalRefetches() {
        XCTAssertTrue(should(force: false, hasUsage: true, fresh: true, inBackoff: false, age: 300))
    }

    func testFirstLoadAlwaysFetches() {
        XCTAssertTrue(should(force: false, hasUsage: false, fresh: false, inBackoff: false))
    }

    // Skip a doomed usage call when the Claude Code token is already expired,
    // so we tell the user to refresh instead of silently holding (and we don't
    // hammer the endpoint with calls that will just 401).
    func testTokenExpiry() {
        let now = Date()
        XCTAssertTrue(UsageClient.isExpired(now.addingTimeInterval(-10), now: now))   // past
        XCTAssertFalse(UsageClient.isExpired(now.addingTimeInterval(3600), now: now)) // hour left
        XCTAssertFalse(UsageClient.isExpired(nil, now: now))                          // unknown: let the call decide
        // clock-skew buffer: expiring in 30s is treated as expired (default 60s skew)
        XCTAssertTrue(UsageClient.isExpired(now.addingTimeInterval(30), now: now))
    }

    // A minimum gap floors the /usage call rate even for forced fetches, so
    // rapid popover opens while rate-limited can't fire a call per open.
    func testCallRateFloorEvenWhenForced() {
        // Forced + stale + due, but attempted 5s ago with a 20s floor: skip.
        XCTAssertFalse(AppState.shouldFetchUsage(
            force: true, hasUsage: true, fresh: false, inBackoff: false,
            age: 1000, threshold: 180, attemptAge: 5, minAttemptGap: 20))
        // Past the floor: allowed.
        XCTAssertTrue(AppState.shouldFetchUsage(
            force: true, hasUsage: true, fresh: false, inBackoff: false,
            age: 1000, threshold: 180, attemptAge: 25, minAttemptGap: 20))
        // The floor applies even with NO reading yet: a failed first fetch
        // (429 / signed out) leaves usage nil, and rapid popover opens must
        // still be floored. (Regression: this case used to fire one /usage
        // call per open because the floor was gated on hasUsage.)
        XCTAssertFalse(AppState.shouldFetchUsage(
            force: true, hasUsage: false, fresh: false, inBackoff: false,
            age: 1000, threshold: 180, attemptAge: 3, minAttemptGap: 20))
        // A TRUE first load (never attempted → attemptAge defaults to .greatest)
        // is exempt, so the meters populate immediately.
        XCTAssertTrue(AppState.shouldFetchUsage(
            force: false, hasUsage: false, fresh: false, inBackoff: false,
            age: 0, threshold: 180, minAttemptGap: 20))
    }

    // A 429 backoff must also hold when we have NO reading yet — otherwise a
    // user who is already rate-limited (first fetch 429'd, usage still nil)
    // could re-fire /usage on every popover open. Backoff only stands down to
    // recover a STALE reading, which the nil case is not. (Regression.)
    func testBackoffHoldsWhenNoReadingYet() {
        XCTAssertFalse(AppState.shouldFetchUsage(
            force: true, hasUsage: false, fresh: false, inBackoff: true,
            age: 1000, threshold: 180, attemptAge: 100, minAttemptGap: 20))
    }
}
