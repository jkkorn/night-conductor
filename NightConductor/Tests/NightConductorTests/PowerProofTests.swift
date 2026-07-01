import XCTest

@testable import NightConductor

/// The app now shows proof it was working: a keep-awake timeline and a
/// launch-at-login default. These pin the durable logic behind that proof.
final class PowerProofTests: XCTestCase {
    private func defs() -> UserDefaults {
        let suite = "PowerProofTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // Launch-at-login defaults ON exactly once, then respects the user's later
    // choice forever (so turning it off in Settings sticks).
    func testFirstLaunchConsumedExactlyOnce() {
        let d = defs()
        XCTAssertTrue(LoginItem.consumeFirstLaunch(defaults: d))    // first launch: apply default
        XCTAssertFalse(LoginItem.consumeFirstLaunch(defaults: d))   // never again
        XCTAssertFalse(LoginItem.consumeFirstLaunch(defaults: d))
    }

    // Each "awake" edge pairs with the next release.
    func testAwakeSecondsPairsEdges() {
        let d = defs()
        let now = Date()
        PowerLog.record(awake: true, at: now.addingTimeInterval(-3600), defaults: d)
        PowerLog.record(awake: false, at: now.addingTimeInterval(-1800), defaults: d)
        XCTAssertEqual(
            PowerLog.awakeSeconds(since: now.addingTimeInterval(-24 * 3600), now: now, defaults: d),
            1800, accuracy: 1)
    }

    // A still-open span counts up to `now` (it's keeping awake right now).
    func testOpenSpanCountsToNow() {
        let d = defs()
        let now = Date()
        PowerLog.record(awake: true, at: now.addingTimeInterval(-600), defaults: d)
        XCTAssertEqual(
            PowerLog.awakeSeconds(since: now.addingTimeInterval(-24 * 3600), now: now, defaults: d),
            600, accuracy: 1)
    }

    // Two "awake" edges in a row collapse to one (only real transitions logged).
    func testRepeatsAreDropped() {
        let d = defs()
        let now = Date()
        PowerLog.record(awake: true, at: now.addingTimeInterval(-100), defaults: d)
        PowerLog.record(awake: true, at: now.addingTimeInterval(-50), defaults: d)
        XCTAssertEqual(PowerLog.load(defaults: d).count, 1)
    }

    // A span left open by a crash is closed at the last heartbeat, so the total
    // reflects when the app actually died, not the gap until relaunch.
    func testCloseOpenSpanAtLastAlive() {
        let d = defs()
        let now = Date()
        PowerLog.record(awake: true, at: now.addingTimeInterval(-7200), defaults: d) // awake 2h ago
        PowerLog.closeOpenSpan(lastAlive: now.addingTimeInterval(-3600), defaults: d) // died 1h ago
        XCTAssertEqual(PowerLog.load(defaults: d).last?.awake, false)
        XCTAssertEqual(
            PowerLog.awakeSeconds(since: now.addingTimeInterval(-24 * 3600), now: now, defaults: d),
            3600, accuracy: 1) // 2h-ago to 1h-ago, not counted to now
    }
}
