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

struct StalledSession: Identifiable, Equatable {
    let sessionID: String
    let claudeSessionID: String
    let title: String
    let workspacePath: String
    let errorText: String
    let stalledAt: Date?

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
