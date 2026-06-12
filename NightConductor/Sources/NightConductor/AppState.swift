import Foundation
import SwiftUI

/// Orchestrates the watch loop: every 10 minutes fetch usage, evaluate the
/// budget policy, and (when armed, in-hours, and budget-safe) resume stalled
/// sessions one at a time, re-checking the budget after each.
@MainActor
final class AppState: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var stalled: [StalledSession] = []
    @Published var decision: Decision?
    @Published var activity: [String] = []
    @Published var isWorking = false
    @Published var currentlyResuming: String?
    @Published var lastTick: Date?

    static let tickInterval: TimeInterval = 600

    private var loop: Task<Void, Never>?

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
            log(newValue ? "Night watch armed" : "Night watch disarmed")
        }
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(manual: false)
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
    }

    /// One scheduling tick. Manual ticks (the "Resume now" button) skip the
    /// active-hours gate but never the budget gates.
    func tick(manual: Bool) async {
        isWorking = true
        defer {
            isWorking = false
            lastTick = Date()
        }

        let config = PolicyConfig.fromDefaults()
        do {
            usage = try await UsageClient.fetchUsage()
        } catch {
            decision = Decision(resume: false, reason: error.localizedDescription)
            log("⚠️ Cannot read usage — holding (fail closed)")
            return // no usage data -> never resume
        }
        guard let snapshot = usage else { return }

        decision = Policy.shouldResume(
            usage: snapshot, config: config, now: Date(), ignoreActiveHours: manual
        )
        stalled = (try? ConductorDB.findStalledSessions()) ?? []

        guard armed || manual else { return }
        guard decision?.resume == true, !stalled.isEmpty else { return }
        await resumeStalledSessions(config: config, manual: manual)
    }

    var uiResumeEnabled: Bool {
        UserDefaults.standard.object(forKey: "uiResume") == nil
            || UserDefaults.standard.bool(forKey: "uiResume")
    }

    private func resumeStalledSessions(config: PolicyConfig, manual: Bool) async {
        let useUI = uiResumeEnabled && UIResumer.hasAccessibilityPermission
        let claudePath = Resumer.findClaudeBinary()
        if !useUI && claudePath == nil {
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
            if !result.ok, let claudePath {
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
                log("Next stalled session at the next check (10 min)")
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
        return anchor.formatted(.iso8601.year().month().day())
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
