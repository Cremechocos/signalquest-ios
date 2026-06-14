import SwiftUI

struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let variant: SQGlassBackground.Variant
    private let content: Content

    init(
        cornerRadius: CGFloat = SQRadius.xl,
        padding: CGFloat = SQSpace.lg,
        variant: SQGlassBackground.Variant = .regular,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.variant = variant
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .sqGlass(variant, cornerRadius: cornerRadius)
    }
}

struct GradientButton: View {
    enum Style { case primary, secondary, ghost }

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

    // Boutons éditoriaux : rouge plein (primary), encre-outline (secondary),
    // simple (ghost). Coins nets (radius 4), libellé Archivo Bold, hauteur 50
    // comme `.btn` de la landing.
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
                        .font(.system(size: 16, weight: .bold))
                }
                Text(title)
                    .font(SQType.button)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md + 3)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            }
        }
        .disabled(isBusy)
        .buttonStyle(SQPressButtonStyle())
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary, .ghost: return SQColor.label
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .primary: return AnyShapeStyle(SQColor.brandRed)
        case .secondary: return AnyShapeStyle(SQColor.surface)
        case .ghost: return AnyShapeStyle(Color.clear)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return .clear
        case .secondary: return SQColor.label
        case .ghost: return SQColor.separator
        }
    }

    private var borderWidth: CGFloat {
        switch style {
        case .primary: return 0
        case .secondary: return 2   // bordure 2px encre, signature éditoriale
        case .ghost: return 1
        }
    }
}

/// Léger enfoncement au tap (la landing fait un translateY au hover ; sur
/// mobile on traduit par un petit scale).
struct SQPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
