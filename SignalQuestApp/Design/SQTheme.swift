import SwiftUI

/// Neutral, appearance-adaptive background. Replaces the previous always-dark
/// gradient and lets the iOS system light/dark setting drive the colorScheme.
struct SQBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            SQColor.bg.ignoresSafeArea()
            content
        }
        .tint(SQColor.brandRed)
    }
}

/// Hero background reserved for marquee screens (Auth, Speedtest). Renders a
/// soft brand wash in light mode and a deep navy gradient in dark mode.
struct SQHeroBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        ZStack {
            gradient.ignoresSafeArea()
            content
        }
        .tint(SQColor.brandRed)
    }

    private var gradient: LinearGradient {
        if colorScheme == .dark {
            // Papier sombre chaud de la landing (--paper #100E0A → --paper-2).
            return LinearGradient(
                colors: [Color(hex: 0x100E0A), Color(hex: 0x16130D)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Papier crème de la landing (--paper #F4F0E6 → --paper-2 #ECE7D8).
        return LinearGradient(
            colors: [Color(hex: 0xF4F0E6), Color(hex: 0xECE7D8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    func signalQuestBackground() -> some View {
        modifier(SQBackground())
    }

    func signalQuestHeroBackground() -> some View {
        modifier(SQHeroBackground())
    }
}

extension Text {
    func sqSectionTitle() -> some View {
        font(.title2.weight(.bold))
            .foregroundStyle(SQColor.label)
    }
}

/// Typographie de la DA éditoriale SignalQuest. Trois familles, comme la
/// landing : Archivo Expanded (display), Archivo (UI/labels), Public Sans
/// (corps). Tailles relatives aux styles système pour préserver Dynamic Type.
enum SQType {
    /// Gros titres de page — Archivo Expanded Black, tracé serré.
    static let display = SQFont.display(34, .black, relativeTo: .largeTitle)
    /// Titres de section — Archivo Expanded Bold.
    static let title = SQFont.display(22, .bold, relativeTo: .title2)
    /// Sous-titres / en-têtes de carte — Archivo SemiBold.
    static let heading = SQFont.archivo(17, .semibold, relativeTo: .headline)
    /// Corps de texte — Public Sans.
    static let body = SQFont.body(16, relativeTo: .body)
    static let callout = SQFont.body(15, relativeTo: .callout)
    static let subhead = SQFont.archivo(14, .medium, relativeTo: .subheadline)
    static let caption = SQFont.body(13, relativeTo: .footnote)
    /// Micro-labels MAJUSCULE tracés (kickers) — Archivo Bold.
    static let micro = SQFont.archivo(11, .bold, relativeTo: .caption2)
    /// Libellés de boutons — Archivo Bold.
    static let button = SQFont.archivo(15, .bold)
}

/// Kicker éditorial : petit label MAJUSCULE rouge à fort tracking, signature
/// de la landing (`.kicker`).
extension Text {
    func sqKicker() -> some View {
        self.font(SQType.micro)
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(SQColor.brandRed)
    }
}
