import ServiceManagement
import SwiftUI

// Confirm this is right — it ships inside the app's About line.
enum AboutLinks {
    static let linkedIn = URL(string: "https://www.linkedin.com/in/jkkorn")!
}

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings: Bool
    @State private var showActivity = false

    init(showSettings: Bool = false) {
        _showSettings = State(initialValue: showSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            usageSection
            decisionRow
            stalledSection
            if showActivity { activityLog }
            Divider()
            footer
            about
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .font(.title2)
                .foregroundStyle(.indigo.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text("Night Conductor").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.armed },
                set: { state.armed = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Arm or disarm the night watch")
        }
    }

    private var subtitle: String {
        if let resuming = state.currentlyResuming { return "Conducting: \(resuming)…" }
        if state.isWorking { return "Checking…" }
        return state.armed ? "Watching while you sleep" : "Paused"
    }

    private var usageSection: some View {
        VStack(spacing: 10) {
            UsageMeter(
                label: "5-hour window",
                window: state.usage?.fiveHour,
                resetStyle: .time
            )
            UsageMeter(
                label: "Weekly budget",
                window: state.usage?.sevenDay,
                resetStyle: .date
            )
        }
    }

    private var decisionRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(decisionColor)
                .frame(width: 8, height: 8)
            Text(state.decision?.reason ?? "Waiting for first check…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var decisionColor: Color {
        guard let decision = state.decision else { return .gray }
        return decision.resume ? .green : .orange
    }

    @ViewBuilder
    private var stalledSection: some View {
        if state.stalled.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "zzz").foregroundStyle(.tertiary)
                Text("No stalled sessions — all quiet")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("STALLED AT THE LIMIT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ForEach(state.stalled) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title).font(.callout).lineLimit(1)
                            Text(session.workspaceName)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                Button {
                    Task { await state.tick(manual: true) }
                } label: {
                    Label("Resume now", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(state.isWorking)
                .help("Bypasses the night schedule, never the budget gates")
            }
        }
    }

    private var activityLog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(state.activity, id: \.self) { line in
                    Text(line).font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if state.activity.isEmpty {
                    Text("Nothing yet tonight.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 110)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if showSettings { SettingsPane() }
            HStack {
                // No animation here: animated height changes make the
                // MenuBarExtra window dismiss itself on some macOS versions.
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")

                Button {
                    showActivity.toggle()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Activity")
                .accessibilityIdentifier("activityButton")

                Spacer()
                if let tick = state.lastTick {
                    Text("Checked \(tick.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

extension MenuView {
    var about: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Made with ❤️ in Brazil by")
            Link("Jonathan Korn", destination: AboutLinks.linkedIn)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .tint(.secondary)
    }
}

enum ResetStyle { case time, date }

struct UsageMeter: View {
    let label: String
    let window: UsageWindow?
    let resetStyle: ResetStyle

    private var value: Double { window?.utilization ?? 0 }

    private var tint: Color {
        switch value {
        case ..<60: return .indigo
        case ..<85: return .orange
        default: return .red
        }
    }

    private var resetText: String {
        guard let resetsAt = window?.resetsAt else { return "" }
        switch resetStyle {
        case .time: return "resets \(resetsAt.formatted(date: .omitted, time: .shortened))"
        case .date: return "resets \(resetsAt.formatted(.dateTime.weekday(.wide).hour().minute()))"
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(resetText).font(.caption2).foregroundStyle(.tertiary)
                Text(window == nil ? "–" : "\(Int(value))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: min(value, 100), total: 100)
                .progressViewStyle(.linear)
                .tint(tint.gradient)
        }
    }
}

struct SettingsPane: View {
    @AppStorage("startHour") private var startHour = 23
    @AppStorage("endHour") private var endHour = 7
    @AppStorage("fiveHourCeiling") private var fiveHourCeiling = 85.0
    @AppStorage("weeklyCeiling") private var weeklyCeiling = 90.0
    @AppStorage("uiResume") private var uiResume = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    // AXIsProcessTrusted() is only re-read on render, so poll while the
    // pane is open — the warning clears within seconds of granting.
    @State private var hasAccessibility = UIResumer.hasAccessibilityPermission
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Watch from").font(.caption)
                Stepper("\(startHour):00", value: $startHour, in: 0...23)
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("I'm back at").font(.caption)
                Stepper("\(endHour):00", value: $endHour, in: 0...23)
                    .font(.caption.monospacedDigit())
            }
            Text("Nothing starts after \(((endHour - 5) + 24) % 24):00, so your 5-hour window is fresh when you sit down.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("5h ceiling \(Int(fiveHourCeiling))%").font(.caption)
                Slider(value: $fiveHourCeiling, in: 50...100, step: 5)
            }
            HStack {
                Text("Weekly stop \(Int(weeklyCeiling))%").font(.caption)
                Slider(value: $weeklyCeiling, in: 50...100, step: 5)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Divider()
            Toggle("Resume inside Conductor", isOn: $uiResume)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onChange(of: uiResume) { _, enabled in
                    if enabled, !UIResumer.hasAccessibilityPermission {
                        UIResumer.requestPermission()
                    }
                }
            if uiResume {
                if hasAccessibility {
                    Text("Presses Conductor's own Retry button, so the chat stays in sync. Falls back to a headless resume if that fails.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Needs Accessibility access: System Settings → Privacy & Security → Accessibility → enable Night Conductor.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onReceive(permissionTimer) { _ in
            hasAccessibility = UIResumer.hasAccessibilityPermission
        }
    }
}
