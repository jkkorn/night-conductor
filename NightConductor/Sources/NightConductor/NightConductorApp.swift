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
            MainActor.assumeIsolated {
                Screenshotter.render(
                    to: args[flagIndex + 1],
                    showSettings: args.contains("--settings")
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
    @AppStorage("armed") private var armed = true

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            Image(systemName: armed ? "moon.stars.fill" : "moon.zzz")
        }
        .menuBarExtraStyle(.window)
    }
}
