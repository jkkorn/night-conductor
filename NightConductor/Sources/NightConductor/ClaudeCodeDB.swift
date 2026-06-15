import Foundation

/// Read-only scanner for standalone Claude Code (terminal) sessions in
/// ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl. A session is
/// "stalled" when its last assistant message is an API-limit error.
///
/// These aren't sandboxed, so they're resumed headlessly (faithful). For
/// speed it only reads recently-modified transcripts, and only their tail —
/// some are multi-megabyte. Conductor and Claude Desktop sessions also live
/// here; the caller dedupes by claudeSessionID so they aren't double-counted.
enum ClaudeCodeDB {
    static var projectsRoot: String { NSHomeDirectory() + "/.claude/projects" }

    private static let maxStallAge: TimeInterval = 48 * 3600
    private static let tailBytes = 24_000
    private static let headBytes = 16_000
    private static let maxFilesScanned = 120 // bound worst-case cost

    static func findStalledSessions(
        root: String = projectsRoot, now: Date = Date()
    ) -> [StalledSession] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Collect recent transcripts (cheap mtime check), newest first, capped.
        var recent: [(url: URL, mtime: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) <= maxStallAge { recent.append((url, mtime)) }
        }
        recent.sort { $0.mtime > $1.mtime }

        var out: [StalledSession] = []
        for entry in recent.prefix(maxFilesScanned) {
            if let session = parse(url: entry.url, now: now) { out.append(session) }
        }
        return out
    }

    private static func parse(url: URL, now: Date) -> StalledSession? {
        let lines = tail(url, maxBytes: tailBytes)
        var cwd: String?
        var lastAssistant: (isError: Bool, status: Int, text: String, ts: Date)?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if cwd == nil, let c = event["cwd"] as? String, !c.isEmpty { cwd = c }
            guard event["type"] as? String == "assistant" else { continue }
            let isError = event["isApiErrorMessage"] as? Bool == true
            let status = (event["apiErrorStatus"] as? NSNumber)?.intValue ?? 0
            let ts = (event["timestamp"] as? String).flatMap(ISO.parse) ?? now
            lastAssistant = (isError, status, assistantText(event), ts)
        }

        // Stalled iff the last model turn ended in a usage-limit error.
        guard let last = lastAssistant, last.isError,
              last.status == 429 || last.text.localizedCaseInsensitiveContains("limit")
        else { return nil }
        if now.timeIntervalSince(last.ts) > maxStallAge { return nil }

        let workingDir = cwd ?? decodeProjectDir(url.deletingLastPathComponent().lastPathComponent)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDir, isDirectory: &isDir),
              isDir.boolValue else { return nil }

        let uuid = url.deletingPathExtension().lastPathComponent
        return StalledSession(
            sessionID: "cc-\(uuid)",
            claudeSessionID: uuid,
            title: firstUserPrompt(url) ?? (workingDir as NSString).lastPathComponent,
            workspacePath: workingDir,
            errorText: last.text,
            stalledAt: last.ts,
            source: .claudeCode
        )
    }

    private static func assistantText(_ event: [String: Any]) -> String {
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    /// First user prompt, for a human-readable title (cheap head read).
    private static func firstUserPrompt(_ url: URL) -> String? {
        for line in head(url, maxBytes: headBytes) {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "user",
                  let message = event["message"] as? [String: Any]
            else { continue }
            if let text = message["content"] as? String {
                return String(text.prefix(60))
            }
            if let content = message["content"] as? [[String: Any]],
               let text = content.compactMap({ $0["text"] as? String }).first {
                return String(text.prefix(60))
            }
        }
        return nil
    }

    /// "-Users-jonathan-Code-RituaGym" → "/Users/jonathan/Code/RituaGym".
    /// Lossy for real dashes; only a fallback when the jsonl has no cwd.
    private static func decodeProjectDir(_ name: String) -> String {
        "/" + name.drop(while: { $0 == "-" }).replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Efficient partial reads

    private static func tail(_ url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }

    private static func head(_ url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }
}
