import SwiftUI

/// Thin abstraction over the iOS 26 Liquid Glass APIs. On iOS 26 we use the
/// native `.glassEffect(_:in:)` and `.glassEffectID`. We keep a graceful
/// fallback that mirrors the previous look-and-feel using `.ultraThinMaterial`.
struct SQGlassBackground: ViewModifier {
    enum Variant { case regular, prominent, tinted(Color) }

    let variant: Variant
    let cornerRadius: CGFloat
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.modifier(NativeGlass(variant: variant, cornerRadius: cornerRadius, interactive: interactive))
        } else {
            content.modifier(LegacyGlass(variant: variant, cornerRadius: cornerRadius))
        }
    }
}

@available(iOS 26.0, *)
private struct NativeGlass: ViewModifier {
    let variant: SQGlassBackground.Variant
    let cornerRadius: CGFloat
    let interactive: Bool

    func body(content: Content) -> some View {
        switch variant {
        case .regular:
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        case .prominent:
            content.glassEffect(.regular.interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        case .tinted(let color):
            content.glassEffect(.regular.tint(color).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        }
    }
}

private struct LegacyGlass: ViewModifier {
    let variant: SQGlassBackground.Variant
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay { shape.stroke(SQColor.separator, lineWidth: 1) }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .background {
                if case .tinted(let color) = variant {
                    color.opacity(0.16).clipShape(shape)
                }
            }
    }
}

extension View {
    /// Apply the SignalQuest glass look. Defaults to a regular Liquid Glass
    /// surface with a 22pt continuous corner radius.
    func sqGlass(
        _ variant: SQGlassBackground.Variant = .regular,
        cornerRadius: CGFloat = 22,
        interactive: Bool = false
    ) -> some View {
        modifier(SQGlassBackground(variant: variant, cornerRadius: cornerRadius, interactive: interactive))
    }
}
