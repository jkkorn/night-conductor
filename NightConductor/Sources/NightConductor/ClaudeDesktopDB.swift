import Foundation

/// Read-only scanner for Claude Desktop's "Cowork" / local-agent-mode
/// sessions. Each session is a `local_<uuid>.json` (metadata: cliSessionId,
/// cwd, title, isArchived) with an `audit.jsonl` event stream. A session is
/// "stalled" when its audit ends on a usage-limit result or a blocking
/// rate-limit event with no successful event after.
enum ClaudeDesktopDB {
    static var sessionsRoot: String {
        NSHomeDirectory()
            + "/Library/Application Support/Claude/local-agent-mode-sessions"
    }

    private static let maxStallAge: TimeInterval = 48 * 3600

    static func findStalledSessions(
        root: String = sessionsRoot, now: Date = Date()
    ) -> [StalledSession] {
        let fm = FileManager.default
        guard let metaFiles = enumerateMetaFiles(root: root, fm: fm) else { return [] }
        var out: [StalledSession] = []
        for metaURL in metaFiles {
            guard let session = parse(metaURL: metaURL, now: now, fm: fm) else { continue }
            out.append(session)
        }
        return out
    }

    /// Every `local_<uuid>.json` under the sessions root (recursive).
    private static func enumerateMetaFiles(root: String, fm: FileManager) -> [URL]? {
        guard let walker = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var files: [URL] = []
        for case let url as URL in walker where
            url.lastPathComponent.hasPrefix("local_")
            && url.pathExtension == "json" {
            files.append(url)
        }
        return files
    }

    private static func parse(metaURL: URL, now: Date, fm: FileManager) -> StalledSession? {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if meta["isArchived"] as? Bool == true { return nil }

        guard let cliSessionId = meta["cliSessionId"] as? String, !cliSessionId.isEmpty,
              let cwd = meta["cwd"] as? String, !cwd.isEmpty
        else { return nil }

        // audit.jsonl lives in a sibling dir named after the session id.
        let sessionId = (meta["sessionId"] as? String) ?? metaURL.deletingPathExtension().lastPathComponent
        let auditURL = metaURL.deletingLastPathComponent()
            .appendingPathComponent(sessionId).appendingPathComponent("audit.jsonl")
        guard let stall = stallSignal(auditURL: auditURL) else { return nil }

        if now.timeIntervalSince(stall.at) > maxStallAge { return nil } // too old

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }

        return StalledSession(
            sessionID: "claude-\(sessionId)",
            claudeSessionID: cliSessionId,
            title: (meta["title"] as? String) ?? "Untitled",
            workspacePath: cwd,
            errorText: stall.text,
            stalledAt: stall.at,
            source: .claudeDesktop
        )
    }

    /// Inspect the last meaningful audit events; return the stall if the
    /// session ended at a limit. Conservative: a successful `result` after
    /// the limit clears it.
    private static func stallSignal(auditURL: URL) -> (text: String, at: Date)? {
        guard let content = try? String(contentsOf: auditURL, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n").suffix(40)
        var stall: (text: String, at: Date)?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = event["type"] as? String
            let at = (event["_audit_timestamp"] as? String).flatMap(ISO.parse) ?? Date()

            if type == "result", event["is_error"] as? Bool == true,
               (event["api_error_status"] as? NSNumber)?.intValue == 429 {
                stall = (String(event["result"] as? String ?? "You've hit your usage limit"), at)
            } else if type == "rate_limit_event",
                      let info = event["rate_limit_info"] as? [String: Any],
                      isBlocking(info["status"] as? String) {
                stall = ("Rate limited (\(info["rateLimitType"] as? String ?? "usage"))", at)
            } else if type == "result" || type == "assistant" {
                stall = nil // a real turn completed after the limit → recovered
            }
        }
        return stall
    }

    private static func isBlocking(_ status: String?) -> Bool {
        guard let s = status?.lowercased() else { return false }
        // "allowed_warning" is just a heads-up; blocks read as rejected/exceeded.
        return s.contains("block") || s.contains("reject") || s.contains("exceeded")
            || s == "limited" || s == "denied"
    }
}
