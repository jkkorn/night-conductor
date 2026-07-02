import XCTest

@testable import NightConductor

/// HoldLog answers "why didn't it resume anything" durably. It exists because
/// a real overnight incident took ten minutes of manual SQLite/Keychain
/// forensics to diagnose (a hold reason that only ever lived in an in-memory
/// @Published var), when the app already computes that reason every tick.
final class HoldLogTests: XCTestCase {
    private func defs() -> UserDefaults {
        let suite = "HoldLogTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testUnchangedReasonIsNotSpammed() {
        let d = defs()
        let now = Date()
        HoldLog.record(reason: "Claude sign-in expired", at: now, defaults: d)
        HoldLog.record(reason: "Claude sign-in expired", at: now.addingTimeInterval(30), defaults: d)
        XCTAssertEqual(HoldLog.load(defaults: d).count, 1)
    }

    func testLongestHoldPicksTheBiggestReason() {
        let d = defs()
        let now = Date()
        // Held 2h for sign-in, then briefly cleared, then held 10m for stale usage.
        HoldLog.record(reason: "Claude sign-in expired", at: now.addingTimeInterval(-7200), defaults: d)
        HoldLog.record(reason: "", at: now.addingTimeInterval(-3600), defaults: d)
        HoldLog.record(reason: "Usage data is stale, holding", at: now.addingTimeInterval(-600), defaults: d)
        HoldLog.record(reason: "", at: now, defaults: d)

        let longest = HoldLog.longestHold(since: now.addingTimeInterval(-24 * 3600), now: now, defaults: d)
        XCTAssertEqual(longest?.reason, "Claude sign-in expired")
        XCTAssertEqual(longest?.seconds ?? 0, 3600, accuracy: 1)
    }

    // The exact regression this exists for: a hold that never clears before
    // `now` (still ongoing) counts up to `now`, not zero.
    func testOpenHoldCountsToNow() {
        let d = defs()
        let now = Date()
        HoldLog.record(reason: "Claude sign-in expired", at: now.addingTimeInterval(-1800), defaults: d)
        let longest = HoldLog.longestHold(since: now.addingTimeInterval(-24 * 3600), now: now, defaults: d)
        XCTAssertEqual(longest?.reason, "Claude sign-in expired")
        XCTAssertEqual(longest?.seconds ?? 0, 1800, accuracy: 1)
    }

    // Non-adjacent spans with the SAME reason accumulate to their true total.
    func testSameReasonAcrossGapsAccumulates() {
        let d = defs()
        let now = Date()
        HoldLog.record(reason: "Checking usage…", at: now.addingTimeInterval(-3000), defaults: d)
        HoldLog.record(reason: "", at: now.addingTimeInterval(-2700), defaults: d)          // resumed 5m later
        HoldLog.record(reason: "Checking usage…", at: now.addingTimeInterval(-1200), defaults: d)
        HoldLog.record(reason: "", at: now.addingTimeInterval(-900), defaults: d)            // resumed again

        let longest = HoldLog.longestHold(since: now.addingTimeInterval(-24 * 3600), now: now, defaults: d)
        XCTAssertEqual(longest?.reason, "Checking usage…")
        XCTAssertEqual(longest?.seconds ?? 0, 600, accuracy: 1) // 300s + 300s
    }

    func testNoHoldsReturnsNil() {
        XCTAssertNil(HoldLog.longestHold(since: Date().addingTimeInterval(-3600), defaults: defs()))
    }

    // A hold left open by a crash is closed at the last heartbeat, matching
    // PowerLog's crash-safety behavior.
    func testCloseOpenSpanAtLastAlive() {
        let d = defs()
        let now = Date()
        HoldLog.record(reason: "Claude sign-in expired", at: now.addingTimeInterval(-7200), defaults: d)
        HoldLog.closeOpenSpan(lastAlive: now.addingTimeInterval(-3600), defaults: d)
        let longest = HoldLog.longestHold(since: now.addingTimeInterval(-24 * 3600), now: now, defaults: d)
        XCTAssertEqual(longest?.seconds ?? 0, 3600, accuracy: 1) // not counted to `now`
    }
}
