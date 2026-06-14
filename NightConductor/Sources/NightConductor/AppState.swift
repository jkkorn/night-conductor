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

    static let scanInterval: TimeInterval = 30     // refresh the displayed list
    static let resumeInterval: TimeInterval = 600  // how often resumes are attempted

    private var viewLoop: Task<Void, Never>?
    private var resumeLoop: Task<Void, Never>?
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
        // UI resume is on by default; if the permission is missing, show
        // the system prompt right away so setup is one click at launch.
        if uiResumeEnabled, !UIResumer.hasAccessibilityPermission {
            UIResumer.requestPermission()
        }
        start()
    }

    var armed: Bool {
        get { UserDefaults.standard.bool(forKey: "armed") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "armed")
            if !newValue { PowerManager.preventIdleSleep(false) } // let it sleep
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

    /// Cheap, frequent refresh of what the popover shows. Never resumes.
    /// The stalled list comes from a local DB read, so it stays fresh even
    /// when the network is down (usage failure holds, but doesn't wipe it).
    /// Returns whether *fresh* usage was obtained — callers must not resume
    /// on a stale snapshot (fail closed).
    @discardableResult
    func refreshView() async -> Bool {
        let config = PolicyConfig.fromDefaults()
        // Hold the Mac awake while the watch is armed and in its window, so
        // every tick and resume actually runs (no privileges needed).
        let inWindow = Policy.inActiveHours(
            hour: Calendar.current.component(.hour, from: Date()),
            start: config.startHour, end: config.endHour
        )
        PowerManager.preventIdleSleep(armed && inWindow)

        if let fresh = try? ConductorDB.findStalledSessions() {
            stalled = fresh
        }
        defer { lastTick = Date() }
        do {
            usage = try await UsageClient.fetchUsage()
        } catch {
            decision = Decision(resume: false, reason: "Can't read usage — holding")
            return false
        }
        if let snapshot = usage {
            decision = Policy.shouldResume(
                usage: snapshot, config: config, now: Date(), ignoreActiveHours: false
            )
        }
        return true
    }

    /// The budget-gated resume pass, run on the slower resume loop.
    func resumeTick() async {
        await refreshView()
        let config = PolicyConfig.fromDefaults()
        guard armed, decision?.resume == true, !stalled.isEmpty else { return }
        await resumeStalledSessions(config: config, manual: false)
    }

    /// Manual "Resume now": refresh, then resume ignoring the active-hours
    /// gate (the user is present) but never the budget gates.
    func tick(manual: Bool) async {
        isWorking = true
        defer { isWorking = false }
        // Fail closed: if we couldn't get fresh usage, refreshView already
        // set a holding decision — don't recompute against a stale snapshot.
        guard await refreshView() else { return }
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
        if !useUI, await claudeBinary() == nil {
            log("⚠️ claude CLI not found — install Claude Code first")
            return
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
            log("▶ Resuming \(session.title)")
            var result = ResumeResult(ok: false, detail: "not attempted")
            var resumedInsideConductor = false
            if useUI {
                result = await Task.detached(priority: .utility) {
                    UIResumer.resume(session: session)
                }.value
                resumedInsideConductor = result.ok
                if !result.ok {
                    log("↻ UI resume failed (\(result.detail)) — falling back to headless")
                }
            }
            if !result.ok, let claudePath = await claudeBinary() {
                result = await Task.detached(priority: .utility) {
                    Resumer.resume(session: session, claudePath: claudePath, config: config)
                }.value
            }
            currentlyResuming = nil
            if resumedInsideConductor {
                log("✓ \(session.title) resumed inside Conductor — chat stays in sync")
            } else {
                log(result.ok ? "✓ \(session.title) finished a run" : "✗ \(session.title): \(result.detail)")
            }

            night = night.recording(session.sessionID)
            night.save()

            // A UI resume hands the run to Conductor and returns immediately,
            // so its cost isn't measurable yet. One per tick keeps the
            // budget checks honest; the next tick handles the next session.
            if resumedInsideConductor {
                log("Handed to Conductor — next session at the next resume cycle")
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
        stalled = (try? ConductorDB.findStalledSessions()) ?? []
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
