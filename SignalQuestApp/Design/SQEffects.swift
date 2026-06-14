import SwiftUI

// Effets signature de la DA SignalQuest, portés de globals.css :
// .sq-ring (anneau conique rotatif), sqShimmer (squelettes), sqLikePop
// (pop du like) et sqFadeUp (entrée des cards). Tous respectent Reduce Motion.

/// Anneau conique orange→rose qui tourne lentement (web `.sq-ring`, 3 s).
/// Utilisé autour des avatars de stories non vues.
struct SQStoryRing: View {
    var lineWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ring(rotation: .zero)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ring(rotation: .degrees((t.truncatingRemainder(dividingBy: 3)) / 3 * 360))
            }
        }
    }

    private func ring(rotation: Angle) -> some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: [SQBrand.signatureStart, SQBrand.signatureEnd, SQBrand.signatureStart],
                    center: .center
                ),
                lineWidth: lineWidth
            )
            .rotationEffect(rotation)
    }
}

/// Balayage lumineux des squelettes de chargement (web `sqShimmer`, 1,6 s).
private struct SQShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.6)
        } else {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.35), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                    }
                }
                .clipped()
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
    }
}

/// Pop élastique du bouton like (web `sqLikePop`, 0,55 s).
private struct SQLikePopModifier<T: Equatable>: ViewModifier {
    let trigger: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let reduce = reduceMotion
        return content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
            view.scaleEffect(reduce ? 1 : scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(1.35, duration: 0.2, spring: .snappy)
                SpringKeyframe(0.92, duration: 0.15, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.2, spring: .bouncy)
            }
        }
    }
}

/// Apparition fondu + translation des cards au scroll (web `sqFadeUp`).
private struct SQFadeUpModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.animated(SQMotion.standard), axis: .vertical) { view, transition in
                view
                    .opacity(transition.isIdentity ? 1 : 0.25)
                    .offset(y: transition.isIdentity ? 0 : 14)
                    .scaleEffect(transition.isIdentity ? 1 : 0.98)
            }
        }
    }
}

extension View {
    /// Squelette de chargement avec balayage lumineux.
    func sqShimmer() -> some View { modifier(SQShimmerModifier()) }

    /// Pop élastique déclenché à chaque changement de `trigger` (like, réaction).
    func sqLikePop(trigger: some Equatable) -> some View { modifier(SQLikePopModifier(trigger: trigger)) }

    /// Entrée fade-up des cards dans un ScrollView.
    func sqFadeUp() -> some View { modifier(SQFadeUpModifier()) }
}
