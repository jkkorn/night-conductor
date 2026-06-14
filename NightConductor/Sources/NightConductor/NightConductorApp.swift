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
            MainActor.assumeIsolated {
                Screenshotter.render(
                    to: args[flagIndex + 1],
                    showSettings: args.contains("--settings"),
                    state: stateName
                )
            }
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

/// The menu bar item itself: the moon plus, optionally, the live 5-hour
/// usage % — the number that actually decides whether you can run Claude
/// right now. Updates every 30s with the view loop.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @AppStorage("armed") private var armed = true
    @AppStorage("menuBarUsage") private var menuBarUsage = true

    var body: some View {
        let icon = armed ? "moon.stars.fill" : "moon.zzz"
        if menuBarUsage, let usage = state.usage {
            Image(systemName: icon)
            Text("\(Int(usage.fiveHour.utilization))%")
        } else {
            Image(systemName: icon)
        }
    }
}
