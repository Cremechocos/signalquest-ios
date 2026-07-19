import SwiftUI

/// Carte douce de la DA « Crème & Terre cuite » : fond `SurfaceElevated`,
/// rayon 22 continu, ombre carte chaude. Ni bordure, ni glassmorphism.
/// (Nom historique conservé — c'était le conteneur « glass » de l'ancienne DA.)
struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    init(
        cornerRadius: CGFloat = SQRadius.xl,
        padding: CGFloat = SQSpace.lg + 2,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                SQColor.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .sqShadowCard()
    }
}

struct GradientButton: View {
    enum Style { case primary, secondary, ghost, accent, destructive }

    let title: String
    let systemImage: String?
    let isBusy: Bool
    let style: Style
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isBusy: Bool = false,
        style: Style = .primary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.style = style
        self.action = action
    }

    /// Backwards-compatible initializer accepting the previous `isProminent` flag.
    init(
        _ title: String,
        systemImage: String? = nil,
        isBusy: Bool = false,
        isProminent: Bool,
        action: @escaping () -> Void
    ) {
        self.init(title, systemImage: systemImage, isBusy: isBusy, style: isProminent ? .primary : .secondary, action: action)
    }

    // Boutons « Crème & Terre cuite » : capsules hauteur 56, libellé Bricolage
    // SemiBold 16. Primaire = encre pleine ; accent (action en cours / stop) =
    // brique ; secondaire = surface + ombre repos ; destructif = texte danger
    // sur teinte danger. Aucune bordure.
    var body: some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            HStack(spacing: SQSpace.sm + 2) {
                if isBusy {
                    ProgressView().tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(SQType.button)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .foregroundStyle(foreground)
            .background(background, in: Capsule(style: .continuous))
            .modifier(GradientButtonShadow(style: style))
        }
        .disabled(isBusy)
        .buttonStyle(SQPressButtonStyle())
    }

    private var foreground: Color {
        switch style {
        case .primary: return SQColor.onInk
        case .accent: return SQColor.onAccent
        case .secondary, .ghost: return SQColor.label
        case .destructive: return SQColor.danger
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .primary: return AnyShapeStyle(SQColor.label)
        case .accent: return AnyShapeStyle(SQColor.brandRed)
        case .secondary: return AnyShapeStyle(SQColor.surface)
        case .ghost: return AnyShapeStyle(Color.clear)
        case .destructive: return AnyShapeStyle(SQColor.dangerSoft)
        }
    }
}

/// Ombre portée par style de bouton : encre sous le primaire, brique sous
/// l'accent, repos sous le secondaire, rien sous ghost/destructif.
private struct GradientButtonShadow: ViewModifier {
    let style: GradientButton.Style

    func body(content: Content) -> some View {
        switch style {
        case .primary:
            content.shadow(color: SQColor.shadowDock, radius: 12, x: 0, y: 10)
        case .accent:
            content.sqShadowAccent()
        case .secondary:
            content.sqShadowSoft()
        case .ghost, .destructive:
            content
        }
    }
}

/// Léger enfoncement au tap (press = scale 0.97, 160 ms).
struct SQPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
