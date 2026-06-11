import Foundation

/// Budget policy — the brain. Direct port of the Python `autoconduct.policy`
/// module so the CLI and the app always agree on what "safe" means.
enum Policy {
    static func inActiveHours(hour: Int, start: Int, end: Int) -> Bool {
        if start == end { return true }
        if start < end { return start <= hour && hour < end }
        return hour >= start || hour < end
    }

    /// Length of Claude's rolling session window in hours.
    static let fiveHourWindow = 5.0

    static func hoursUntilWake(nowHour: Double, wakeHour: Int) -> Double {
        let remaining = (Double(wakeHour) - nowHour).truncatingRemainder(dividingBy: 24)
        return remaining < 0 ? remaining + 24 : remaining
    }

    static func daysUntilWeeklyReset(_ usage: UsageSnapshot, now: Date) -> Double {
        guard let resetsAt = usage.sevenDay.resetsAt else { return 0 }
        return max(0, resetsAt.timeIntervalSince(now) / 86_400)
    }

    static func shouldResume(
        usage: UsageSnapshot,
        config: PolicyConfig,
        now: Date,
        calendar: Calendar = .current,
        ignoreActiveHours: Bool = false
    ) -> Decision {
        let hour = calendar.component(.hour, from: now)
        if !ignoreActiveHours,
           !inActiveHours(hour: hour, start: config.startHour, end: config.endHour) {
            return Decision(
                resume: false,
                reason: "Outside active hours (\(config.startHour):00–\(config.endHour):00)"
            )
        }

        // Morning protection: the user is back at the computer at endHour.
        // A session started now anchors a 5h window — never start one that
        // would still be hot when they sit down (a 6am resume would lock
        // them out until 11am).
        if !ignoreActiveHours, config.startHour != config.endHour {
            let minute = calendar.component(.minute, from: now)
            let nowFrac = Double(hour) + Double(minute) / 60.0
            let remaining = hoursUntilWake(nowHour: nowFrac, wakeHour: config.endHour)
            if remaining < Self.fiveHourWindow {
                return Decision(
                    resume: false,
                    reason: "Morning protection: a session now would hold your "
                        + "5-hour window past \(config.endHour):00 "
                        + "(you're back in \(String(format: "%.1f", remaining))h)"
                )
            }
        }

        if usage.fiveHour.utilization >= config.fiveHourCeiling {
            return Decision(
                resume: false,
                reason: "5-hour window at \(Int(usage.fiveHour.utilization))% "
                    + "(ceiling \(Int(config.fiveHourCeiling))%)"
            )
        }

        if usage.sevenDay.utilization >= config.weeklyCeiling {
            return Decision(
                resume: false,
                reason: "Weekly window at \(Int(usage.sevenDay.utilization))% "
                    + "(ceiling \(Int(config.weeklyCeiling))%)"
            )
        }

        // Weekly pacing: hold if the week is being consumed faster than time
        // is passing, with a safety margin protecting the next workdays.
        let weekUsed = usage.sevenDay.utilization
        let daysLeft = daysUntilWeeklyReset(usage, now: now)
        let elapsedPct = (1.0 - min(daysLeft, 7.0) / 7.0) * 100.0
        let allowed = elapsedPct + config.pacingMargin
        if weekUsed > allowed {
            return Decision(
                resume: false,
                reason: "Weekly burn too fast: \(Int(weekUsed))% used, "
                    + String(format: "%.1f", daysLeft) + " days to reset"
            )
        }

        return Decision(
            resume: true,
            reason: "Wiggle room: \(Int(weekUsed))% of week used, "
                + String(format: "%.1f", daysLeft) + " days to reset"
        )
    }
}
