import SwiftUI

/// Centralised animation tokens. Use these instead of hand-tuned springs so the
/// whole app feels coherent.
enum SQMotion {
    // Les courbes `.snappy/.smooth/.bouncy` et `spring(duration:bounce:)` sont
    // iOS 17+. On les garde sur iOS 17+ et on retombe sur des springs iOS 16
    // visuellement équivalentes (rétro-compat iOS 16, sans changer le ressenti
    // sur iOS 17/18/26).
    static var snappy: Animation {
        if #available(iOS 17.0, *) { return .snappy(duration: 0.32, extraBounce: 0.05) }
        return .spring(response: 0.32, dampingFraction: 0.80)
    }
    static var smooth: Animation {
        if #available(iOS 17.0, *) { return .smooth(duration: 0.45) }
        return .spring(response: 0.45, dampingFraction: 1.0)
    }
    static var bouncy: Animation {
        if #available(iOS 17.0, *) { return .bouncy(duration: 0.55, extraBounce: 0.15) }
        return .spring(response: 0.55, dampingFraction: 0.66)
    }
    static let micro: Animation = .interpolatingSpring(stiffness: 320, damping: 24)

    /// A long, soft transition used for big screen changes (sheet → detail).
    static let heroSpring: Animation = .interpolatingSpring(stiffness: 220, damping: 26)

    // Durées Material-expressive de la DA web (globals.css --motion-*).
    /// Micro-interactions : hover, pressed, toggles (web 160 ms).
    static let fast: Animation = .easeOut(duration: 0.16)
    /// Transitions courantes : apparition de cards, fades (web 250 ms).
    static let standard: Animation = .easeInOut(duration: 0.25)
    /// Transitions accentuées : sheets, panneaux (web 400 ms, courbe emphasized).
    static var emphasized: Animation {
        if #available(iOS 17.0, *) { return .spring(duration: 0.4, bounce: 0.12) }
        return .spring(response: 0.4, dampingFraction: 0.82)
    }
    /// Grandes entrées de scène (web 600 ms).
    static var slow: Animation {
        if #available(iOS 17.0, *) { return .spring(duration: 0.6, bounce: 0.18) }
        return .spring(response: 0.6, dampingFraction: 0.78)
    }

    /// Returns the animation, or `nil` when Reduce Motion is enabled. Use inside
    /// `withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { ... }`.
    static func resolve(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension View {
    /// Mark this view as a transition source for a matched zoom effect, when
    /// the SwiftUI / iOS version supports it. Falls back to a no-op below 18.
    @ViewBuilder
    func sqMatchedTransitionSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Apply a zoom navigation transition for the given source, when available.
    @ViewBuilder
    func sqZoomNavigationTransition(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }

    /// Animation that is automatically suppressed when Reduce Motion is enabled.
    /// Prefer this over `.animation(_:value:)` so motion honours accessibility.
    func sqAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(SQReduceMotionAnimation(animation: animation, value: value))
    }
}

private struct SQReduceMotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
