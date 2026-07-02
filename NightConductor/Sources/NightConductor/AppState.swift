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
    @Published var update: UpdateChecker.Release?   // set when a newer release exists

    static let scanInterval: TimeInterval = 30        // local DB scan — cheap
    static let resumeInterval: TimeInterval = 600     // how often resumes are attempted
    // The usage API rate-limits rapid polling (429 within seconds), so the
    // 30s view loop reads it from cache and only re-fetches this often.
    static let usageRefreshInterval: TimeInterval = 180   // 3 min
    static let usageStaleAfter: TimeInterval = 900        // 15 min → treat as unavailable
    static let maxAttemptsPerPass = 8                     // bound a pass when sessions fail
    static let transientCooldown: TimeInterval = 300      // 5 min before retrying a server rate-limit
    static let resumeCooldown: TimeInterval = 600         // 10 min before re-firing the SAME session
    static let minUsageAttemptGap: TimeInterval = 20      // floor between /usage calls, even forced ones

    private var viewLoop: Task<Void, Never>?
    private var resumeLoop: Task<Void, Never>?
    private var lastUsageFetchAt: Date?
    private var lastUsageAttemptAt: Date?  // every attempt (success or fail), to floor the rate
    private var usageBackoffUntil: Date?   // set on a 429, grows exponentially
    private var usageBackoffStep = 0
    private var usageJitter: Double = 0     // randomized offset so polls desync
    private var signInExpired = false       // Claude Code token expired → tell the user
    private var lastInWindow: Bool?
    private var lastKeepAwake = false  // last computed keep-awake state, to log real transitions
    private var lastClaudeCodeScan: Date?
    private var cachedClaudeCode: [StalledSession] = []
    private var lastResumedAt: [String: Date] = [:]  // ledgerKey -> last resume, to space re-fires
    // Guards against the resume loop and the manual "Resume now" button
    // running a resume pass at the same time (which could double-run a
    // session and bypass the per-night caps).
    private var isResuming = false
    let isScreenshot: Bool  // true → inert demo state; never hit the live API

    init(forScreenshots: Bool = false) {
        isScreenshot = forScreenshots
        UserDefaults.standard.register(defaults: [
            "armed": true,
            "startHour": 23,
            "endHour": 7,
            "fiveHourCeiling": 85.0,
            "weeklyCeiling": 90.0,
            "resumePaceMinutes": 10.0,
            "aroundTheClock": false,
        ])
        if forScreenshots { return } // inert state; data injected by caller
        usageJitter = Double(Int.random(in: 0...45)) // desync the very first poll too
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

    /// When on, the watch resumes whenever there's budget (not just the night
    /// window) and keeps the Mac awake while armed, so it's always ready to
    /// resume the moment your limit resets, any time of day.
    var aroundTheClock: Bool { UserDefaults.standard.bool(forKey: "aroundTheClock") }

    func start() {
        viewLoop?.cancel()
        resumeLoop?.cancel()
        // Reliability: default to launching at login (first launch only), so a
        // restart never leaves the watch silently dead. And close any keep-awake
        // span left open by a previous run that was killed while holding the Mac
        // awake, so the awake total stays honest.
        LoginItem.ensureDefaultOnFirstLaunch()
        if let lastAlive = UserDefaults.standard.object(forKey: "lastHeartbeat") as? Date {
            PowerLog.closeOpenSpan(lastAlive: lastAlive)
            HoldLog.closeOpenSpan(lastAlive: lastAlive)
        }
        Task { [weak self] in await self?.refreshUsage(force: true) } // populate meters once at launch
        Task { [weak self] in await self?.checkForUpdates() }         // notify if a newer release exists
        viewLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshView()
                try? await Task.sleep(for: .seconds(Self.scanInterval))
            }
        }
        resumeLoop = Task { [weak self] in
            while !Task.isCancelled {
                // Jittered gap between resume attempts so the night's resumes
                // spread out (and don't sync to a robotic beat). Pace is the
                // user's setting (clamped); jitter is +/-40%.
                let pace = Self.paceSeconds(UserDefaults.standard.object(forKey: "resumePaceMinutes") as? Double)
                let gap = pace * Double.random(in: 0.6...1.4)
                try? await Task.sleep(for: .seconds(gap))
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

    /// Cheap 30s refresh: scan stalled sessions and recompute the decision
    /// from the CACHED usage. Deliberately does NOT hit the usage API — that
    /// endpoint is rate-limited, so we fetch it lazily (before a resume, when
    /// the popover opens, at launch) via `refreshUsage`.
    @discardableResult
    func refreshView() async -> Bool {
        let config = PolicyConfig.fromDefaults()
        let inWindow = Policy.inActiveHours(
            hour: Calendar.current.component(.hour, from: Date()),
            start: config.startHour, end: config.endHour
        )
        // Around-the-clock keeps the Mac awake whenever armed, so it's ready to
        // resume the instant a limit resets; otherwise only during the window.
        let keepAwake = armed && (aroundTheClock || inWindow)
        if keepAwake != lastKeepAwake {
            PowerLog.record(awake: keepAwake) // durable proof of when we held the Mac awake
            lastKeepAwake = keepAwake
        }
        PowerManager.preventIdleSleep(keepAwake)
        UserDefaults.standard.set(Date(), forKey: "lastHeartbeat") // liveness proof
        checkMorningSummary(inWindow: inWindow, config: config)
        stalled = await combinedStalled()
        lastTick = Date()
        return recomputeDecision(config: config)
    }

    /// Check GitHub Releases for a newer version. Throttled to once every 6h
    /// (persisted across launches) so it can't rate-limit GitHub; a manual
    /// check from settings passes `force`. Sets `update` when one is available.
    func checkForUpdates(force: Bool = false) async {
        guard !isScreenshot else { return }
        let now = Date()
        if !force, let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date,
           now.timeIntervalSince(last) < UpdateChecker.minCheckInterval {
            return
        }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        guard let latest = await UpdateChecker.fetchLatest() else { return }
        update = UpdateChecker.isNewer(latest.version, than: UpdateChecker.currentVersion)
            ? latest : nil
    }

    /// Fetch usage with three guards against rate-limiting the shared `/usage`
    /// endpoint: a cache window, randomized jitter (so we don't sync up with
    /// Conductor / Claude Code / Claude Desktop polling the same endpoint),
    /// and exponential backoff on a 429. Returns whether usage is fresh
    /// enough to act on.
    @discardableResult
    func refreshUsage(force: Bool) async -> Bool {
        let now = Date()
        let inBackoff = (usageBackoffUntil.map { now < $0 }) ?? false
        let age = now.timeIntervalSince(lastUsageFetchAt ?? .distantPast)
        let attemptAge = now.timeIntervalSince(lastUsageAttemptAt ?? .distantPast)
        let threshold = Self.usageRefreshInterval + usageJitter
        if Self.shouldFetchUsage(
            force: force, hasUsage: usage != nil, fresh: usageIsFresh(now),
            inBackoff: inBackoff, age: age, threshold: threshold,
            attemptAge: attemptAge, minAttemptGap: Self.minUsageAttemptGap
        ) {
            lastUsageAttemptAt = now
            do {
                usage = try await UsageClient.fetchUsage()
                lastUsageFetchAt = Date()
                usageBackoffUntil = nil
                usageBackoffStep = 0
                signInExpired = false
                usageJitter = Double(Int.random(in: 0...45)) // re-roll for next time
            } catch let error as UsageError where error.isRateLimited {
                let delays = [300.0, 600.0, 1200.0, 1800.0] // 5, 10, 20, 30 min
                usageBackoffStep = min(usageBackoffStep + 1, delays.count)
                usageBackoffUntil = now.addingTimeInterval(delays[usageBackoffStep - 1])
                log("Usage rate-limited, backing off \(Int(delays[usageBackoffStep - 1] / 60))m")
            } catch let error as UsageError where error.isSignInExpired {
                // The fetch was skipped/refused because the Claude Code token
                // expired. No backoff (the call is cheap and we never hit the
                // network) — just surface it so the user knows to refresh.
                signInExpired = true
            } catch {
                // transient / network — keep the cached reading
            }
        }
        _ = recomputeDecision(config: PolicyConfig.fromDefaults())
        return usageIsFresh(now)
    }

    /// Whether to attempt a usage fetch. The 429 backoff throttles polling of
    /// data we ALREADY have fresh, but must never strand us on a stale reading:
    /// a stale "you're maxed" value makes us hold all night when there's really
    /// headroom (max backoff is 30m, staleness is 15m, so a backoff alone
    /// guarantees such a window). Once the cached data is stale, always retry.
    nonisolated static func shouldFetchUsage(
        force: Bool, hasUsage: Bool, fresh: Bool,
        inBackoff: Bool, age: TimeInterval, threshold: TimeInterval,
        attemptAge: TimeInterval = .greatestFiniteMagnitude, minAttemptGap: TimeInterval = 0
    ) -> Bool {
        // Floor the call rate: never fetch more than once per minAttemptGap,
        // even a forced one, so rapid popover opens can't fire a /usage call per
        // open. This holds even before the first SUCCESS — a failed first fetch
        // (429, signed out, network) leaves `usage` nil, and that must NOT exempt
        // the floor. A true first load (never attempted) has attemptAge of
        // .greatestFiniteMagnitude, so it stays exempt and the meters populate.
        if attemptAge < minAttemptGap { return false }
        // The 429 backoff throttles polling, but must never strand us on a STALE
        // reading (a stale "you're maxed" value would hold all night). So it
        // blocks when the data is fresh OR when we have no reading at all, and
        // stands down only to recover a stale one.
        let blockedByBackoff = inBackoff && (fresh || !hasUsage)
        return !blockedByBackoff && (force || !hasUsage || age > threshold)
    }

    /// Seconds between resume attempts from the user's "resume pace" setting,
    /// clamped to a sane 5 to 20 minute range (jitter is added at the call site).
    nonisolated static func paceSeconds(_ minutes: Double?) -> TimeInterval {
        min(20, max(5, minutes ?? 10)) * 60
    }

    /// Stop a resume pass after a success only when it's NOT manual: an auto
    /// pass resumes one session per tick to spread the night's work, while a
    /// manual "Resume now" resumes the whole list.
    nonisolated static func shouldStopPass(manual: Bool, handedToApp: Bool, resultOK: Bool) -> Bool {
        !manual && (handedToApp || resultOK)
    }

    /// Whether the auto loop should resume this session now. Pinned sessions run
    /// around the clock; the rest only inside the night window (`nightOK`). A
    /// session stalled on a TRANSIENT server rate-limit ("temporarily limiting
    /// requests") gets a cool-down first, so the loop never bounces straight
    /// back into the same limit and re-triggers it. Manual "Resume now" skips
    /// this (it doesn't run through here).
    nonisolated static func autoResumeEligible(
        _ session: StalledSession, nightOK: Bool, pins: Set<String>, now: Date,
        lastResumedAt: Date? = nil
    ) -> Bool {
        guard nightOK || pins.contains(session.claudeSessionID) else { return false }
        if session.kind == .transient, let at = session.stalledAt,
           now.timeIntervalSince(at) < transientCooldown { return false }
        // Don't re-fire the SAME session too soon. A headless resume doesn't
        // clear the host app's stalled flag, so without this the loop would
        // re-resume it every tick and pile inference onto the rate limit.
        if let last = lastResumedAt, now.timeIntervalSince(last) < resumeCooldown { return false }
        return true
    }

    func usageIsFresh(_ now: Date = Date()) -> Bool {
        guard usage != nil, let at = lastUsageFetchAt else { return false }
        return now.timeIntervalSince(at) <= Self.usageStaleAfter
    }

    @discardableResult
    private func recomputeDecision(config: PolicyConfig) -> Bool {
        let now = Date()
        if let snapshot = usage, usageIsFresh(now) {
            let result = Policy.shouldResume(
                usage: snapshot, config: config, now: now, ignoreActiveHours: false
            )
            decision = result
            // .standingBy is the intentional daytime rest, not a problem — only
            // .holding is worth a durable record of "resume was blocked, and why."
            HoldLog.record(reason: (!result.resume && result.state == .holding) ? result.reason : "")
            return true
        }
        let reason: String
        if signInExpired {
            reason = "Claude sign-in expired. Open Claude Code or Conductor to refresh"
        } else if usage == nil {
            reason = "Checking usage…"
        } else {
            reason = "Usage data is stale, holding"
        }
        decision = Decision(resume: false, reason: reason, state: .checking)
        // Unlike .holding above, .checking here can be a brief, normal blip (a
        // fetch in flight) or the exact multi-hour failure this log exists to
        // catch (e.g. a sign-in that stayed expired all night). Recording it
        // is harmless either way: HoldLog dedupes unchanged reasons, so a
        // fast-clearing blip collapses to one short-lived entry.
        HoldLog.record(reason: reason)
        return false
    }

    /// The budget-gated resume pass, run on the slower resume loop.
    func resumeTick() async {
        await refreshView()
        // Fresh usage required to auto-resume (respects backoff; fail closed).
        guard await refreshUsage(force: true) else { return }
        guard armed, let usage else { return }
        let config = PolicyConfig.fromDefaults()
        let now = Date()
        // Never overspend. But resume PINNED sessions around the clock, and
        // every stalled session during the night window.
        guard Policy.budgetAllows(usage: usage, config: config, now: now).resume else { return }
        // Around-the-clock resumes whenever budget allows (the guard above),
        // bypassing the night window. Otherwise only inside the watch window.
        let nightOK = aroundTheClock || Policy.shouldResume(usage: usage, config: config, now: now).resume
        let pins = pinnedIDs
        let eligible = stalled.filter {
            Self.autoResumeEligible($0, nightOK: nightOK, pins: pins, now: now,
                                    lastResumedAt: lastResumedAt[$0.ledgerKey])
        }
        guard !eligible.isEmpty else { return }
        await resumeStalledSessions(sessions: eligible, config: config, manual: false)
    }

    /// Manual "Resume now": your explicit call — resume regardless of our
    /// active-hours and budget gates (only Anthropic's real limit can stop a
    /// resume, and that's reported per-session). Crucially it does NOT depend
    /// on a usage fetch, which can itself be rate-limited.
    func tick(manual: Bool) async {
        isWorking = true
        defer { isWorking = false }
        await refreshView() // best-effort display refresh; never gates the resume
        await refreshUsage(force: false) // freshen the meters (throttled), non-blocking
        guard !stalled.isEmpty else { log("Nothing stalled to resume right now"); return }
        let config = PolicyConfig.fromDefaults()
        await resumeStalledSessions(sessions: stalled, config: config, manual: manual)
    }

    var uiResumeEnabled: Bool {
        UserDefaults.standard.object(forKey: "uiResume") == nil
            || UserDefaults.standard.bool(forKey: "uiResume")
    }

    // MARK: - Per-session auto-resume pins

    // Pinned sessions auto-resume around the clock (budget permitting), not
    // just during the night window — so the day's stalls aren't stuck waiting.
    private let pinnedKey = "pinnedSessions"

    var pinnedIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
    }

    func isPinned(_ session: StalledSession) -> Bool {
        pinnedIDs.contains(session.claudeSessionID)
    }

    func togglePin(_ session: StalledSession) {
        objectWillChange.send()
        var ids = pinnedIDs
        let nowPinned = !ids.contains(session.claudeSessionID)
        if nowPinned { ids.insert(session.claudeSessionID) }
        else { ids.remove(session.claudeSessionID) }
        UserDefaults.standard.set(Array(ids), forKey: pinnedKey)
        log(nowPinned ? "📌 Auto-resume on: \(session.title)" : "Auto-resume off: \(session.title)")
    }

    private func resumeStalledSessions(
        sessions: [StalledSession], config: PolicyConfig, manual: Bool
    ) async {
        guard !isResuming else {
            if manual { log("Busy resuming, try again in a moment") } // don't drop silently
            return
        } // never run two passes at once
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
        var attemptsThisPass = 0 // bound a pass when many sessions fail in a row

        for session in sessions {
            // Per-night caps protect the unattended loop; a manual click is
            // your explicit call, so it bypasses them.
            if !manual {
                guard night.total < config.maxSessionsPerNight else {
                    log("Nightly cap reached (\(config.maxSessionsPerNight) resumes)")
                    break
                }
                guard attemptsThisPass < Self.maxAttemptsPerPass else { break } // try again next tick
                guard night.count(for: session.ledgerKey) < config.maxResumesPerSession else {
                    continue // already resumed this one enough tonight
                }
                guard night.failureCount(for: session.ledgerKey) < config.maxResumesPerSession else {
                    continue // keeps failing tonight — stop hammering it
                }
            }
            attemptsThisPass += 1

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
                        log("↻ UI resume failed (\(result.detail)), falling back to headless")
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
                log("✓ \(session.title) resumed inside \(session.source.label), chat stays in sync")
            } else {
                log(result.ok ? "✓ \(session.title) finished a run" : "✗ \(session.title): \(result.detail)")
            }

            // A manual click bypasses the cap CHECK, so it must not spend the
            // cap BUDGET either — the nightly ledger exists to bound the
            // UNATTENDED loop, not your explicit choices. Manual still logs to
            // history (for the activity log / stat card).
            if result.ok {
                lastResumedAt[session.ledgerKey] = Date() // space out re-firing this session
                ResumeHistory.record(ResumeEvent(
                    date: Date(), title: session.title,
                    kind: session.kind == .transient ? "transient" : "usage_limit",
                    inConductor: handedToApp
                ))
            }
            if !manual {
                // Only a SUCCESS spends the night's budget. A failure is tracked
                // separately so a transient blip can't burn the per-night /
                // per-session caps and disable the whole night's watch.
                night = result.ok
                    ? night.recordingSuccess(session.ledgerKey)
                    : night.recordingFailure(session.ledgerKey)
                night.save()
            }

            // Spread it out: an AUTO pass resumes ONE session per tick so the
            // night's budget trickles out instead of bursting; the next tick
            // takes the next session. A MANUAL pass ("Resume now") keeps going
            // through the whole list, so clicking it resumes everything.
            if Self.shouldStopPass(manual: manual, handedToApp: handedToApp, resultOK: result.ok) {
                log(handedToApp
                    ? "Handed to \(session.source.label), next session shortly"
                    : "Resumed \(session.title), spacing out, next at the next cycle")
                break
            }
            // Manual passes, and failed auto attempts, continue to the next.
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
        log("🌅 Good morning, \(count) resumed overnight")
    }

    private func log(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        activity.insert("\(stamp)  \(message)", at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}

/// Per-night ledger, persisted so relaunching can't bypass the caps. A
/// "night" is keyed by the date its active window started. Successes and
/// failures are tracked separately: successes gate the spend caps, while
/// failures only stop us from retrying a genuinely broken session forever —
/// a transient blip must NOT consume the night's budget.
struct NightLedger {
    let key: String
    let counts: [String: Int]    // successful resumes per session
    let failures: [String: Int]  // failed attempts per session

    init(key: String, counts: [String: Int] = [:], failures: [String: Int] = [:]) {
        self.key = key
        self.counts = counts
        self.failures = failures
    }

    var total: Int { counts.values.reduce(0, +) } // successful resumes tonight

    func count(for sessionID: String) -> Int { counts[sessionID] ?? 0 }
    func failureCount(for sessionID: String) -> Int { failures[sessionID] ?? 0 }

    func recordingSuccess(_ sessionID: String) -> NightLedger {
        var updated = counts
        updated[sessionID, default: 0] += 1
        return NightLedger(key: key, counts: updated, failures: failures)
    }

    func recordingFailure(_ sessionID: String) -> NightLedger {
        var updated = failures
        updated[sessionID, default: 0] += 1
        return NightLedger(key: key, counts: counts, failures: updated)
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
        guard defaults.string(forKey: "nightKey") == key else {
            return NightLedger(key: key) // new night, fresh budget
        }
        return NightLedger(
            key: key,
            counts: defaults.dictionary(forKey: "nightCounts") as? [String: Int] ?? [:],
            failures: defaults.dictionary(forKey: "nightFailures") as? [String: Int] ?? [:]
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(key, forKey: "nightKey")
        defaults.set(counts, forKey: "nightCounts")
        defaults.set(failures, forKey: "nightFailures")
    }
}
