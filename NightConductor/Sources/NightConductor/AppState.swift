import Foundation
import SwiftUI

/// Orchestrates two independent loops:
///   • a fast **view loop** that refreshes the displayed usage and stalled
///     list every `scanInterval` — the local DB scan is essentially free,
///     so the list never shows sessions that already recovered, and
///   • a slower **resume loop** that, when armed + in-hours + budget-safe,
///     resumes stalled sessions one at a time, re-checking budget after each.
@MainActor
final class AppState: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var stalled: [StalledSession] = []
    @Published var decision: Decision?
    @Published var activity: [String] = []
    @Published var isWorking = false
    @Published var currentlyResuming: String?
    @Published var lastTick: Date?

    static let scanInterval: TimeInterval = 30        // local DB scan — cheap
    static let resumeInterval: TimeInterval = 600     // how often resumes are attempted
    // The usage API rate-limits rapid polling (429 within seconds), so the
    // 30s view loop reads it from cache and only re-fetches this often.
    static let usageRefreshInterval: TimeInterval = 180   // 3 min
    static let usageStaleAfter: TimeInterval = 900        // 15 min → treat as unavailable

    private var viewLoop: Task<Void, Never>?
    private var resumeLoop: Task<Void, Never>?
    private var lastUsageFetchAt: Date?
    private var lastInWindow: Bool?
    private var lastClaudeCodeScan: Date?
    private var cachedClaudeCode: [StalledSession] = []
    // Guards against the resume loop and the manual "Resume now" button
    // running a resume pass at the same time (which could double-run a
    // session and bypass the per-night caps).
    private var isResuming = false

    init(forScreenshots: Bool = false) {
        UserDefaults.standard.register(defaults: [
            "armed": true,
            "startHour": 23,
            "endHour": 7,
            "fiveHourCeiling": 85.0,
            "weeklyCeiling": 90.0,
        ])
        if forScreenshots { return } // inert state; data injected by caller
        // No accessibility prompt at launch — that nags on every relaunch.
        // The settings panel shows a button to grant it on the user's terms.
        start()
    }

    var armed: Bool {
        get { UserDefaults.standard.bool(forKey: "armed") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "armed")
            if newValue {
                Notifications.requestAuthorizationIfNeeded() // for the morning summary
            } else {
                PowerManager.preventIdleSleep(false) // let it sleep
            }
            log(newValue ? "Night watch armed" : "Night watch disarmed")
        }
    }

    func start() {
        viewLoop?.cancel()
        resumeLoop?.cancel()
        viewLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshView()
                try? await Task.sleep(for: .seconds(Self.scanInterval))
            }
        }
        resumeLoop = Task { [weak self] in
            while !Task.isCancelled {
                // The view loop already did the first refresh; wait one
                // resume interval before the first resume attempt.
                try? await Task.sleep(for: .seconds(Self.resumeInterval))
                await self?.resumeTick()
            }
        }
    }

    /// Stalled sessions from all sources, scanned off the main thread.
    /// Conductor + Claude Desktop are cheap and run every call; the terminal
    /// transcript scan is heavier, so it's throttled and cached. Standalone
    /// transcripts also contain Conductor / Claude Desktop sessions, so we
    /// dedupe by Claude session id — the richer in-app source wins.
    private func combinedStalled() async -> [StalledSession] {
        var all = await Task.detached(priority: .utility) { () -> [StalledSession] in
            var a: [StalledSession] = []
            if let conductor = try? ConductorDB.findStalledSessions() { a += conductor }
            a += ClaudeDesktopDB.findStalledSessions()
            return a
        }.value

        if Date().timeIntervalSince(lastClaudeCodeScan ?? .distantPast) > 120 {
            cachedClaudeCode = await Task.detached(priority: .utility) {
                ClaudeCodeDB.findStalledSessions()
            }.value
            lastClaudeCodeScan = Date()
        }
        let seen = Set(all.map(\.claudeSessionID))
        all += cachedClaudeCode.filter { !seen.contains($0.claudeSessionID) }
        return all
    }

    /// Refresh the display. `forceUsage` bypasses the cache (used right
    /// before a resume so budget gates see current data). Returns whether we
    /// have a fresh-enough usage reading to act on. Never resumes.
    @discardableResult
    func refreshView(forceUsage: Bool = false) async -> Bool {
        let config = PolicyConfig.fromDefaults()
        // Hold the Mac awake while the watch is armed and in its window.
        let inWindow = Policy.inActiveHours(
            hour: Calendar.current.component(.hour, from: Date()),
            start: config.startHour, end: config.endHour
        )
        PowerManager.preventIdleSleep(armed && inWindow)
        checkMorningSummary(inWindow: inWindow, config: config)

        stalled = await combinedStalled()
        defer { lastTick = Date() }

        // Re-fetch usage only when forced or the cache is older than the
        // refresh interval — the API 429s if polled every 30s.
        let age = Date().timeIntervalSince(lastUsageFetchAt ?? .distantPast)
        if forceUsage || usage == nil || age > Self.usageRefreshInterval {
            if let fresh = try? await UsageClient.fetchUsage() {
                usage = fresh
                lastUsageFetchAt = Date()
            } else if forceUsage {
                // About to resume but can't confirm budget → fail closed.
                if usage == nil {
                    decision = Decision(resume: false, reason: "Can't read usage — holding")
                }
                return false
            }
            // Not forced and fetch failed → keep the cached reading.
        }

        let freshness = Date().timeIntervalSince(lastUsageFetchAt ?? .distantPast)
        if let snapshot = usage, freshness <= Self.usageStaleAfter {
            decision = Policy.shouldResume(
                usage: snapshot, config: config, now: Date(), ignoreActiveHours: false
            )
            return true
        }
        decision = Decision(
            resume: false,
            reason: usage == nil ? "Checking usage…" : "Usage data is stale — holding"
        )
        return false
    }

    /// The budget-gated resume pass, run on the slower resume loop.
    func resumeTick() async {
        // Force a fresh read so the budget decision reflects current usage.
        guard await refreshView(forceUsage: true) else { return }
        let config = PolicyConfig.fromDefaults()
        guard armed, decision?.resume == true, !stalled.isEmpty else { return }
        await resumeStalledSessions(config: config, manual: false)
    }

    /// Manual "Resume now": refresh, then resume ignoring the active-hours
    /// gate (the user is present) but never the budget gates.
    func tick(manual: Bool) async {
        isWorking = true
        defer { isWorking = false }
        // Fail closed: a manual resume needs a fresh, confirmed reading.
        guard await refreshView(forceUsage: true) else { return }
        let config = PolicyConfig.fromDefaults()
        if let snapshot = usage {
            decision = Policy.shouldResume(
                usage: snapshot, config: config, now: Date(), ignoreActiveHours: manual
            )
        }
        guard armed || manual, decision?.resume == true, !stalled.isEmpty else { return }
        await resumeStalledSessions(config: config, manual: manual)
    }

    var uiResumeEnabled: Bool {
        UserDefaults.standard.object(forKey: "uiResume") == nil
            || UserDefaults.standard.bool(forKey: "uiResume")
    }

    private func resumeStalledSessions(config: PolicyConfig, manual: Bool) async {
        guard !isResuming else { return } // never run two passes at once
        isResuming = true
        defer { isResuming = false }

        let useUI = uiResumeEnabled && UIResumer.hasAccessibilityPermission

        // Locating the claude CLI may spawn a login shell, so do it off the
        // main thread and only when headless is actually needed (UI mode
        // defers it until a UI resume fails).
        var resolvedClaudePath: String??  // nil = not looked up yet
        func claudeBinary() async -> String? {
            if let cached = resolvedClaudePath { return cached }
            let found = await Task.detached(priority: .utility) {
                Resumer.findClaudeBinary()
            }.value
            resolvedClaudePath = .some(found)
            return found
        }
        var night = NightLedger.load(startHour: config.startHour)

        for session in stalled {
            guard night.count(for: session.sessionID) < config.maxResumesPerSession else {
                log("Skipping \(session.title): nightly retry cap reached")
                continue
            }
            guard night.total < config.maxSessionsPerNight else {
                log("Nightly cap reached (\(config.maxSessionsPerNight) resumes)")
                break
            }

            currentlyResuming = session.title
            log("▶ Resuming \(session.title) [\(session.source.label)]")
            var result = ResumeResult(ok: false, detail: "not attempted")
            var handedToApp = false // resumed inside the host app — chat in sync

            switch session.source {
            case .claudeDesktop:
                // Faithful, in-sandbox resume only — no headless fallback,
                // since a host resume would drop Claude Desktop's sandbox.
                if ClaudeDesktopResumer.hasAccessibilityPermission {
                    result = await Task.detached(priority: .utility) {
                        ClaudeDesktopResumer.resume(session: session)
                    }.value
                    handedToApp = result.ok
                } else {
                    result = ResumeResult(ok: false, detail: "needs Accessibility access")
                }
            case .conductor:
                if useUI {
                    result = await Task.detached(priority: .utility) {
                        UIResumer.resume(session: session)
                    }.value
                    handedToApp = result.ok
                    if !result.ok {
                        log("↻ UI resume failed (\(result.detail)) — falling back to headless")
                    }
                }
                if !result.ok, let claudePath = await claudeBinary() {
                    result = await Task.detached(priority: .utility) {
                        Resumer.resume(session: session, claudePath: claudePath, config: config)
                    }.value
                }
            case .claudeCode:
                // Terminal sessions aren't sandboxed → headless is faithful.
                if let claudePath = await claudeBinary() {
                    result = await Task.detached(priority: .utility) {
                        Resumer.resume(session: session, claudePath: claudePath, config: config)
                    }.value
                } else {
                    result = ResumeResult(ok: false, detail: "claude CLI not found")
                }
            }

            currentlyResuming = nil
            if handedToApp {
                log("✓ \(session.title) resumed inside \(session.source.label) — chat stays in sync")
            } else {
                log(result.ok ? "✓ \(session.title) finished a run" : "✗ \(session.title): \(result.detail)")
            }

            night = night.recording(session.sessionID)
            night.save()
            if result.ok {
                ResumeHistory.record(ResumeEvent(
                    date: Date(), title: session.title,
                    kind: session.kind == .transient ? "transient" : "usage_limit",
                    inConductor: handedToApp
                ))
            }

            // An in-app resume hands off and returns immediately, so its cost
            // isn't measurable yet. One per tick keeps the budget honest.
            if handedToApp {
                log("Handed to \(session.source.label) — next session at the next resume cycle")
                break
            }

            // A long agentic run can eat a big chunk of the 5h window on its
            // own — re-check the budget before touching the next session.
            guard let fresh = try? await UsageClient.fetchUsage() else {
                log("⚠️ Usage re-check failed — stopping")
                break
            }
            usage = fresh
            let next = Policy.shouldResume(
                usage: fresh, config: config, now: Date(), ignoreActiveHours: manual
            )
            decision = next
            if !next.resume {
                log("Pausing: \(next.reason)")
                break
            }
        }
        stalled = await combinedStalled()
    }

    /// When the watch window ends (the user's wake hour), post one morning
    /// summary if anything was resumed overnight — at most once per night.
    private func checkMorningSummary(inWindow: Bool, config: PolicyConfig) {
        defer { lastInWindow = inWindow }
        guard let was = lastInWindow, was, !inWindow else { return } // just ended
        let nightKey = NightLedger.currentKey(startHour: config.startHour)
        guard UserDefaults.standard.string(forKey: "lastSummaryNight") != nightKey else { return }
        let count = NightLedger.load(startHour: config.startHour).total
        UserDefaults.standard.set(nightKey, forKey: "lastSummaryNight")
        guard count > 0 else { return }
        let latest = ResumeHistory.load().sorted { $0.date > $1.date }.first?.title
        Notifications.postMorningSummary(count: count, sampleTitle: latest)
        log("🌅 Good morning — \(count) resumed overnight")
    }

    private func log(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        activity.insert("\(stamp)  \(message)", at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}

/// Per-night resume counts, persisted so relaunching the app can't bypass
/// the caps. A "night" is keyed by the date its active window started.
struct NightLedger {
    let key: String
    let counts: [String: Int]

    var total: Int { counts.values.reduce(0, +) }

    func count(for sessionID: String) -> Int { counts[sessionID] ?? 0 }

    func recording(_ sessionID: String) -> NightLedger {
        var updated = counts
        updated[sessionID, default: 0] += 1
        return NightLedger(key: key, counts: updated)
    }

    static func currentKey(now: Date = Date(), startHour: Int, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let anchor = hour >= startHour ? now : now.addingTimeInterval(-86_400)
        // Format the date in the SAME (local) calendar used for the hour.
        // `.iso8601` formats in UTC, which in negative-offset zones rolls
        // the date over at local midnight and silently resets the caps.
        let c = calendar.dateComponents([.year, .month, .day], from: anchor)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func load(startHour: Int, defaults: UserDefaults = .standard) -> NightLedger {
        let key = currentKey(startHour: startHour)
        guard defaults.string(forKey: "nightKey") == key,
              let counts = defaults.dictionary(forKey: "nightCounts") as? [String: Int]
        else {
            return NightLedger(key: key, counts: [:]) // new night, fresh budget
        }
        return NightLedger(key: key, counts: counts)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(key, forKey: "nightKey")
        defaults.set(counts, forKey: "nightCounts")
    }
}
