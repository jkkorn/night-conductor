import XCTest

@testable import NightConductor

final class ResumeEligibilityTests: XCTestCase {
    private let now = Date()

    private func session(transient: Bool, stalledAgo: TimeInterval?) -> StalledSession {
        StalledSession(
            sessionID: "s", claudeSessionID: "s", title: "t", workspacePath: "/w",
            errorText: transient
                ? "API Error: Server is temporarily limiting requests (not your usage limit)"
                : "You've hit your usage limit",
            stalledAt: stalledAgo.map { now.addingTimeInterval(-$0) }
        )
    }

    private func eligible(_ s: StalledSession, nightOK: Bool, pins: Set<String> = []) -> Bool {
        AppState.autoResumeEligible(s, nightOK: nightOK, pins: pins, now: now)
    }

    func testNightWindowGatesUnpinned() {
        let s = session(transient: false, stalledAgo: 3600)
        XCTAssertTrue(eligible(s, nightOK: true))                 // in window
        XCTAssertFalse(eligible(s, nightOK: false))               // out of window, unpinned
        XCTAssertTrue(eligible(s, nightOK: false, pins: ["s"]))   // pinned: around the clock
    }

    // A transient server rate-limit must cool down before we retry, so the
    // auto loop never bounces straight back into the same limit.
    func testTransientCooldown() {
        XCTAssertFalse(eligible(session(transient: true, stalledAgo: 30), nightOK: true))   // just stalled: wait
        XCTAssertTrue(eligible(session(transient: true, stalledAgo: 600), nightOK: true))   // past cool-down
        XCTAssertTrue(eligible(session(transient: true, stalledAgo: nil), nightOK: true))   // unknown time: don't block
        XCTAssertTrue(eligible(session(transient: false, stalledAgo: 30), nightOK: true))   // cool-down is transient-only
    }

    // The "resume pace" setting (minutes) is clamped to 5...20 and converted to
    // seconds; nil (unset) falls back to the 10 min default.
    func testResumePaceClamping() {
        XCTAssertEqual(AppState.paceSeconds(10), 600)
        XCTAssertEqual(AppState.paceSeconds(5), 300)
        XCTAssertEqual(AppState.paceSeconds(20), 1200)
        XCTAssertEqual(AppState.paceSeconds(2), 300)    // clamped up to 5
        XCTAssertEqual(AppState.paceSeconds(60), 1200)  // clamped down to 20
        XCTAssertEqual(AppState.paceSeconds(nil), 600)  // unset -> default
    }
}
