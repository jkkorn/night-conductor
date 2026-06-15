import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--render-screenshot"), args.count > flagIndex + 1 {
            var stateName = "default"
            if let s = args.firstIndex(of: "--state"), args.count > s + 1 { stateName = args[s + 1] }
            var hour = 23.0
            if let h = args.firstIndex(of: "--hour"), args.count > h + 1 { hour = Double(args[h + 1]) ?? 23 }
            MainActor.assumeIsolated {
                Screenshotter.render(
                    to: args[flagIndex + 1],
                    showSettings: args.contains("--settings"),
                    state: stateName,
                    hour: hour
                )
            }
            return
        }
        if let flagIndex = args.firstIndex(of: "--render-menubar"), args.count > flagIndex + 1 {
            MainActor.assumeIsolated { Screenshotter.renderMenuBar(to: args[flagIndex + 1]) }
            return
        }
        if let flagIndex = args.firstIndex(of: "--render-statcard"), args.count > flagIndex + 2 {
            let count = Int(args[flagIndex + 1]) ?? 12
            MainActor.assumeIsolated {
                NightSkyView.hourOverride = 23
                _ = StatCardExporter.render(count: count, to: URL(fileURLWithPath: args[flagIndex + 2]))
            }
            return
        }
        if args.contains("--scan") {
            let conductor = (try? ConductorDB.findStalledSessions()) ?? []
            let claude = ClaudeDesktopDB.findStalledSessions()
            print("Conductor stalled: \(conductor.count)")
            for s in conductor { print("  - \(s.title) [\(s.kind.shortLabel)] @ \(s.workspaceName)") }
            print("Claude Desktop stalled: \(claude.count)")
            for s in claude { print("  - \(s.title) [\(s.kind.shortLabel)] @ \(s.workspaceName)") }
            return
        }
        NightConductorApp.main()
    }
}

struct NightConductorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item: a ring gauge that fills with your live 5-hour usage —
/// the number that decides whether you can run Claude right now — so it reads
/// as a consumption meter, not a weather glyph. Dims when paused. Falls back
/// to the moon when usage display is turned off.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @AppStorage("armed") private var armed = true
    @AppStorage("menuBarUsage") private var menuBarUsage = true

    var body: some View {
        if menuBarUsage, let usage = state.usage {
            let pct = usage.fiveHour.utilization
            HStack(spacing: 3) {
                UsageRing(value: pct, armed: armed)
                Text("\(Int(pct))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(armed ? .primary : .secondary)
            }
        } else {
            Image(systemName: armed ? "moon.stars.fill" : "moon.zzz")
        }
    }
}
