import SwiftUI

// Effets signature de la DA SignalQuest : SQStoryRing (anneau de story),
// sqShimmer (pulsation des squelettes), sqLikePop (pop du like) et sqFadeUp (entrée des
// cards). Tous respectent Reduce Motion.

/// Anneau de story : liseré carmin statique de la forme de l'avatar, décollé de
/// lui (le décalage est porté par le padding du parent). Aucune animation
/// permanente.
struct SQStoryRing: View {
    var lineWidth: CGFloat = 3

    var body: some View {
        SQAvatarShape()
            .strokeBorder(SQColor.brandRed, lineWidth: lineWidth)
    }
}

/// Pulsation des squelettes de chargement Halo (`h-skel`) : opacité 1 → 0,5 → 1
/// en 2 s. Sous Reduce Motion, le squelette reste fixe.
private struct SQShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.5 : 1)
            .onAppear {
                guard let animation = SQMotion.repeating(
                    .easeInOut(duration: 1),
                    autoreverses: true,
                    reduceMotion: reduceMotion
                ) else { return }
                withAnimation(animation) {
                    dimmed = true
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

/// Translation légère des cartes au scroll (web `sqFadeUp`).
///
/// Le contenu reste toujours à opacité pleine. Une opacité de 25 % appliquée
/// aux éléments proches du bord du viewport faisait échouer le contraste et
/// pouvait rendre une carte durablement illisible tant qu'elle n'atteignait
/// pas exactement l'état `identity` du `scrollTransition`.
/// `scrollTransition` est iOS 17+ ; sur iOS 16 la card apparaît normalement.
private struct SQFadeUpModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if #available(iOS 17.0, *) {
            content.scrollTransition(.animated(SQMotion.standard), axis: .vertical) { view, transition in
                view
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
