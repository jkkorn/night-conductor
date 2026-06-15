import Foundation

struct UsageWindow: Equatable {
    let utilization: Double // 0..100
    let resetsAt: Date?
}

struct UsageSnapshot: Equatable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let fetchedAt: Date
}

/// Why a session stalled — both arrive as HTTP 429 but mean different things.
enum StallKind: Equatable {
    case usageLimit   // "You've hit your usage/session limit · resets …"
    case transient    // "Server is temporarily limiting requests (not your usage limit)"

    /// Classify from the error result text.
    static func classify(_ text: String) -> StallKind {
        let t = text.lowercased()
        if t.contains("temporarily limiting") || t.contains("not your usage limit") {
            return .transient
        }
        return .usageLimit
    }

    var shortLabel: String {
        switch self {
        case .usageLimit: return "usage limit"
        case .transient: return "rate-limited"
        }
    }

    var icon: String {
        switch self {
        case .usageLimit: return "pause.circle.fill"
        case .transient: return "bolt.horizontal.circle.fill"
        }
    }
}

/// Which app the stalled session belongs to. Resume routing differs:
/// Conductor resumes via its Retry (with a headless fallback); Claude
/// Desktop resumes only via its own Retry (its agents run sandboxed, so a
/// host-side headless resume would change the security model).
enum SessionSource: String, Equatable {
    case conductor
    case claudeDesktop

    var label: String {
        switch self {
        case .conductor: return "Conductor"
        case .claudeDesktop: return "Claude"
        }
    }
}

struct StalledSession: Identifiable, Equatable {
    let sessionID: String
    let claudeSessionID: String
    let title: String
    let workspacePath: String
    let errorText: String
    let stalledAt: Date?
    var source: SessionSource = .conductor
    var kind: StallKind { StallKind.classify(errorText) }

    var id: String { sessionID }

    var workspaceName: String {
        (workspacePath as NSString).lastPathComponent
    }
}

struct Decision: Equatable {
    let resume: Bool
    let reason: String
}

struct PolicyConfig {
    var startHour: Int = 23
    var endHour: Int = 7
    var fiveHourCeiling: Double = 85
    var weeklyCeiling: Double = 90
    var pacingMargin: Double = 15
    var maxResumesPerSession: Int = 3
    var maxSessionsPerNight: Int = 10
    var permissionMode: String = "acceptEdits"
    var resumePrompt: String =
        "Continue where you left off. Finish the task you were working on. "
        + "If everything is already done, reply DONE and stop."

    static func fromDefaults(_ d: UserDefaults = .standard) -> PolicyConfig {
        var c = PolicyConfig()
        if d.object(forKey: "startHour") != nil { c.startHour = d.integer(forKey: "startHour") }
        if d.object(forKey: "endHour") != nil { c.endHour = d.integer(forKey: "endHour") }
        if d.object(forKey: "fiveHourCeiling") != nil { c.fiveHourCeiling = d.double(forKey: "fiveHourCeiling") }
        if d.object(forKey: "weeklyCeiling") != nil { c.weeklyCeiling = d.double(forKey: "weeklyCeiling") }
        return c
    }
}

enum ISO {
    /// Parse ISO-8601 timestamps with any fractional-second precision
    /// (the usage API emits 6 digits, Conductor's DB emits 3).
    static func parse(_ raw: String) -> Date? {
        var cleaned = raw.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        // Some SQLite writers separate date and time with a space, not "T".
        if !cleaned.contains("T"), let space = cleaned.firstIndex(of: " ") {
            cleaned.replaceSubrange(space...space, with: "T")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }
}
