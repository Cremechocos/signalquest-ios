import SwiftUI

// Effets signature de la DA SignalQuest, portés de globals.css :
// .sq-ring (anneau conique rotatif), sqShimmer (squelettes), sqLikePop
// (pop du like) et sqFadeUp (entrée des cards). Tous respectent Reduce Motion.

/// Anneau conique orange→rose qui tourne lentement (web `.sq-ring`, 3 s).
/// Utilisé autour des avatars de stories non vues.
///
/// PERF-RING-01 : la rotation est pilotée par une animation Core Animation
/// `repeatForever` (render server, GPU) et NON par un `TimelineView` 30 fps. Un
/// `TimelineView` par anneau forçait SwiftUI à réévaluer la vue 30×/s pour CHAQUE
/// story non vue du rail (écran d'accueil) — drain CPU permanent. Le rendu est
/// identique (rotation linéaire, période 3 s), mais le coût CPU/SwiftUI est nul.
struct SQStoryRing: View {
    var lineWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ring
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }

    private var ring: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: [SQBrand.signatureStart, SQBrand.signatureEnd, SQBrand.signatureStart],
                    center: .center
                ),
                lineWidth: lineWidth
            )
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

/// Pop élastique du bouton like (web `sqLikePop`, 0,55 s). `keyframeAnimator`
/// est iOS 17+ ; repli iOS 16 = petit rebond d'échelle déclenché au changement.
private struct SQLikePopModifier<T: Equatable & Sendable>: ViewModifier {
    let trigger: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            let reduce = reduceMotion
            content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
                view.scaleEffect(reduce ? 1 : scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.35, duration: 0.2, spring: .snappy)
                    SpringKeyframe(0.92, duration: 0.15, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.2, spring: .bouncy)
                }
            }
        } else {
            content.modifier(SQLikePopFallbackModifier(trigger: trigger))
        }
    }
}

/// Repli iOS 16 du pop like : rebond d'échelle déclenché au changement du trigger.
private struct SQLikePopFallbackModifier<T: Equatable>: ViewModifier {
    let trigger: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChangeCompat(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { scale = 1.35 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { scale = 1 }
                }
            }
    }
}

/// Apparition fondu + translation des cards au scroll (web `sqFadeUp`).
/// `scrollTransition` est iOS 17+ ; sur iOS 16 la card apparaît normalement.
private struct SQFadeUpModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if #available(iOS 17.0, *) {
            content.scrollTransition(.animated(SQMotion.standard), axis: .vertical) { view, transition in
                view
                    .opacity(transition.isIdentity ? 1 : 0.25)
                    .offset(y: transition.isIdentity ? 0 : 14)
                    .scaleEffect(transition.isIdentity ? 1 : 0.98)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Squelette de chargement avec balayage lumineux.
    func sqShimmer() -> some View { modifier(SQShimmerModifier()) }

    /// Pop élastique déclenché à chaque changement de `trigger` (like, réaction).
    func sqLikePop(trigger: some Equatable & Sendable) -> some View { modifier(SQLikePopModifier(trigger: trigger)) }

    /// Entrée fade-up des cards dans un ScrollView.
    func sqFadeUp() -> some View { modifier(SQFadeUpModifier()) }
}
