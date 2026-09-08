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

/// Actions partagées : primaire encre, accent terracotta ; API historique conservée.
struct GradientButton: View {
    enum Style { case primary, secondary, ghost, accent, destructive }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let systemImage: String?
    let isBusy: Bool
    let style: Style
    let allowsMultiline: Bool
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isBusy: Bool = false,
        style: Style = .primary,
        allowsMultiline: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.style = style
        self.allowsMultiline = allowsMultiline
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
                Text(LocalizedStringKey(title))
                    .font(SQType.button)
                    .lineLimit(allowsMultiline || dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
            .frame(maxWidth: .infinity)
            .frame(minHeight: SQSpace.primaryActionHeight)
            .foregroundStyle(foreground)
            .background {
                switch style {
                case .primary, .accent:
                    Capsule(style: .continuous).fill(background)
                default:
                    RoundedRectangle(cornerRadius: SQRadius.control, style: .continuous)
                        .fill(background)
                }
            }
            .overlay {
                if style == .secondary {
                    RoundedRectangle(cornerRadius: SQRadius.control, style: .continuous)
                        .strokeBorder(SQColor.controlOutline, lineWidth: 1)
                }
            }
        }
        .disabled(isBusy)
        .buttonStyle(SQPressButtonStyle())
    }

    private var foreground: Color {
        guard isEnabled else { return SQColor.labelSecondary }
        switch style {
        case .primary: return SQColor.onInk
        case .accent: return SQColor.onAccent
        case .secondary, .ghost: return SQColor.label
        case .destructive: return SQColor.danger
        }
    }

    private var background: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(SQColor.surfaceMuted) }
        switch style {
        case .primary: return AnyShapeStyle(SQColor.label)
        case .accent: return AnyShapeStyle(SQColor.accent)
        case .secondary: return AnyShapeStyle(SQColor.surface)
        case .ghost: return AnyShapeStyle(Color.clear)
        case .destructive: return AnyShapeStyle(SQColor.dangerSoft)
        }
    }
}

/// Retour tactile visuel court, sans réduction sous Reduce Motion.
struct SQPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
