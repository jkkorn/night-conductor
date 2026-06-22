import ServiceManagement
import SwiftUI

enum AboutLinks {
    static let linkedIn = URL(string: "https://www.linkedin.com/in/jkkorn")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/jkkorn")!
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
    private let maxStalledRows = 6 // render this many; the rest auto-resume

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
        // Opening the popover is an explicit "show me now". If the cached
        // reading is stale, force a refresh (which also punches through a 429
        // backoff); if it's already fresh, stay throttled to avoid hammering.
        // Never in screenshot mode — docs must use curated demo data, not live.
        .onAppear {
            guard !state.isScreenshot else { return }
            Task { await state.refreshUsage(force: !state.usageIsFresh()) }
        }
    }

    // Living night-sky header: a drifting aurora + twinkling starfield, with
    // the brand wordmark (bottom-left), the arm control (bottom-right), and a
    // glowing moon (top-right). Each is its own corner so nothing overlaps.
    private var header: some View {
        ZStack(alignment: .topTrailing) {
            NightSkyView(armed: state.armed)
            // Scrim: darkens the top (moon/toggle) and bottom (wordmark) so
            // white content stays legible even on the bright daytime sky,
            // while the middle keeps the sky's color.
            LinearGradient(
                colors: [.black.opacity(0.22), .black.opacity(0.0), .black.opacity(0.40)],
                startPoint: .top, endPoint: .bottom
            )
            GlowingMoon(armed: state.armed)
                .padding(Design.l)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: Design.xs) {
                    Text("Night Conductor")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                        .contentTransition(.opacity)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Design.xs) {
                    Toggle("Arm night watch", isOn: Binding(
                        get: { state.armed },
                        set: { newValue in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                state.armed = newValue
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.green)
                    .help("Arm or disarm the night watch")
                    Text(state.armed ? "ARMED" : "PAUSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.armed ? Color.green : .white.opacity(0.6))
                        .contentTransition(.numericText())
                }
            }
            .padding(Design.l)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5) // crisp edge
        )
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
                .contentTransition(.symbolEffect(.replace))
            Text(state.decision?.reason ?? "Waiting for first check…")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)
                .contentTransition(.opacity)
        }
        .glassCard(tint: decisionColor)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: decisionColor)
    }

    private var decisionColor: Color {
        switch state.decision?.state {
        case .resuming: return .green
        case .standingBy: return .indigo   // calm & nocturnal — not a warning
        case .holding: return .orange
        case .checking, .none: return .secondary
        }
    }

    private var decisionIcon: String {
        switch state.decision?.state {
        case .resuming: return "checkmark.circle.fill"
        case .standingBy: return "moon.stars.fill" // resting; wakes for the night
        case .holding: return "pause.circle.fill"
        case .checking, .none: return "clock"
        }
    }

    @ViewBuilder
    private var stalledSection: some View {
        if state.stalled.isEmpty {
            HStack(spacing: Design.m) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary)
                Text("No stalled sessions, all quiet")
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
                // Render rows directly (a ScrollView collapses to zero height
                // in a self-sizing popover). Cap the count; the rest auto-
                // resume on their own cadence.
                ForEach(state.stalled.prefix(maxStalledRows)) { session in
                    stalledRow(session)
                }
                if state.stalled.count > maxStalledRows {
                    Text("+ \(state.stalled.count - maxStalledRows) more, pin the ones you want resumed by day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
                Button {
                    Task { await state.tick(manual: true) }
                } label: {
                    Label(state.isWorking ? "Working…" : "Resume now",
                          systemImage: state.isWorking ? "hourglass" : "play.fill")
                        .contentTransition(.opacity)
                }
                .buttonStyle(GlowButtonStyle(disabled: state.isWorking))
                .disabled(state.isWorking)
                .help("Resumes now, bypasses the schedule and budget gates")
            }
        }
    }

    @ViewBuilder
    private func stalledRow(_ session: StalledSession) -> some View {
        let accent: Color = session.kind == .transient ? .yellow : .orange
        let pinned = state.isPinned(session)
        HStack(spacing: Design.m) {
            Image(systemName: session.kind.icon)
                .font(.title3)
                .foregroundStyle(accent.gradient)
            VStack(alignment: .leading, spacing: Design.xs) {
                Text(session.title).font(.body).lineLimit(1)
                HStack(spacing: Design.s) {
                    Text(session.workspaceName)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(session.source.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    Text(session.kind.shortLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(accent.opacity(0.15), in: Capsule())
                }
            }
            Spacer()
            // Pin = auto-resume this session around the clock (not just at night).
            Button { state.togglePin(session) } label: {
                Image(systemName: pinned ? "repeat.circle.fill" : "repeat.circle")
                    .font(.title3)
                    .foregroundStyle(pinned ? Color.indigo : .secondary)
            }
            .buttonStyle(.plain)
            .help(pinned
                  ? "Auto-resuming any time, click to stop"
                  : "Auto-resume this session any time (not just at night)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverLift()
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
                ToolbarIconButton(systemName: "square.and.arrow.up", label: "Share this week's stats") {
                    StatCardExporter.share()
                }

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
        VStack(spacing: 2) {
            Text("Made with ❤️ in Brazil")
            HStack(spacing: 5) {
                Link("Jonathan Korn", destination: AboutLinks.linkedIn).underline()
                Text("·")
                Link("Buy me a coffee", destination: AboutLinks.buyMeACoffee).underline()
            }
        }
        .frame(maxWidth: .infinity)
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
                Text(window == nil ? "·" : "\(Int(value))%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.usageStatus(value))
                    .contentTransition(.numericText())
            }
            // Custom bar: a flat semantic fill (the color IS the signal),
            // with a soft glow, a top sheen for a glassy read, and a spring
            // on value changes so it fills like liquid, not a jump.
            GeometryReader { geo in
                let w = max(6, geo.size.width * min(value, 100) / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(Color.usageStatus(value).gradient)
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(.white.opacity(0.28))
                                .frame(height: 3)
                                .padding(.horizontal, 3)
                                .padding(.top, 1)
                        }
                        .frame(width: w)
                        .shadow(color: Color.usageStatus(value).opacity(0.55), radius: 5, y: 1)
                        .animation(.spring(response: 0.65, dampingFraction: 0.82), value: value)
                }
            }
            .frame(height: 10)
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject var state: AppState
    @State private var checkingUpdate = false
    @State private var checkedUpToDate = false
    @AppStorage("startHour") private var startHour = 23
    @AppStorage("endHour") private var endHour = 7
    @AppStorage("fiveHourCeiling") private var fiveHourCeiling = 85.0
    @AppStorage("weeklyCeiling") private var weeklyCeiling = 90.0
    @AppStorage("resumePaceMinutes") private var resumePaceMinutes = 10.0
    @AppStorage("uiResume") private var uiResume = true
    @AppStorage("menuBarUsage") private var menuBarUsage = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var wakeScheduled = PowerManager.currentWakeSchedule() != nil
    // AXIsProcessTrusted() is only re-read on render, so poll while the
    // pane is open — the warning clears within seconds of granting.
    @State private var hasAccessibility = UIResumer.hasAccessibilityPermission
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.m) {
            HStack {
                Text("Watch from").font(.caption)
                HourStepper(hour: $startHour)
                Spacer()
                Text("I'm back at").font(.caption)
                HourStepper(hour: $endHour)
            }
            Text("Nothing starts after \(((endHour - 5) + 24) % 24):00, so your 5-hour window is fresh when you sit down.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("Nightly wake").font(.caption)
                Spacer()
                if wakeScheduled {
                    Label("scheduled", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                    Button("Remove") {
                        if PowerManager.cancelNightlyWake() { wakeScheduled = false }
                    }.controlSize(.small)
                } else {
                    Button("Wake at \(startHour):00…") {
                        if PowerManager.scheduleNightlyWake(hour: startHour) { wakeScheduled = true }
                    }.controlSize(.small)
                }
            }
            Text("Night Conductor keeps your Mac awake during the watch by itself. Only schedule a wake if your Mac fully sleeps before then (asks for your password once).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Design.l) {
                Text("5h ceiling \(Int(fiveHourCeiling))%")
                    .font(.caption).frame(width: 96, alignment: .leading)
                NightSlider(value: $fiveHourCeiling, range: 50...100, step: 5)
            }
            HStack(spacing: Design.l) {
                Text("Weekly stop \(Int(weeklyCeiling))%")
                    .font(.caption).frame(width: 96, alignment: .leading)
                NightSlider(value: $weeklyCeiling, range: 50...100, step: 5)
            }
            HStack(spacing: Design.l) {
                Text("Resume pace \(Int(resumePaceMinutes))m")
                    .font(.caption).frame(width: 96, alignment: .leading)
                NightSlider(value: $resumePaceMinutes, range: 5...20, step: 1)
            }
            Text("How often the watch attempts a resume overnight. Higher spreads them out more.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            if uiResume {
                if hasAccessibility {
                    Text("Presses Conductor's own Retry button, so the chat stays in sync. Falls back to a headless resume if that fails.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: Design.s) {
                        Text("Needs Accessibility access to press Conductor's Retry button.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Accessibility Settings…") {
                            UIResumer.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
            Divider().opacity(0.4)
            HStack {
                if !state.isScreenshot {  // the offscreen render has no bundle version
                    Text("Version \(UpdateChecker.currentVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(checkingUpdate ? "Checking…" : "Check for updates") {
                    checkingUpdate = true
                    checkedUpToDate = false
                    Task {
                        await state.checkForUpdates(force: true)
                        checkingUpdate = false
                        checkedUpToDate = state.update == nil
                    }
                }
                .controlSize(.small)
                .disabled(checkingUpdate)
            }
            if let update = state.update, let url = URL(string: update.url) {
                HStack(spacing: Design.s) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                    Text("Update available: \(update.version)").font(.caption)
                    Spacer()
                    Link("Download", destination: url).controlSize(.small)
                }
            } else if checkedUpToDate {
                Text("You're on the latest version.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .glassCard()
        .onReceive(permissionTimer) { _ in
            hasAccessibility = UIResumer.hasAccessibilityPermission
        }
    }
}
