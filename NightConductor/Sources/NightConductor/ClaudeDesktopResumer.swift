import AppKit
import ApplicationServices

/// Resumes a stalled Claude Desktop "Cowork" session by driving Claude
/// Desktop's own UI: navigate to the session by title (opening the Cowork
/// tab if needed), then press its Retry button. This keeps the run inside
/// Claude Desktop's sandbox — there is deliberately no headless fallback,
/// because resuming on the host would drop that sandbox.
enum ClaudeDesktopResumer {
    static let bundleID = "com.anthropic.claudefordesktop"

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    static func resume(session: StalledSession, now: Date = Date()) -> ResumeResult {
        guard AXIsProcessTrusted() else {
            return ResumeResult(ok: false, detail: "no Accessibility permission")
        }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).first else {
            return ResumeResult(ok: false, detail: "Claude Desktop is not running")
        }
        app.activate() // the view must be frontmost to be interactive
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.0)

        // 1. Navigate to the session by its title.
        let title = normalize(session.title)
        var target = findButton(in: axApp) { matchesTitle($0, title) }
        if target == nil, let cowork = findButton(in: axApp, where: { norm in
            norm.trimmingCharacters(in: .whitespaces) == "cowork"
        }) {
            AXUIElementPerformAction(cowork, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1.5)
            target = findButton(in: axApp) { matchesTitle($0, title) }
        }
        guard let sessionButton = target else {
            return ResumeResult(ok: false, detail: "'\(session.title)' not found in Claude Desktop")
        }
        AXUIElementPerformAction(sessionButton, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 2.0)

        // 2. Press Retry.
        guard let retry = findButton(in: axApp, where: { $0.trimmingCharacters(in: .whitespaces) == "retry" }) else {
            return ResumeResult(ok: false, detail: "Retry not visible (session may have recovered)")
        }
        AXUIElementPerformAction(retry, kAXPressAction as CFString)

        // 3. Verify: the session should drop out of the stalled set once its
        //    audit gets a fresh event.
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 2)
            let stillStalled = ClaudeDesktopDB.findStalledSessions(now: now)
                .contains { $0.sessionID == session.sessionID }
            if !stillStalled {
                return ResumeResult(ok: true, detail: "resumed inside Claude Desktop")
            }
        }
        return ResumeResult(ok: false, detail: "pressed Retry but session didn't resume")
    }

    // MARK: - AX helpers

    private static func matchesTitle(_ label: String, _ title: String) -> Bool {
        let l = normalize(label)
        return !title.isEmpty && (l == title || l.hasPrefix(title) || l.contains(title))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static func attribute(_ e: AXUIElement, _ n: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, n as CFString, &v)
        return v
    }

    private static func label(of e: AXUIElement) -> String {
        let t = (attribute(e, kAXTitleAttribute) as? String) ?? ""
        let d = (attribute(e, kAXDescriptionAttribute) as? String) ?? ""
        let v = (attribute(e, kAXValueAttribute) as? String) ?? ""
        return "\(t) \(d) \(v)".trimmingCharacters(in: .whitespaces)
    }

    private static func findButton(
        in root: AXUIElement, where matches: (String) -> Bool
    ) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 80000 {
            let e = queue.removeFirst()
            visited += 1
            if (attribute(e, kAXRoleAttribute) as? String) == "AXButton",
               matches(label(of: e)) {
                return e
            }
            if let kids = attribute(e, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: kids)
            }
        }
        return nil
    }
}
