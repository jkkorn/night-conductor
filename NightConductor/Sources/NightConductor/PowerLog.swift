import Foundation

/// One edge in the keep-awake timeline: the moment the watch began holding the
/// Mac awake (`awake == true`) or released it (`false`).
struct PowerEvent: Codable, Equatable {
    let date: Date
    let awake: Bool
}

/// Durable record of when the watch actually held the Mac awake, so the app can
/// *prove* it was working overnight instead of just claiming it. Persisted like
/// the resume history and pruned to a week.
enum PowerLog {
    private static let key = "powerLog"
    private static let maxAge: TimeInterval = 7 * 86_400

    static func load(defaults: UserDefaults = .standard) -> [PowerEvent] {
        guard let data = defaults.data(forKey: key),
              let events = try? JSONDecoder().decode([PowerEvent].self, from: data)
        else { return [] }
        return events
    }

    private static func save(_ events: [PowerEvent], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: key) }
    }

    /// Append a real transition. No-op repeats (two "awake" in a row) are
    /// dropped so the log holds only genuine edges.
    static func record(awake: Bool, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var events = load(defaults: defaults)
        if events.last?.awake == awake { return }
        events.append(PowerEvent(date: date, awake: awake))
        let cutoff = date.addingTimeInterval(-maxAge)
        save(events.filter { $0.date >= cutoff }, defaults: defaults)
    }

    /// If the app died while still holding the Mac awake, the log ends on an
    /// open "awake" edge. Close it at `lastAlive` (the last heartbeat) so the
    /// awake total reflects reality, not the idle gap until the next launch.
    static func closeOpenSpan(lastAlive: Date, defaults: UserDefaults = .standard) {
        let events = load(defaults: defaults)
        guard let last = events.last, last.awake else { return }
        record(awake: false, at: max(lastAlive, last.date), defaults: defaults)
    }

    /// Total seconds the Mac was held awake within [since, now], pairing each
    /// "awake" edge with the next release (or `now` if it is still open).
    static func awakeSeconds(since: Date, now: Date = Date(),
                             defaults: UserDefaults = .standard) -> TimeInterval {
        let events = load(defaults: defaults).sorted { $0.date < $1.date }
        var total: TimeInterval = 0
        var open: Date?
        for event in events {
            if event.awake {
                if open == nil { open = event.date }
            } else if let start = open {
                total += clampedSpan(start, event.date, since: since)
                open = nil
            }
        }
        if let start = open { total += clampedSpan(start, now, since: since) }
        return total
    }

    private static func clampedSpan(_ start: Date, _ end: Date, since: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(max(start, since)))
    }
}
