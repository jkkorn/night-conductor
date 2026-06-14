import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac available for the night shift in two complementary ways:
///   1. A power assertion that prevents idle sleep while the watch is active
///      (no privileges needed) — covers a Mac that's awake at bedtime.
///   2. An optional firmware wake schedule (`pmset`, needs an admin prompt)
///      for a Mac that's fully asleep when the window begins.
enum PowerManager {
    // MARK: - Prevent idle sleep (no privileges)

    private static var assertionID: IOPMAssertionID = 0
    private static var held = false

    /// Hold/release an assertion that stops the system idle-sleeping, so
    /// every overnight tick and resume actually runs. Idempotent.
    static func preventIdleSleep(_ on: Bool) {
        if on, !held {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Night Conductor is resuming sessions" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                held = true
            }
        } else if !on, held {
            IOPMAssertionRelease(assertionID)
            held = false
        }
    }

    // MARK: - Firmware wake schedule (needs admin prompt)

    /// Schedule a daily wake-or-power-on at `hour:00`, derived from the
    /// user's watch start hour. Shows the native macOS admin prompt once.
    /// Returns true if the command succeeded.
    @discardableResult
    static func scheduleNightlyWake(hour: Int) -> Bool {
        let hh = String(format: "%02d", max(0, min(23, hour)))
        return runPrivileged("/usr/bin/pmset repeat wakeorpoweron MTWRFSU \(hh):00:00")
    }

    @discardableResult
    static func cancelNightlyWake() -> Bool {
        runPrivileged("/usr/bin/pmset repeat cancel")
    }

    /// Reads the current repeating schedule (best-effort, no privileges).
    static func currentWakeSchedule() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "sched"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        // The "Repeating power events" section lists a wake/poweron line.
        for line in out.split(separator: "\n") where
            line.localizedCaseInsensitiveContains("wakepoweron")
            || line.localizedCaseInsensitiveContains("wakeorpoweron") {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func runPrivileged(_ command: String) -> Bool {
        // `with administrator privileges` shows the native auth dialog once.
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 // non-zero if the user cancels
    }
}
