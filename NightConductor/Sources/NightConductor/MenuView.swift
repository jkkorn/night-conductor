import ServiceManagement
import SwiftUI

// Confirm this is right — it ships inside the app's About line.
enum AboutLinks {
    static let linkedIn = URL(string: "https://www.linkedin.com/in/jkkorn")!
}

/// Design tokens — one 4pt spacing scale and one card surface, so spacing
/// and chrome are systematic instead of per-view magic numbers.
enum Design {
    static let xs: CGFloat = 2   // within a tight text stack
    static let s: CGFloat = 4    // label → control
    static let m: CGFloat = 8    // within a section
    static let l: CGFloat = 12   // card padding / section gap
    static let xl: CGFloat = 16  // window padding
    static let cardRadius: CGFloat = 8
}

extension Color {
    /// One semantic ramp for "how full is this budget": green = headroom,
    /// amber = approaching the ceiling, red = at/over. Indigo is reserved
    /// for the brand (the moon), never for status.
    static func usageStatus(_ pct: Double) -> Color {
        switch pct {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

extension View {
    /// The single card surface used by the decision pill and settings pane.
    func cardSurface() -> some View {
        padding(Design.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: Design.cardRadius))
    }
}

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings: Bool
    @State private var showActivity = false

    init(showSettings: Bool = false) {
        _showSettings = State(initialValue: showSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.l) {
            header
            usageSection
            decisionRow
            stalledSection
            if showActivity { activityLog }
            Divider()
            footer
            about
        }
        .padding(Design.l)
        .frame(width: 340)
    }

    // Nocturnal header: a gradient night-sky card with the brand wordmark
    // (bottom-left), the arm control (bottom-right), and an atmospheric moon
    // (top-right). Each is its own corner so nothing overlaps.
    private var header: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(red: 0.20, green: 0.16, blue: 0.45),
                         Color(red: 0.06, green: 0.06, blue: 0.16)],
                startPoint: .topTrailing, endPoint: .bottomLeading
            )
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.22)) // atmospheric brand mark
                .padding(Design.l)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: Design.xs) {
                    Text("Night Conductor")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Design.xs) {
                    Toggle("Arm night watch", isOn: Binding(
                        get: { state.armed },
                        set: { state.armed = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.green)
                    .help("Arm or disarm the night watch")
                    Text(state.armed ? "ARMED" : "PAUSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.armed ? Color.green : .white.opacity(0.6))
                }
            }
            .padding(Design.l)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var subtitle: String {
        if let resuming = state.currentlyResuming { return "Conducting: \(resuming)…" }
        if state.isWorking { return "Checking…" }
        return state.armed ? "Watching while you sleep" : "Paused"
    }

    private var usageSection: some View {
        VStack(spacing: Design.m) {
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
        HStack(spacing: Design.m) {
            Image(systemName: decisionIcon)
                .foregroundStyle(decisionColor)
            Text(state.decision?.reason ?? "Waiting for first check…")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
        }
        .padding(Design.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(decisionColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Design.cardRadius))
    }

    private var decisionColor: Color {
        guard let decision = state.decision else { return .gray }
        return decision.resume ? .green : .orange
    }

    private var decisionIcon: String {
        guard let decision = state.decision else { return "clock" }
        return decision.resume ? "checkmark.circle.fill" : "pause.circle.fill"
    }

    @ViewBuilder
    private var stalledSection: some View {
        if state.stalled.isEmpty {
            HStack(spacing: Design.m) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary)
                Text("No stalled sessions — all quiet")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, Design.s)
        } else {
            VStack(alignment: .leading, spacing: Design.m) {
                HStack {
                    Text("Stalled at the limit").font(.headline)
                    Spacer()
                    Text("\(state.stalled.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
                // Bounded height so a long stalled list can't push the
                // popover past the screen; scrolls past ~4 rows.
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.m) {
                        ForEach(state.stalled) { session in
                            HStack(spacing: Design.m) {
                                Image(systemName: "pause.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.orange.gradient)
                                VStack(alignment: .leading, spacing: Design.xs) {
                                    Text(session.title).font(.body).lineLimit(1)
                                    Text(session.workspaceName)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: state.stalled.count > 4 ? 160 : .infinity)
                Button {
                    Task { await state.tick(manual: true) }
                } label: {
                    Label("Resume now", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Design.m)
                        .background(
                            (state.isWorking ? Color.gray : Color.indigo).gradient,
                            in: RoundedRectangle(cornerRadius: Design.cardRadius)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
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
        VStack(spacing: Design.m) {
            if showSettings { SettingsPane() }
            HStack {
                // No animation here: animated height changes make the
                // MenuBarExtra window dismiss itself on some macOS versions.
                ToolbarIconButton(systemName: "gearshape", label: "Settings") {
                    showSettings.toggle()
                }
                .accessibilityIdentifier("settingsButton")
                ToolbarIconButton(systemName: "list.bullet.rectangle", label: "Activity") {
                    showActivity.toggle()
                }
                .accessibilityIdentifier("activityButton")

                Spacer()
                if let tick = state.lastTick {
                    Text("Checked \(tick.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

/// A menu-bar-style icon button: real hit target plus a hover highlight, so
/// it reads as clickable instead of a dim decorative glyph.
struct ToolbarIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 26, height: 22)
                .background(
                    hovering ? Color.secondary.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
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

    private var resetText: String {
        guard let resetsAt = window?.resetsAt else { return "" }
        switch resetStyle {
        case .time: return "resets \(resetsAt.formatted(date: .omitted, time: .shortened))"
        case .date: return "resets \(resetsAt.formatted(.dateTime.weekday(.wide).hour().minute()))"
        }
    }

    var body: some View {
        VStack(spacing: Design.m) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(resetText).font(.caption).foregroundStyle(.secondary)
                Text(window == nil ? "–" : "\(Int(value))%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
            }
            // Custom bar with an explicit semantic fill. macOS's
            // ProgressView(.linear) ignores .tint in some render contexts,
            // washing the fill to gray — and the color IS the signal here.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.usageStatus(value).gradient)
                        .frame(width: max(6, geo.size.width * min(value, 100) / 100))
                }
            }
            .frame(height: 10)
        }
    }
}

struct SettingsPane: View {
    @AppStorage("startHour") private var startHour = 23
    @AppStorage("endHour") private var endHour = 7
    @AppStorage("fiveHourCeiling") private var fiveHourCeiling = 85.0
    @AppStorage("weeklyCeiling") private var weeklyCeiling = 90.0
    @AppStorage("uiResume") private var uiResume = true
    @AppStorage("menuBarUsage") private var menuBarUsage = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    // AXIsProcessTrusted() is only re-read on render, so poll while the
    // pane is open — the warning clears within seconds of granting.
    @State private var hasAccessibility = UIResumer.hasAccessibilityPermission
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.m) {
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("5h ceiling \(Int(fiveHourCeiling))%").font(.caption)
                Slider(value: $fiveHourCeiling, in: 50...100, step: 5)
            }
            HStack {
                Text("Weekly stop \(Int(weeklyCeiling))%").font(.caption)
                Slider(value: $weeklyCeiling, in: 50...100, step: 5)
            }
            Toggle("Show 5h usage in menu bar", isOn: $menuBarUsage)
                .font(.caption)
                .toggleStyle(.checkbox)
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
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Needs Accessibility access: System Settings → Privacy & Security → Accessibility → enable Night Conductor.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Design.l)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Design.cardRadius))
        .onReceive(permissionTimer) { _ in
            hasAccessibility = UIResumer.hasAccessibilityPermission
        }
    }
}
