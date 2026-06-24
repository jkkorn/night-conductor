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

    // A session just resumed must not be re-fired for a cool-down, so the loop
    // can't pile inference onto a rate limit by re-resuming the same session
    // (e.g. when a headless resume doesn't clear the host's stalled flag).
    func testResumeCooldownSpacesSameSession() {
        let s = session(transient: false, stalledAgo: 3600)
        XCTAssertFalse(AppState.autoResumeEligible(s, nightOK: true, pins: [], now: now,
                                                   lastResumedAt: now.addingTimeInterval(-60)))    // just resumed
        XCTAssertTrue(AppState.autoResumeEligible(s, nightOK: true, pins: [], now: now,
                                                  lastResumedAt: now.addingTimeInterval(-1200)))   // 20 min ago
        XCTAssertTrue(AppState.autoResumeEligible(s, nightOK: true, pins: [], now: now,
                                                  lastResumedAt: nil))                              // never
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

    // Manual "Resume now" must resume the WHOLE list; an auto pass stops after
    // one success to spread the night's work. (Regression: a manual pass used
    // to stop after the first in-app resume, so "some didn't resume".)
    func testManualPassResumesAllAutoStopsAfterOne() {
        // Auto: stop after any success (handed to app or headless).
        XCTAssertTrue(AppState.shouldStopPass(manual: false, handedToApp: true, resultOK: true))
        XCTAssertTrue(AppState.shouldStopPass(manual: false, handedToApp: false, resultOK: true))
        XCTAssertFalse(AppState.shouldStopPass(manual: false, handedToApp: false, resultOK: false)) // failed: keep going
        // Manual: never stop, even after an in-app resume.
        XCTAssertFalse(AppState.shouldStopPass(manual: true, handedToApp: true, resultOK: true))
        XCTAssertFalse(AppState.shouldStopPass(manual: true, handedToApp: false, resultOK: true))
    }
}
