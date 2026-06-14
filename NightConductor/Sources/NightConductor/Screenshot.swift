import AppKit
import SwiftUI

/// Hidden CLI mode that renders the popover to a PNG for docs/marketing:
///   NightConductor --render-screenshot out.png [--settings]
/// Uses representative demo data so real session titles never ship.
@MainActor
enum Screenshotter {
    static func render(to path: String, showSettings: Bool, state stateName: String = "default") {
        // ImageRenderer can't draw NSView-backed controls (Toggle, Stepper,
        // Slider), so render in a real off-to-the-side window and snapshot
        // the view hierarchy instead — that draws everything.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        app.finishLaunching()

        let state = demoState(stateName)
        let root = MenuView(showSettings: showSettings)
            .environmentObject(state)
            .frame(width: 340)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(red: 0.12, green: 0.12, blue: 0.14))
            .environment(\.colorScheme, .dark)
        renderHosting(AnyView(root), to: path)
    }

    private static func renderHosting(_ rootView: some View, to path: String) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 900)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.orderFrontRegardless()

        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let fitting = hosting.fittingSize
        window.setContentSize(fitting)
        hosting.frame = NSRect(origin: .zero, size: fitting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("encode failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        window.orderOut(nil)
        print("Wrote \(path)")
    }

    private static func demoState(_ name: String = "default") -> AppState {
        // Per-state knobs so we can audit every visual state as a still.
        let armed = name != "paused"
        let fiveHour = name == "high" ? 88.0 : 36.0
        let weekly = name == "high" ? 76.0 : 29.0
        UserDefaults.standard.set(armed, forKey: "armed")

        let state = AppState(forScreenshots: true)
        let now = Date()
        state.usage = UsageSnapshot(
            fiveHour: UsageWindow(utilization: fiveHour, resetsAt: now.addingTimeInterval(3.2 * 3600)),
            sevenDay: UsageWindow(utilization: weekly, resetsAt: now.addingTimeInterval(1.6 * 86_400)),
            fetchedAt: now
        )
        state.decision = name == "high"
            ? Decision(resume: false, reason: "5-hour window at 88% (ceiling 85%)")
            : Decision(resume: true, reason: "Wiggle room: 29% of week used, 1.6 days to reset")
        state.stalled = name == "empty" ? [] : [
            StalledSession(
                sessionID: "demo-1", claudeSessionID: "demo-1",
                title: "Refactor onboarding flow", workspacePath: "/ws/myapp/oslo",
                errorText: "You've hit your session limit · resets 1:30am",
                stalledAt: now.addingTimeInterval(-40 * 60)
            ),
            StalledSession(
                sessionID: "demo-2", claudeSessionID: "demo-2",
                title: "Fix paywall A/B variants", workspacePath: "/ws/myapp/dallas",
                errorText: "You've hit your session limit · resets 1:30am",
                stalledAt: now.addingTimeInterval(-25 * 60)
            ),
        ]
        state.lastTick = now
        return state
    }
}
