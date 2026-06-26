import XCTest

@testable import NightConductor

final class ClaudeCodeTests: XCTestCase {
    private let now = ISO.parse("2026-06-15T11:00:00Z")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Write <uuid>.jsonl in a project dir, with `cwd` defaulting to an
    /// existing folder so the workspace check passes.
    private func seed(uuid: String, lines: [String], cwd: String? = nil) throws {
        let proj = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let dir = cwd ?? root.path
        let withCwd = lines.map { $0.replacingOccurrences(of: "__CWD__", with: dir) }
        try withCwd.joined(separator: "\n")
            .write(to: proj.appendingPathComponent("\(uuid).jsonl"), atomically: true, encoding: .utf8)
    }

    private func userLine() -> String {
        #"{"type":"user","cwd":"__CWD__","message":{"role":"user","content":"Fix the build"},"timestamp":"2026-06-15T10:00:00.000Z"}"#
    }
    private func okAssistant() -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]},"timestamp":"2026-06-15T10:05:00.000Z"}"#
    }
    private func errorAssistant() -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"message":{"role":"assistant","content":[{"type":"text","text":"You've hit your usage limit · resets 1pm"}]},"timestamp":"2026-06-15T10:10:00.000Z"}"#
    }

    func testDetectsTerminalSessionStalledOnLimit() throws {
        try seed(uuid: "u1", lines: [userLine(), okAssistant(), errorAssistant()])
        let stalled = ClaudeCodeDB.findStalledSessions(root: root.path, now: now)
        XCTAssertEqual(stalled.count, 1)
        XCTAssertEqual(stalled.first?.claudeSessionID, "u1")
        XCTAssertEqual(stalled.first?.source, .claudeCode)
        XCTAssertEqual(stalled.first?.title, "Fix the build")
    }

    func testIgnoresRecoveredTerminalSession() throws {
        try seed(uuid: "u2", lines: [userLine(), errorAssistant(), okAssistant()])
        XCTAssertTrue(ClaudeCodeDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }

    func testIgnoresMissingWorkspace() throws {
        try seed(uuid: "u3", lines: [userLine(), errorAssistant()], cwd: "/no/such/dir")
        XCTAssertTrue(ClaudeCodeDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }

    func testIgnoresConductorOwnedTranscripts() throws {
        // A Conductor workspace transcript also lives in ~/.claude/projects —
        // the terminal scanner must not claim it (Conductor's scanner does).
        let conductorCwd = root.appendingPathComponent("conductor/workspaces/RituaGym/new-york")
        try FileManager.default.createDirectory(at: conductorCwd, withIntermediateDirectories: true)
        try seed(uuid: "u4", lines: [userLine(), errorAssistant()], cwd: conductorCwd.path)
        XCTAssertTrue(ClaudeCodeDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }

    func testDedupesToOnePerWorkspace() throws {
        // Several stalled transcripts in the same cwd → one entry, not many.
        try seed(uuid: "w1", lines: [userLine(), errorAssistant()])
        try seed(uuid: "w2", lines: [userLine(), errorAssistant()])
        try seed(uuid: "w3", lines: [userLine(), errorAssistant()])
        XCTAssertEqual(ClaudeCodeDB.findStalledSessions(root: root.path, now: now).count, 1)
    }

    /// Regression: a newer ACTIVE transcript in a cwd must not hide an older,
    /// still-stalled transcript there. The scanner keeps the newest STALLED
    /// transcript per dir, not merely the newest.
    func testOlderStalledFoundWhenNewestIsActive() throws {
        try seed(uuid: "old-stalled", lines: [userLine(), errorAssistant()])
        try seed(uuid: "new-active", lines: [userLine(), okAssistant()])
        let proj = root.appendingPathComponent("proj")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3600)],
            ofItemAtPath: proj.appendingPathComponent("old-stalled.jsonl").path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-600)],  // newest
            ofItemAtPath: proj.appendingPathComponent("new-active.jsonl").path)

        let stalled = ClaudeCodeDB.findStalledSessions(root: root.path, now: now)
        XCTAssertEqual(stalled.count, 1)
        XCTAssertEqual(stalled.first?.claudeSessionID, "old-stalled")
    }

    private func errorAssistantAt(_ ts: String) -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"message":{"role":"assistant","content":[{"type":"text","text":"You've hit your usage limit"}]},"timestamp":"\#(ts)"}"#
    }

    // Fail closed: an undateable stall timestamp must not be treated as fresh.
    // It used to default to "now", which would resurrect a long-abandoned
    // session and burn the token budget.
    func testUndateableStallIsIgnored() throws {
        try seed(uuid: "bad-ts", lines: [userLine(), errorAssistantAt("not-a-timestamp")])
        XCTAssertTrue(ClaudeCodeDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }

    // A genuinely old stall (beyond the 48h window) is ignored.
    func testOldStallBeyondWindowIgnored() throws {
        try seed(uuid: "old", lines: [userLine(), errorAssistantAt("2026-06-10T10:00:00.000Z")])
        XCTAssertTrue(ClaudeCodeDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }
}
