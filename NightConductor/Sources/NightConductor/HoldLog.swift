import Foundation

/// One edge in the hold timeline: `reason` is why the watch could not resume
/// (e.g. an expired sign-in), or "" when it is not being held.
struct HoldEvent: Codable, Equatable {
    let date: Date
    let reason: String
}

/// Durable record of why the watch was blocked, so "it didn't resume anything"
/// is a ten-second answer instead of a forensic one. `AppState` already computes
/// a live human-readable reason every tick (`Decision.reason`), but it only ever
/// lived in an in-memory `@Published` var — invisible the moment nobody was
/// looking at the popover, which is the whole point of an overnight watch.
/// Persisted like PowerLog, pruned to a week.
enum HoldLog {
    private static let key = "holdLog"
    private static let maxAge: TimeInterval = 7 * 86_400

    static func load(defaults: UserDefaults = .standard) -> [HoldEvent] {
        guard let data = defaults.data(forKey: key),
              let events = try? JSONDecoder().decode([HoldEvent].self, from: data)
        else { return [] }
        return events
    }

    private static func save(_ events: [HoldEvent], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: key) }
    }

    /// Record the current hold reason ("" means not held). No-op if unchanged
    /// from the last entry, so a steady state doesn't spam the log.
    static func record(reason: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var events = load(defaults: defaults)
        if events.last?.reason == reason { return }
        events.append(HoldEvent(date: date, reason: reason))
        let cutoff = date.addingTimeInterval(-maxAge)
        save(events.filter { $0.date >= cutoff }, defaults: defaults)
    }

    /// Close a span left open by a crash, at the last heartbeat, so a hold
    /// doesn't read as lasting until the next launch.
    static func closeOpenSpan(lastAlive: Date, defaults: UserDefaults = .standard) {
        let events = load(defaults: defaults)
        guard let last = events.last, !last.reason.isEmpty else { return }
        record(reason: "", at: max(lastAlive, last.date), defaults: defaults)
    }

    /// The hold reason with the most cumulative time within [since, now], and
    /// how long it totaled — the one line worth surfacing ("held 6h 40m:
    /// sign-in expired"). Spans with the SAME reason are summed even when not
    /// adjacent, so a cause that came and went more than once still reads as
    /// its true total instead of fragmenting across several short entries.
    static func longestHold(since: Date, now: Date = Date(),
                            defaults: UserDefaults = .standard) -> (reason: String, seconds: TimeInterval)? {
        let events = load(defaults: defaults).sorted { $0.date < $1.date }
        var totals: [String: TimeInterval] = [:]
        var open: (reason: String, start: Date)?
        func closeSpan(at end: Date) {
            guard let o = open, !o.reason.isEmpty else { return }
            let span = max(0, end.timeIntervalSince(max(o.start, since)))
            totals[o.reason, default: 0] += span
        }
        for event in events {
            closeSpan(at: event.date)
            open = event.reason.isEmpty ? nil : (event.reason, event.date)
        }
        closeSpan(at: now)
        return totals.max { $0.value < $1.value }.map { (reason: $0.key, seconds: $0.value) }
    }
}
