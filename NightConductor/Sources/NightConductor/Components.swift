import SwiftUI

extension View {
    /// A frosted card surface. We deliberately fake the glass with layered
    /// translucent fills + a hairline top-lit stroke instead of a real
    /// backdrop material: backdrop blur needs a live compositor (it renders
    /// opaque in offscreen snapshots and is unreliable inside a menu-bar
    /// popover), whereas this reads identically everywhere and stays crisp.
    func glassCard(cornerRadius: CGFloat = Design.cardRadius, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .padding(Design.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(.white.opacity(0.05))                 // frost
                    if let tint { shape.fill(tint.opacity(0.14)) }   // status wash
                    shape.fill(
                        LinearGradient(                              // top-lit sheen
                            colors: [.white.opacity(0.06), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
                }
            }
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    /// A subtle lift + glow on hover, the macOS "this is alive" cue.
    func hoverLift() -> some View { modifier(HoverLift()) }
}

private struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.012 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Custom hour stepper — replaces AppKit `Stepper` (which triggers
/// AttributeGraph layout cycles in this hosting context) with a crafted
/// −/+ control that matches the night theme.
struct HourStepper: View {
    @Binding var hour: Int
    var range: ClosedRange<Int> = 0...23

    var body: some View {
        HStack(spacing: Design.m) {
            Text(String(format: "%02d:00", hour))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 46, alignment: .leading)
                .contentTransition(.numericText())
            HStack(spacing: 3) {
                button("minus") { set(hour - 1) }
                button("plus") { set(hour + 1) }
            }
        }
    }

    private func set(_ v: Int) {
        withAnimation(.snappy(duration: 0.18)) {
            hour = min(range.upperBound, max(range.lowerBound, v))
        }
    }

    private func button(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 18)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.8))
    }
}

/// Custom slider — replaces AppKit `Slider` (cycle source) with a draggable
/// track + knob in the accent color, with a spring on tick changes.
struct NightSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var tint: Color = .indigo

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let frac = span == 0 ? 0 : (value - range.lowerBound) / span
            let w = geo.size.width
            let knobX = max(7, min(w - 7, w * frac))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                Capsule().fill(tint.gradient).frame(width: knobX, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: knobX - 7)
                    .animation(.snappy(duration: 0.15), value: value)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let f = max(0, min(1, g.location.x / w))
                    let raw = range.lowerBound + f * span
                    let stepped = (raw / step).rounded() * step
                    value = min(range.upperBound, max(range.lowerBound, stepped))
                }
            )
        }
        .frame(height: 18)
    }
}

/// The hero "Resume now" button: indigo glass, springy press, breathing glow.
struct GlowButtonStyle: ButtonStyle {
    var disabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        let base = disabled ? AnyShapeStyle(Color.gray.opacity(0.5))
                            : AnyShapeStyle(Color.indigo.gradient)
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Design.m)
            .background(base, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
            .foregroundStyle(.white)
            .overlay(
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .shadow(color: .indigo.opacity(disabled ? 0 : 0.45),
                    radius: configuration.isPressed ? 5 : 12, y: 4)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
