import SwiftUI

/// A living night sky: a slowly drifting aurora (animated MeshGradient) with
/// a hand-composed, twinkling starfield and a glowing moon. This replaces the
/// flat "CSS gradient" header — the whole point is that it breathes, so it
/// can never read as a generic AI-slop gradient. Calm by design (long, slow
/// periods); when paused, the sky dims and the stars settle.
struct NightSkyView: View {
    var armed: Bool
    var animated: Bool = true

    // Hand-placed stars (x, y in 0...1, radius pt, twinkle phase). Composed,
    // not random — a few bright anchors, many faint ones, biased to the top
    // so they don't fight the wordmark at the bottom-left.
    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, phase: Double)] = [
        (0.86, 0.22, 1.7, 0.0), (0.74, 0.40, 1.1, 1.3), (0.92, 0.52, 0.9, 2.1),
        (0.66, 0.18, 1.3, 3.4), (0.55, 0.30, 0.8, 0.7), (0.80, 0.68, 1.0, 4.2),
        (0.45, 0.16, 0.9, 5.1), (0.34, 0.26, 1.2, 2.7), (0.62, 0.55, 0.7, 1.9),
        (0.24, 0.20, 0.8, 3.9), (0.50, 0.46, 0.6, 0.4), (0.70, 0.28, 0.7, 4.8),
        (0.16, 0.34, 1.0, 2.2), (0.40, 0.62, 0.7, 5.5), (0.88, 0.36, 0.8, 1.1),
        (0.30, 0.44, 0.6, 3.1), (0.58, 0.70, 0.8, 0.9), (0.10, 0.22, 0.7, 4.4),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                aurora(t: t)
                starfield(t: t)
            }
        }
    }

    // MARK: - Aurora (animated mesh)

    private func aurora(t: TimeInterval) -> some View {
        // Drift the interior control points on slow, out-of-phase sines so
        // the color field swirls organically instead of sliding linearly.
        let d = animated ? 0.018 : 0.0
        func wob(_ a: Double, _ b: Double) -> Float {
            Float(sin(t * a + b) * d)
        }
        let pts: [SIMD2<Float>] = [
            [0, 0], [0.5 + wob(0.23, 1.0), 0], [1, 0],
            [0, 0.5 + wob(0.19, 2.0)],
            [0.5 + wob(0.27, 0.0), 0.5 + wob(0.21, 3.0)],
            [1, 0.5 + wob(0.17, 4.0)],
            [0, 1], [0.5 + wob(0.25, 5.0), 1], [1, 1],
        ]
        // Deep nocturnal palette: violet → indigo → midnight, with a faint
        // teal aurora breathing in the upper band when armed.
        let glow = armed ? 0.5 + 0.5 * sin(t * 0.4) : 0.0
        let teal = Color(red: 0.10, green: 0.42, blue: 0.45).opacity(0.30 + 0.25 * glow)
        let colors: [Color] = [
            Color(red: 0.16, green: 0.13, blue: 0.42), teal, Color(red: 0.20, green: 0.15, blue: 0.46),
            Color(red: 0.13, green: 0.11, blue: 0.34), Color(red: 0.17, green: 0.13, blue: 0.40), Color(red: 0.10, green: 0.10, blue: 0.30),
            Color(red: 0.05, green: 0.05, blue: 0.14), Color(red: 0.07, green: 0.06, blue: 0.18), Color(red: 0.04, green: 0.04, blue: 0.12),
        ]
        return MeshGradient(width: 3, height: 3, points: pts, colors: colors)
    }

    // MARK: - Starfield

    private func starfield(t: TimeInterval) -> some View {
        Canvas { ctx, size in
            for star in Self.stars {
                let twinkle = animated ? (0.55 + 0.45 * sin(t * 1.1 + star.phase)) : 0.8
                let brightness = (armed ? 1.0 : 0.5) * twinkle
                let p = CGPoint(x: star.x * size.width, y: star.y * size.height)
                let rect = CGRect(x: p.x - star.r, y: p.y - star.r,
                                  width: star.r * 2, height: star.r * 2)
                // soft glow + crisp core
                ctx.fill(Circle().path(in: rect.insetBy(dx: -star.r, dy: -star.r)),
                         with: .color(.white.opacity(0.10 * brightness)))
                ctx.fill(Circle().path(in: rect),
                         with: .color(.white.opacity(0.85 * brightness)))
            }
        }
    }
}

/// The moon mark with a soft, breathing glow.
struct GlowingMoon: View {
    var armed: Bool
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: "moon.stars.fill")
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(armed ? 0.9 : 0.5))
            .shadow(color: .white.opacity(armed ? 0.5 : 0.15), radius: armed ? 10 : 4)
            .shadow(color: Color(red: 0.5, green: 0.5, blue: 0.95).opacity(armed ? 0.6 : 0.2),
                    radius: armed ? 18 : 6)
    }
}
