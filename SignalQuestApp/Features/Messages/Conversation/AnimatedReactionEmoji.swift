import SwiftUI

/// Emoji de réaction qui joue un geste propre, façon tapbacks d'iMessage :
/// ❤️ bat, 🔥 vacille, 👏 tape, 🚀 décolle, ⚡ clignote, 📡 balaie.
/// Il joue à l'ouverture de la barre de l'appui long (`autoplayDelay`), quand
/// la réaction vient d'être posée (`burst` récent) et quand son compteur monte.
/// « Réduire les animations » : emoji immobile.
struct AnimatedReactionEmoji: View {
    let emoji: String
    let size: CGFloat
    var autoplayDelay: Double?
    var burst: Date?
    var count = 0

    @State private var token = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        animated
            .onAppear {
                if let autoplayDelay { play(after: autoplayDelay) }
                // Pastille qui vient d'apparaître pour la réaction posée : après son « pop ».
                if let burst, Date().timeIntervalSince(burst) < 1.5 { play(after: 0.12) }
            }
            .onChangeCompat(of: burst) { _, _ in play(after: 0.12) }
            .onChangeCompat(of: count) { old, new in if new > old { play(after: 0) } }
    }

    @ViewBuilder
    private var animated: some View {
        let label = Text(emoji).font(.system(size: size))
        if reduceMotion {
            label
        } else if #available(iOS 17.0, *) {
            let p = ReactionMotionProfile.for(emoji)
            label.keyframeAnimator(initialValue: ReactionMotion(), trigger: token) { content, m in
                content
                    .scaleEffect(x: m.scale, y: m.scale * m.stretch, anchor: .bottom)
                    .rotationEffect(.degrees(m.angle), anchor: p.pivot)
                    .offset(y: m.lift)
                    .opacity(m.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(p.scale.0, duration: 0.14, spring: .snappy)
                    SpringKeyframe(p.scale.1, duration: 0.14, spring: .snappy)
                    SpringKeyframe(p.scale.2, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                }
                KeyframeTrack(\.stretch) {
                    LinearKeyframe(p.stretch.0, duration: 0.12)
                    LinearKeyframe(p.stretch.1, duration: 0.12)
                    LinearKeyframe(p.stretch.2, duration: 0.12)
                    SpringKeyframe(1, duration: 0.22)
                }
                KeyframeTrack(\.angle) {
                    LinearKeyframe(p.angle.0, duration: 0.09)
                    LinearKeyframe(p.angle.1, duration: 0.11)
                    LinearKeyframe(p.angle.2, duration: 0.11)
                    LinearKeyframe(p.angle.3, duration: 0.11)
                    SpringKeyframe(0, duration: 0.25)
                }
                KeyframeTrack(\.lift) {
                    SpringKeyframe(p.lift.0, duration: 0.2, spring: .snappy)
                    SpringKeyframe(p.lift.1, duration: 0.2)
                    SpringKeyframe(0, duration: 0.25, spring: .bouncy)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(p.flash.0, duration: 0.07)
                    LinearKeyframe(1, duration: 0.07)
                    LinearKeyframe(p.flash.1, duration: 0.07)
                    LinearKeyframe(1, duration: 0.1)
                }
            }
        } else {
            LegacyBounce(label: label, token: token)
        }
    }

    private func play(after delay: Double) {
        guard !reduceMotion else { return }
        if delay <= 0 { token += 1; return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            token += 1
        }
    }
}

private struct ReactionMotion {
    var scale: Double = 1
    var stretch: Double = 1
    var angle: Double = 0
    var lift: Double = 0
    var opacity: Double = 1
}

/// Valeurs clés du geste de chaque emoji (mêmes pistes, amplitudes différentes).
private struct ReactionMotionProfile {
    var scale: (Double, Double, Double) = (1.35, 0.95, 1.1)
    var stretch: (Double, Double, Double) = (1, 1, 1)
    var angle: (Double, Double, Double, Double) = (0, 0, 0, 0)
    var lift: (Double, Double) = (0, 0)
    var flash: (Double, Double) = (1, 1)
    var pivot: UnitPoint = .center

    static func `for`(_ emoji: String) -> ReactionMotionProfile {
        switch emoji {
        case "❤️":
            // Deux battements.
            return ReactionMotionProfile(scale: (1.38, 0.9, 1.22))
        case "🔥":
            // La flamme s'étire et vacille depuis sa base.
            return ReactionMotionProfile(scale: (1.15, 1.0, 1.1), stretch: (1.2, 0.9, 1.12),
                                         angle: (-7, 6, -4, 3), lift: (-2, 0), pivot: .bottom)
        case "👏":
            // Applaudissements : petits coups rapides.
            return ReactionMotionProfile(scale: (1.22, 1.05, 1.16), angle: (-16, 14, -12, 9))
        case "🚀":
            // Décolle en penchant, puis se repose.
            return ReactionMotionProfile(scale: (1.12, 1.1, 1.04), angle: (-12, -12, -6, 0), lift: (-13, 3))
        case "⚡":
            // Éclair : deux flashs.
            return ReactionMotionProfile(scale: (1.3, 1.0, 1.16), angle: (-5, 5, 0, 0), flash: (0.2, 0.3))
        case "📡":
            // L'antenne balaie le ciel depuis son pied.
            return ReactionMotionProfile(scale: (1.12, 1.06, 1.05), angle: (-24, 18, -10, 6), pivot: .bottom)
        default:
            return ReactionMotionProfile()
        }
    }
}

/// iOS 16 : un rebond simple à chaque jeton.
private struct LegacyBounce: View {
    let label: Text
    let token: Int
    @State private var up = false

    var body: some View {
        label
            .scaleEffect(up ? 1.3 : 1)
            .onChangeCompat(of: token) { _, _ in
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { up = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { up = false }
                }
            }
    }
}
