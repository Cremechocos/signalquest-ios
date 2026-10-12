import SwiftUI

/// Fond « verre » des contrôles posés sur une carte (Carte, Drive Test) :
/// verre dépoli teinté, le seul verre de la DA.
func sqMapGlassBackground<S: InsettableShape>(_ shape: S) -> some View {
    shape
        .fill(SQColor.surfaceGlass)
        .background(.ultraThinMaterial, in: shape)
}

/// Élévation d'une carte : `card` pour les cartes de contenu, `rest` (ombre
/// repos) pour les rangées et les petites tuiles.
enum SQCardElevation {
    case card
    case rest
}

extension View {
    /// Fond de carte : surface, rayon continu, ombre carte. En « Noir intense »,
    /// carte et fond sont tous deux noirs et l'ombre s'efface : le liseré prend le
    /// relais, sans quoi les cartes se fondaient dans le fond (TRX-09, SOC-26).
    /// Hors OLED il est transparent : jamais ombre et bordure à la fois.
    func sqCardBackground(
        _ fill: Color = SQColor.surface,
        cornerRadius: CGFloat = SQRadius.xl,
        elevation: SQCardElevation = .card
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(fill, in: shape)
            .overlay { shape.strokeBorder(SQOledPalette.cardStroke, lineWidth: 1) }
            .modifier(SQCardShadow(elevation: elevation))
    }

    /// Fond plein posé directement (tuile, chip, pastille, bouton), sans ombre.
    /// En « Noir intense », `surface` et `surfaceMuted` sont noirs comme le fond :
    /// même liseré que `sqCardBackground`, sinon la forme disparaît. Hors OLED,
    /// identique à `background(fill, in: shape)`.
    nonisolated func sqSurface<S: InsettableShape>(_ fill: Color = SQColor.surface, in shape: S) -> some View {
        background(fill, in: shape)
            .overlay { shape.strokeBorder(SQOledPalette.cardStroke, lineWidth: 1).allowsHitTesting(false) }
    }

    /// Champ de saisie : fond tuile et filet de 1 pt dans les quatre modes. Le fond
    /// tuile a la couleur de la page ; sans le filet, un champ posé dessus disparaît.
    nonisolated func sqFieldSurface<S: InsettableShape>(in shape: S) -> some View {
        background(SQColor.surfaceMuted, in: shape)
            .overlay { shape.strokeBorder(SQOledPalette.fieldStroke, lineWidth: 1).allowsHitTesting(false) }
    }
}

private struct SQCardShadow: ViewModifier {
    let elevation: SQCardElevation

    @ViewBuilder
    func body(content: Content) -> some View {
        switch elevation {
        case .card: content.sqShadowCard()
        case .rest: content.sqShadowSoft()
        }
    }
}

/// Carte Halo : surface blanche posée sur le papier, 22 pt de coins, 14 pt de
/// marge, ombre douce, aucune bordure hors « Noir intense » et mode terrain.
/// (Nom historique conservé — c'était le conteneur « glass » d'une ancienne DA.)
struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    init(
        cornerRadius: CGFloat = SQRadius.xl,
        padding: CGFloat = SQSpace.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .sqCardBackground(cornerRadius: cornerRadius)
    }
}

/// Bouton pilule Halo (planche P2-33, « Boutons et liens ») ; nom historique conservé.
/// - `primary` : pilule d'encre, l'action principale de l'écran (une seule).
/// - `secondary` : fond carte et filet ; `ghost` : sans fond, encre secondaire.
/// - `destructive` : fond carte, filet et texte rouge, pour supprimer depuis une page ;
///   `destructiveFill` (rouge plein) ne sert que dans la confirmation d'un geste
///   irréversible.
/// - `glass` sur une photo ou une vidéo ; `inverse` sur un bandeau d'encre.
/// - `accent` est conservé pour l'API : Halo ne remplit jamais un bouton de carmin,
///   il se dessine donc comme `primary`.
struct GradientButton: View {
    enum Style { case primary, secondary, ghost, accent, destructive, destructiveFill, glass, inverse }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

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
            HStack(spacing: SQSpace.sm) {
                if isBusy {
                    SQSpinner().tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(SQFont.body(15, .semibold, relativeTo: .body))
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
            // Mode terrain : `controlSize(.large)` posé à la racine agrandit la cible.
            .frame(minHeight: controlSize == .large ? SQSpace.primaryActionHeight + 8 : SQSpace.primaryActionHeight)
            .foregroundStyle(foreground)
            .background(background, in: Capsule(style: .continuous))
            .overlay {
                if let line = outline {
                    Capsule(style: .continuous).strokeBorder(line, lineWidth: 1)
                }
            }
            // Désactivé : le bouton garde son dessin, atténué (Halo : 46 %).
            .opacity(isEnabled ? 1 : 0.46)
        }
        .disabled(isBusy)
        .buttonStyle(SQPressButtonStyle(scale: 0.97))
    }

    private var foreground: Color {
        switch style {
        case .primary, .accent: return SQColor.onInk
        case .secondary: return SQColor.label
        case .ghost: return SQColor.ink2
        case .destructive: return SQColor.dangerInk
        case .destructiveFill: return SQColor.bg
        case .glass: return SQColor.onGlass
        case .inverse: return SQColor.label
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .primary, .accent: return AnyShapeStyle(SQColor.label)
        case .secondary, .destructive: return AnyShapeStyle(SQColor.surface)
        case .ghost: return AnyShapeStyle(Color.clear)
        case .destructiveFill: return AnyShapeStyle(SQColor.danger)
        case .glass: return AnyShapeStyle(SQColor.glass)
        case .inverse: return AnyShapeStyle(SQColor.onInk)
        }
    }

    /// Filet des boutons posés sur une surface : `--h-hair`, encre en mode terrain.
    private var outline: Color? {
        switch style {
        case .secondary, .destructive: return SQColor.separator
        case .glass: return SQColor.glassLine
        case .primary, .accent, .ghost, .destructiveFill, .inverse:
            // Les aplats pleins n'ont pas de filet, sauf en « Noir intense ».
            return SQOledPalette.cardStroke
        }
    }
}

/// Retour tactile visuel court, sans réduction sous Reduce Motion.
struct SQPressButtonStyle: ButtonStyle {
    /// 0,985 pour les cartes et les lignes ; les boutons capsules prennent le
    /// 0,97 de DESIGN.md, plus lisible sur une petite surface.
    var scale: CGFloat = 0.985
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
