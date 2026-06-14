import AppKit
import ApplicationServices

/// Resumes a stalled session *inside* Conductor by driving its UI through
/// the Accessibility API: navigate to the workspace in the sidebar, then
/// press the session's "Retry" button. Unlike the headless resumer, the run
/// then happens in Conductor's own agent loop — chat UI stays in sync.
///
/// Requires the Accessibility permission (System Settings → Privacy &
/// Security → Accessibility). Every failure path returns a ResumeResult
/// with ok=false so the caller can fall back to headless mode.
enum UIResumer {
    static let conductorBundleID = "com.conductor.app"

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to the Accessibility pane.
    static func requestPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func resume(session: StalledSession) -> ResumeResult {
        guard AXIsProcessTrusted() else {
            return ResumeResult(ok: false, detail: "no Accessibility permission")
        }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: conductorBundleID
        ).first else {
            return ResumeResult(ok: false, detail: "Conductor is not running")
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Ask the Tauri WebView to expose its full accessibility tree.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.0)

        // 1. Navigate: Conductor's sidebar labels workspaces by their
        //    directory name (e.g. "new-york" shows as "New york"), not the
        //    session title. Match on the normalized workspace name first,
        //    then fall back to the title for same-named workspaces.
        guard let workspaceLink = findWorkspaceLink(in: axApp, session: session) else {
            return ResumeResult(
                ok: false,
                detail: "'\(session.workspaceName)' not found in Conductor's sidebar"
            )
        }
        AXUIElementPerformAction(workspaceLink, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 2.5)

        // 2. Press "Retry" (and not "Retry in new chat").
        guard let retryButton = findElement(in: axApp, role: "AXButton", where: { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("Retry")
                && !trimmed.localizedCaseInsensitiveContains("new chat")
        }) else {
            return ResumeResult(
                ok: false,
                detail: "Retry button not visible (session may have recovered)"
            )
        }
        AXUIElementPerformAction(retryButton, kAXPressAction as CFString)

        // 3. Trust but verify: Conductor flips the session to 'working' in
        //    its DB once the agent actually starts.
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 2)
            if (try? ConductorDB.sessionStatus(session.sessionID)) == "working" {
                return ResumeResult(ok: true, detail: "resumed inside Conductor")
            }
        }
        return ResumeResult(ok: false, detail: "pressed Retry but session didn't start")
    }

    // MARK: - Navigation

    /// Conductor shows "new-york" as "New york", so compare on a normalized
    /// form: separators → spaces, lowercased.
    static func normalize(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Finds the sidebar link for a session's workspace, trying the most
    /// specific signal first: exact workspace name, then workspace-name
    /// prefix (the label often has a PR title appended), then session title.
    private static func findWorkspaceLink(
        in root: AXUIElement, session: StalledSession
    ) -> AXUIElement? {
        let workspace = normalize(session.workspaceName)
        let title = normalize(session.title)

        // Require a word-boundary prefix so "new" can't match "new jersey"
        // when the target workspace is "new york".
        func wordPrefix(_ label: String, _ needle: String) -> Bool {
            guard !needle.isEmpty else { return false }
            let l = normalize(label)
            return l == needle || l.hasPrefix(needle + " ")
        }
        let strategies: [(String) -> Bool] = [
            { normalize($0) == workspace },
            { wordPrefix($0, workspace) },
            { wordPrefix($0, title) },
        ]
        for matches in strategies {
            if let link = findElement(in: root, role: "AXLink", where: matches) {
                return link
            }
        }
        return nil
    }

    // MARK: - AX tree search

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func label(of element: AXUIElement) -> String {
        let title = (attribute(element, kAXTitleAttribute) as? String) ?? ""
        let description = (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
        let value = (attribute(element, kAXValueAttribute) as? String) ?? ""
        return "\(title) \(description) \(value)".trimmingCharacters(in: .whitespaces)
    }

    private static func findElement(
        in root: AXUIElement,
        role: String,
        where matches: (String) -> Bool
    ) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 60000 {
            let element = queue.removeFirst()
            visited += 1
            if (attribute(element, kAXRoleAttribute) as? String) == role,
               matches(label(of: element)) {
                return element
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }
}
