import XCTest

@testable import NightConductor

/// Budget-ledger tests for the C1 fix (success vs failure tracking).
/// Night-key / immutability tests live in PolicyTests' NightLedgerTests.
final class NightLedgerBudgetTests: XCTestCase {
    func testSuccessSpendsBudgetFailureDoesNot() {
        var night = NightLedger(key: "2026-06-16")
        night = night.recordingFailure("s1")
        night = night.recordingFailure("s1")
        // A pile of failures must NOT consume the per-night budget.
        XCTAssertEqual(night.total, 0)
        XCTAssertEqual(night.count(for: "s1"), 0)
        XCTAssertEqual(night.failureCount(for: "s1"), 2)

        night = night.recordingSuccess("s1")
        XCTAssertEqual(night.total, 1)            // only the success counts
        XCTAssertEqual(night.count(for: "s1"), 1)
        XCTAssertEqual(night.failureCount(for: "s1"), 2) // failures unchanged
    }

    func testSuccessAndFailureAreIndependentPerSession() {
        var night = NightLedger(key: "k")
        night = night.recordingSuccess("a").recordingSuccess("b").recordingFailure("c")
        XCTAssertEqual(night.total, 2)
        XCTAssertEqual(night.count(for: "a"), 1)
        XCTAssertEqual(night.count(for: "c"), 0)
        XCTAssertEqual(night.failureCount(for: "c"), 1)
    }

    func testRecordingReturnsNewValueWithoutMutating() {
        let base = NightLedger(key: "k")
        let next = base.recordingSuccess("x")
        XCTAssertEqual(base.total, 0)   // immutable: original untouched
        XCTAssertEqual(next.total, 1)
    }

    func testPersistsSuccessAndFailureSeparately() {
        let defaults = makeDefaults()
        var night = NightLedger.load(startHour: 23, defaults: defaults)
        night = night.recordingSuccess("s1").recordingFailure("s2")
        night.save(defaults: defaults)

        let reloaded = NightLedger(
            key: night.key,
            counts: defaults.dictionary(forKey: "nightCounts") as? [String: Int] ?? [:],
            failures: defaults.dictionary(forKey: "nightFailures") as? [String: Int] ?? [:]
        )
        XCTAssertEqual(reloaded.count(for: "s1"), 1)
        XCTAssertEqual(reloaded.failureCount(for: "s2"), 1)
    }

    func testLoadResetsWhenNightKeyChanges() {
        let defaults = makeDefaults()
        defaults.set("1999-01-01", forKey: "nightKey")
        defaults.set(["old": 5], forKey: "nightCounts")
        defaults.set(["old": 9], forKey: "nightFailures")
        // A new night → fresh budget, prior counts ignored.
        let night = NightLedger.load(startHour: 23, defaults: defaults)
        XCTAssertNotEqual(night.key, "1999-01-01")
        XCTAssertEqual(night.total, 0)
        XCTAssertEqual(night.failureCount(for: "old"), 0)
    }

    // C2: the same Claude session under two source IDs shares ONE per-session
    // counter, so it can't quietly get 2× the per-session retry budget by
    // being resumed once as a Conductor session and once as a terminal one.
    func testLedgerKeyCollapsesCrossSourceDuplicates() {
        let claude = "824cbb1e-3ace-4666-8674-d7bd19f442a6"
        let conductor = StalledSession(
            sessionID: claude, claudeSessionID: claude, title: "t",
            workspacePath: "/w", errorText: "limit", stalledAt: nil, source: .conductor)
        let terminal = StalledSession(
            sessionID: "cc-\(claude)", claudeSessionID: claude, title: "t",
            workspacePath: "/w", errorText: "limit", stalledAt: nil, source: .claudeCode)
        XCTAssertEqual(conductor.ledgerKey, terminal.ledgerKey) // same counter

        var night = NightLedger(key: "k")
        night = night.recordingSuccess(conductor.ledgerKey)
        night = night.recordingSuccess(terminal.ledgerKey)
        // Both resumes accumulate under one key — the per-session cap (3)
        // is now shared across sources instead of being 3-per-source.
        XCTAssertEqual(night.count(for: conductor.ledgerKey), 2)
        XCTAssertEqual(night.count(for: terminal.ledgerKey), 2)
    }

    func testLedgerKeyFallsBackToSessionIDWhenClaudeIDEmpty() {
        let s = StalledSession(
            sessionID: "only-id", claudeSessionID: "", title: "t",
            workspacePath: "/w", errorText: "limit", stalledAt: nil)
        XCTAssertEqual(s.ledgerKey, "only-id")
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "NightLedgerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
