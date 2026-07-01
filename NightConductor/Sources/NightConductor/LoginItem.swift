import Foundation
import ServiceManagement

/// Launch-at-login, defaulted ON so a restart never leaves the night watch
/// silently dead (the failure that made the app look broken: it wasn't running
/// at all). We register once, on the very first launch, then respect whatever
/// the user chooses in Settings from then on.
enum LoginItem {
    static let configuredKey = "loginItemConfigured"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True exactly once, on the first launch ever, and records that the
    /// default has been applied. Pure and testable: the system call is kept
    /// out so this can be unit-tested; `ensureDefaultOnFirstLaunch` does the
    /// registration.
    static func consumeFirstLaunch(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: configuredKey) else { return false }
        defaults.set(true, forKey: configuredKey)
        return true
    }

    /// Register as a login item on first launch only, so a later "off" sticks.
    static func ensureDefaultOnFirstLaunch(defaults: UserDefaults = .standard) {
        guard consumeFirstLaunch(defaults: defaults) else { return }
        try? SMAppService.mainApp.register() // no-op / throws on unsigned dev builds; harmless
    }

    /// Apply an explicit user choice from the Settings toggle.
    static func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // The caller re-reads `isEnabled` to reflect the real status.
        }
    }
}
