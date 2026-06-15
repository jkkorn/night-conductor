import XCTest

@testable import NightConductor

final class ClaudeDesktopTests: XCTestCase {
    private let now = ISO.parse("2026-06-15T11:00:00Z")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Write a session: local_<id>.json + <id>/audit.jsonl with the given lines.
    private func seed(id: String, title: String = "Fix bug", archived: Bool = false,
                      cwd: String? = nil, audit: [String]) throws {
        let grp = root.appendingPathComponent("grp")
        try FileManager.default.createDirectory(at: grp, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "sessionId": id, "cliSessionId": "cli-\(id)",
            "cwd": cwd ?? root.path, "title": title, "isArchived": archived,
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: grp.appendingPathComponent("\(id).json"))
        let auditDir = grp.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        try audit.joined(separator: "\n").write(
            to: auditDir.appendingPathComponent("audit.jsonl"), atomically: true, encoding: .utf8)
    }

    private func limitResult() -> String {
        #"{"type":"result","is_error":true,"api_error_status":429,"result":"You've hit your usage limit","_audit_timestamp":"2026-06-15T10:00:00.000Z"}"#
    }
    private func okResult() -> String {
        #"{"type":"result","is_error":false,"_audit_timestamp":"2026-06-15T10:05:00.000Z"}"#
    }
    private func warning() -> String {
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"seven_day"},"_audit_timestamp":"2026-06-15T10:00:00.000Z"}"#
    }

    func testDetectsSessionStalledOnLimit() throws {
        try seed(id: "local_s1", audit: [okResult(), limitResult()])
        let stalled = ClaudeDesktopDB.findStalledSessions(root: root.path, now: now)
        XCTAssertEqual(stalled.count, 1)
        XCTAssertEqual(stalled.first?.claudeSessionID, "cli-local_s1")
        XCTAssertEqual(stalled.first?.source, .claudeDesktop)
    }

    func testIgnoresRecoveredSession() throws {
        try seed(id: "local_s2", audit: [limitResult(), okResult()])
        XCTAssertTrue(ClaudeDesktopDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }

    func testIgnoresArchived() throws {
        try seed(id: "local_s3", archived: true, audit: [limitResult()])
        XCTAssertTrue(ClaudeDesktopDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }

    func testWarningIsNotAStall() throws {
        try seed(id: "local_s4", audit: [warning()])
        XCTAssertTrue(ClaudeDesktopDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }

    func testIgnoresMissingWorkspace() throws {
        try seed(id: "local_s5", cwd: "/no/such/dir", audit: [limitResult()])
        XCTAssertTrue(ClaudeDesktopDB.findStalledSessions(root: root.path, now: now).isEmpty)
    }
}
