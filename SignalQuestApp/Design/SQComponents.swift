import SwiftUI
import MapKit
import UIKit

/// Libellé visuel persistant ; le champ conserve son propre nom VoiceOver.
struct SQFormFieldLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(SQFont.body(14, .bold, relativeTo: .subheadline))
            .foregroundStyle(SQColor.label)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}

enum SQFormPrompt {
    static func text(_ title: LocalizedStringKey) -> Text {
        Text(title).foregroundColor(SQColor.labelSecondary)
    }
}

struct TechBadge: View {
    let text: String
    var color: Color = SQColor.brandRed

    var body: some View {
        Text(text)
            .font(SQFont.body(12, .semibold))
            .padding(.horizontal, SQSpace.sm2)
            .padding(.vertical, SQSpace.xs2)
            .background(color.opacity(0.13), in: Capsule(style: .continuous))
            .foregroundStyle(SQColor.label)
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SQColor.brandRed)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)
                Text(value)
                    .font(SQFont.display(15, .bold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous).strokeBorder(SQOledPalette.cardStroke, lineWidth: 1) }
        // VoiceOver : lire « titre : valeur » d'un bloc plutôt que l'icône + 2 textes.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityValue(value)
    }
}

/// Forme des avatars Halo : carré à coins de 30 % (« squircle »), quelle que
/// soit la taille. L'anneau de story reprend la même forme.
struct SQAvatarShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) * 0.3 - inset
        return RoundedRectangle(cornerRadius: max(0, radius), style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> SQAvatarShape {
        SQAvatarShape(inset: inset + amount)
    }
}

/// Avatar Halo : photo ou initiale sur la puce, coins à 30 %.
struct SQAvatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            SQAvatarShape().fill(SQColor.chip)
            if let url {
                RemoteImage(url: url, maxDimension: size, contentMode: .fill) {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(SQAvatarShape())
    }

    private var initials: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(SQFont.display(max(12, size * 0.36), .bold, relativeTo: .title3))
            .foregroundStyle(SQColor.chipInk)
            .accessibilityHidden(true)
            .accessibilityIdentifier("feed.avatar.initial")
    }
}

    // `Text(String)` NE LOCALISE PAS — seule la surcharge `LocalizedStringKey`
    // le fait. Un libellé qui transite par un paramètre `String` contourne donc
    // le catalogue, ce qui laissait ces états en français une fois l'app passée
    // en anglais. `LocalizedStringKey(_:)` rétablit la recherche pour les
    // littéraux, et rend le texte inchangé quand la clé est absente — ce qui est
    // exactement le comportement voulu pour les quelques appels qui passent un
    // message venu du serveur.
struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    var messageColor: Color = SQColor.labelSecondary

    var body: some View {
        VStack(spacing: SQSpace.sm) {
            SQIconPastille(systemImage: systemImage, size: 46, tint: SQColor.chipInk, fill: SQColor.chip,
                           font: SQFont.body(22, .medium, relativeTo: .title3))
                .padding(.bottom, SQSpace.xs)
            Text(LocalizedStringKey(title))
                .font(SQType.stateTitle)
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey(message))
                .font(SQType.callout)
                .foregroundStyle(messageColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.xxl + 2)
        // Un état vide se lit d'un bloc : titre puis explication. Le laisser en
        // trois éléments distincts obligerait à balayer trois fois pour une
        // information unique. Traiter ce composant couvre ses ~28 sites d'usage.
        // `sqCard` prend des `String` : sans recherche explicite, VoiceOver
        // énonçait le titre FRANÇAIS dans une app anglaise, alors même que le
        // texte affiché, lui, était traduit. `NSLocalizedString` accepte une clé
        // d'exécution — ce que `String(localized:)` ne fait pas.
        .sqCard(
            label: NSLocalizedString(title, comment: ""),
            value: NSLocalizedString(message, comment: "")
        )
    }
}

/// Échec d'une action, dit près de l'action et annoncé à VoiceOver : une
/// bannière globale passe sous les feuilles, et un échec avalé laisse croire
/// que l'action a réussi.
struct SQInlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(SQType.caption)
            .foregroundStyle(SQColor.dangerInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("state.inlineError")
            .task(id: message) {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
    }
}

/// Une ligne en taille normale ; en très grand texte (tailles d'accessibilité),
/// jusqu'à trois lignes plutôt qu'un texte coupé en « … » (TRX-12).
private struct SQSingleLine: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
    }
}

extension View {
    func sqSingleLine() -> some View { modifier(SQSingleLine()) }
}

/// Roue d'activité du design system. Une `SQSpinner()` nue ne disait rien
/// d'utile à VoiceOver : celle-ci s'annonce « Chargement… » (TRX-10).
struct SQSpinner: View {
    var body: some View {
        ProgressView()
            .accessibilityLabel(Text("Chargement…"))
    }
}

struct ErrorStateView: View {
    let title: String
    let message: String
    var retry: (() -> Void)?

    /// Une panne de connexion n'est pas une erreur de l'écran : elle se dit
    /// « Hors ligne », avec son icône, sur tous les écrans à la fois (TRX-10).
    private var isOffline: Bool { message == SQOfflineText.message }

    var body: some View {
        GlassCard {
            VStack(spacing: SQSpace.sm) {
                SQIconPastille(
                    systemImage: isOffline ? "wifi.slash" : "exclamationmark.triangle",
                    size: 46,
                    tint: isOffline ? SQColor.warning : SQColor.dangerInk,
                    fill: isOffline ? SQColor.warningSoft : SQColor.dangerSoft,
                    font: SQFont.body(22, .medium, relativeTo: .title3)
                )
                .padding(.bottom, SQSpace.xs)
                Text(LocalizedStringKey(isOffline ? "Hors ligne" : title))
                    .font(SQType.stateTitle)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("state.error.title")
                Text(LocalizedStringKey(message))
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                // Volontairement PAS de `.sqCard` ici : regrouper ce bloc faisait
                // échouer `testFiveTabsAndPrimaryStatesWithMockAuth`, qui ne
                // retrouvait plus `feed.header` ni le bouton « Messages » —
                // pourtant des FRÈRES de cet état d'erreur, pas des enfants.
                // Mécanisme non élucidé ; le gain (3 arrêts de balayage en 1)
                // ne valait pas de livrer une régression inexpliquée.
                if let retry {
                    // Bouton secondaire du design system (planche Halo, « Retours »).
                    GradientButton(String(localized: "Réessayer"), systemImage: "arrow.clockwise",
                                   style: .secondary, action: retry)
                        .accessibilityIdentifier("state.error.retry")
                        .padding(.top, SQSpace.sm)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Hors ligne : l'écran se recharge seul au retour du réseau ; « Réessayer »
        // reste là pour qui n'attend pas.
        .onReceive(NotificationCenter.default.publisher(for: .sqNetworkRestored)) { _ in
            guard isOffline, let retry else { return }
            retry()
        }
    }
}

/// Bandeau d'avertissement VPN affiché sur les écrans Speedtest et Drive Test.
///
/// Sous tunnel VPN, l'IP publique reflète le VPN et non le réseau réel : l'app ne
/// peut pas détecter le vrai opérateur, et le test n'est donc PAS publié sur la
/// carte communautaire (il fausserait les données). On le signale clairement.
struct VPNWarningBanner: View {
    var message = String(localized: "VPN actif : ton opérateur ne peut pas être détecté, ce test ne sera pas publié sur la carte.")

    var body: some View {
        HStack(alignment: .top, spacing: SQSpace.sm) {
            Image(systemName: "lock.shield.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(SQColor.warning)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(message))
                .font(.caption.weight(.medium))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Avertissement.") + Text(verbatim: " ") + Text(LocalizedStringKey(message)))
    }
}

/// Squelette de chargement du feed : imite la structure réelle d'une
/// `FeedItemCard` (avatar + auteur, média, texte, barre d'actions) pour éviter
/// le saut de mise en page à l'arrivée des données. À combiner avec `sqShimmer()`.
struct LoadingSkeleton: View {
    var count: Int = 3
    var showsMedia: Bool = true

    var body: some View {
        VStack(spacing: SQSpace.md2) {
            ForEach(0..<count, id: \.self) { _ in
                card
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.sm) {
                Circle().fill(SQColor.skeleton).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBlock(width: 130, height: 12)
                    SkeletonBlock(width: 84, height: 10)
                }
                Spacer(minLength: 0)
            }
            if showsMedia {
                SkeletonBlock(height: 150, radius: SQRadius.lg)
            }
            SkeletonBlock(height: 11)
            SkeletonBlock(width: 220, height: 11)
            HStack(spacing: SQSpace.lg) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock(width: 46, height: 14, radius: SQRadius.sm)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        // Liseré visible UNIQUEMENT en mode OLED, où la carte et le fond sont tous
        // deux noirs : sans lui, les tuiles fusionneraient en un seul aplat.
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                .strokeBorder(SQOledPalette.cardStroke, lineWidth: 1)
        }
        .sqShadowCard()
    }
}

/// Bloc gris arrondi de base d'un squelette (largeur pleine par défaut).
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = SQRadius.sm

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(SQColor.skeleton)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Squelette d'une liste de conversations : avatar + titre + aperçu, calqué sur
/// `conversationRow`. À combiner avec `sqShimmer()`.
struct ConversationListSkeleton: View {
    var count: Int = 7

    var body: some View {
        VStack(spacing: SQSpace.lg) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: SQSpace.md) {
                    Circle().fill(SQColor.skeleton).frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: 150, height: 13)
                        SkeletonBlock(width: 220, height: 11)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 34, height: 10)
                }
            }
        }
    }
}

// MARK: - New primitives

/// Pastille d'icône circulaire Halo : icône à l'encre secondaire sur la puce
/// (`--h-chip`). Le carmin reste à l'identité et à la sélection.
/// Décorative d'office (`accessibilityHidden`) — le libellé voisin porte le sens.
/// Sans `font`, l'icône fait 40 % du diamètre en semibold ; passer `font` pour
/// garder un rendu historique (Dynamic Type, taille ou graisse précises).
/// Pour une pastille carrée, voir `SQRadius.iconTile`.
struct SQIconPastille: View {
    let systemImage: String
    /// Diamètre de la pastille.
    var size: CGFloat = 40
    /// Sur `accentSoft`, préférer `SQColor.accentInk` quand l'icône porte du sens.
    var tint: Color = SQColor.ink2
    var fill: Color = SQColor.chip
    var font: Font? = nil

    var body: some View {
        Image(systemName: systemImage)
            .font(font ?? .system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Barre de recherche Halo (`SearchField`) : 44 pt, 13 pt de coins, fond carte
/// et filet de 1 pt, loupe 16 pt.
struct SQSearchField: View {
    @Binding var text: String
    /// Clé du catalogue, traduite à l'affichage : passée en `String`, elle
    /// restait en français dans l'app anglaise (TRX-06).
    var placeholder: String = "Rechercher"
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "magnifyingglass")
                .font(SQFont.body(16, .medium, relativeTo: .body))
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
            TextField(LocalizedStringKey(placeholder), text: $text)
                .font(SQType.body)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .foregroundStyle(SQColor.label)
            if !text.isEmpty {
                Button {
                    text = ""
                    Haptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SQColor.labelTertiary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Effacer la recherche"))
            }
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, text.isEmpty ? SQSpace.md : SQSpace.xs)
        // Hauteur minimale et non fixe : en grande taille de texte, le champ
        // coupait sa propre saisie (TRX-12).
        .frame(minHeight: 44)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(SQOledPalette.fieldStroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// Sélecteur segmenté Halo (`Segmented`) : piste `segTrack` à 14 pt de coins,
/// segment actif en pastille pleine (`segThumb`), jamais un soulignement.
/// Au téléphone, la piste défile quand les segments dépassent la largeur.
struct SQSegmentedFilter<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String, icon: String?)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    segment(option)
                }
            }
            .padding(SQSpace.xs)
            .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .padding(.horizontal)
        }
    }

    private func segment(_ option: (value: Value, label: String, icon: String?)) -> some View {
        let isSelected = option.value == selection
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : SQMotion.snappy) { selection = option.value }
        } label: {
            HStack(spacing: SQSpace.xs) {
                if let icon = option.icon {
                    Image(systemName: icon).accessibilityHidden(true)
                }
                Text(LocalizedStringKey(option.label))
            }
            .font(SQType.chip)
            .foregroundStyle(isSelected ? SQColor.label : SQColor.labelSecondary)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(SQColor.segThumb)
                        .shadow(color: SQColor.shadowSoft, radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Puce de filtre Halo (`FilterChip`) : inactive sur la puce (`--h-chip`), active
/// en carmin doux au texte carmin, sans ombre ni bordure hors OLED. Zone de
/// toucher de 44 pt, état annoncé par VoiceOver (`.isSelected`).
///
/// Une seule implémentation pour tous les filtres en capsule : les variantes
/// passent par les paramètres (teinte du fond actif, point de couleur, coche,
/// pleine largeur) plutôt que par une copie locale.
struct SQChip: View {
    let label: String
    var systemImage: String? = nil
    var isSelected = false
    /// Remplace `systemImage` quand la pastille est active (ex. une coche : l'état
    /// ne repose alors pas sur la seule couleur).
    var selectedSystemImage: String? = nil
    /// Point de couleur en tête (opérateur) ; il prend l'encre de l'état actif.
    var dot: Color? = nil
    /// Fond et encre de l'état actif : carmin doux et carmin par défaut. Un fond
    /// d'opérateur demande l'encre calculée (`SQBrand.operatorBadgeForeground`).
    var selectedFill: Color = SQColor.accentSoft
    var selectedInk: Color = SQColor.accentInk
    /// Fond de l'état inactif, posé par `sqSurface` (liseré en « Noir intense »).
    var restFill: Color = SQColor.chip
    /// Occupe la largeur proposée (grilles de filtres) au lieu de celle du texte.
    var fillsWidth = false
    /// Texte VoiceOver à la place du libellé affiché (clés du catalogue).
    var spokenLabel: LocalizedStringKey? = nil
    var spokenValue: LocalizedStringKey? = nil
    var spokenHint: LocalizedStringKey? = nil
    let action: () -> Void

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let ink = !isEnabled ? SQColor.labelSecondary : isSelected ? selectedInk : SQColor.chipInk
        let leadingImage = isSelected ? (selectedSystemImage ?? systemImage) : systemImage
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.xs2) {
                if let leadingImage {
                    Image(systemName: leadingImage)
                        .accessibilityHidden(true)
                } else if let dot {
                    Circle()
                        .fill(isSelected ? selectedInk : dot)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                // Clé du catalogue : un libellé passé en `String` restait en
                // français dans l'app anglaise.
                Text(LocalizedStringKey(label))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(SQType.chip)
            // Un libellé d'un seul caractère (« 1 », « 5 ») reste une vraie capsule.
            .frame(minWidth: SQSpace.lg)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .foregroundStyle(ink)
            .sqSurface(isSelected ? selectedFill : restFill, in: Capsule(style: .continuous))
            .frame(minWidth: 44, minHeight: controlSize == .large ? 50 : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.97))
        .sqChipAccessibility(label: spokenLabel, value: spokenValue, hint: spokenHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    /// Les valeurs absentes ne posent rien : un libellé vide écraserait celui du texte.
    @ViewBuilder
    func sqChipAccessibility(label: LocalizedStringKey?, value: LocalizedStringKey?, hint: LocalizedStringKey?) -> some View {
        let labeled = Group { if let label { self.accessibilityLabel(label) } else { self } }
        let valued = Group { if let value { labeled.accessibilityValue(value) } else { labeled } }
        if let hint { valued.accessibilityHint(hint) } else { valued }
    }
}

/// Compact "icon + value + optional label" chip for inline stats.
struct SQChipMetric: View {
    let value: String
    var label: String? = nil
    var systemImage: String? = nil

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: SQSpace.xs2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(SQColor.brandRed)
                }
                Text(value)
                    .font(SQFont.display(17, .bold, relativeTo: .headline))
                    .foregroundStyle(SQColor.label)
            }
            if let label {
                Text(LocalizedStringKey(label))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Lightweight section header — title only, optional trailing action.
struct SQSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title))
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            Spacer()
            trailing()
        }
    }
}

// MARK: - Données et listes Halo (planche P2-33)

/// Chiffre clé Halo (`Stat`) : surtitre, valeur 26/800 et unité 14/600 grise.
/// Sans fond : se pose dans une carte ou une tuile.
struct SQStatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text(LocalizedStringKey(label)).sqKicker()
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                Text(value)
                    .font(SQType.metricMedium)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                if let unit {
                    Text(LocalizedStringKey(unit))
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            if let caption {
                Text(LocalizedStringKey(caption))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Ligne clé-valeur Halo (`KeyValue`) : libellé gris, points de conduite, valeur
/// en 600. En très grand texte, la valeur passe sous le libellé.
struct SQFactRow: View {
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    labelText
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    labelText
                    SQDotLeader()
                        .frame(height: 1)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    valueText
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(LocalizedStringKey(label))
            .font(SQType.subhead(.regular))
            .foregroundStyle(SQColor.labelSecondary)
    }

    private var valueText: some View {
        Text(value)
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.label)
            // Chiffres tabulaires : sans eux, la police ne dessine pas l'espace
            // fine des milliers (« 1180 » au lieu de « 1 180 »).
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Points de conduite d'une ligne clé-valeur (`--h-dots`).
struct SQDotLeader: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(SQColor.dots, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
        }
        .frame(minWidth: SQSpace.lg)
        .accessibilityHidden(true)
    }
}

/// Rangée de liste Halo (`ListRow`) : tuile d'icône 38 pt à 12 pt de coins, titre
/// 13/600, sous-titre 12 gris, pas de séparateur. 44 pt de hauteur au moins.
struct SQListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: SQSpace.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(SQFont.body(16, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.ink2)
                    .frame(width: 38, height: 38)
                    .background(SQColor.chip, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(LocalizedStringKey(title))
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Encadré Halo (`Notice`) : 14 pt de coins ; neutre sur la tuile avec un filet,
/// sinon sur un ton doux. Le texte reste à l'encre, l'icône porte la teinte.
struct SQNotice: View {
    enum Tone { case neutral, brand, success, warning, danger }

    let message: String
    var title: String? = nil
    var systemImage: String? = nil
    var tone: Tone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm2) {
            Image(systemName: systemImage ?? defaultIcon)
                .font(SQFont.body(15, .semibold, relativeTo: .body))
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                if let title {
                    Text(LocalizedStringKey(title))
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                }
                Text(LocalizedStringKey(message))
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SQSpace.md)
        .background(fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .strokeBorder(tone == .neutral ? SQOledPalette.fieldStroke : SQOledPalette.cardStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var defaultIcon: String {
        switch tone {
        case .neutral, .brand: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning, .danger: return "exclamationmark.triangle"
        }
    }

    private var fill: Color {
        switch tone {
        case .neutral: return SQColor.surfaceMuted
        case .brand: return SQColor.accentSoft
        case .success: return SQColor.successSoft
        case .warning: return SQColor.warningSoft
        case .danger: return SQColor.dangerSoft
        }
    }

    private var iconTint: Color {
        switch tone {
        case .neutral: return SQColor.ink2
        case .brand: return SQColor.accentInk
        case .success: return SQColor.success
        case .warning: return SQColor.warning
        case .danger: return SQColor.dangerInk
        }
    }
}

/// Compteur Halo (`CountBadge`) : fond d'encre, chiffre couleur papier, 6 pt de coins.
struct SQCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(SQType.micro(.bold))
            .monospacedDigit()
            .foregroundStyle(SQColor.bg)
            .padding(.horizontal, SQSpace.xs2)
            .frame(minWidth: 20, minHeight: 20)
            .background(SQColor.label, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - File globale de notifications in-app

enum SQInAppNotificationVariant {
    case info, success, warning, error
}

enum SQInAppNotificationPriority: Int {
    case normal = 0
    case high = 1
    case urgent = 2
}

struct SQInAppNotificationItem: Identifiable {
    let id: UUID
    let title: String?
    let body: String
    let variant: SQInAppNotificationVariant
    let duration: Duration
    let actionLabel: String?
    let action: (@MainActor () -> Void)?
    let priority: SQInAppNotificationPriority
    let canBePreempted: Bool

    init(
        id: UUID = UUID(),
        title: String? = nil,
        body: String,
        variant: SQInAppNotificationVariant = .info,
        duration: Duration = .seconds(3),
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil,
        priority: SQInAppNotificationPriority? = nil,
        canBePreempted: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.variant = variant
        self.duration = duration
        self.actionLabel = actionLabel
        self.action = action
        self.priority = priority ?? {
            switch variant {
            case .info, .success: return .normal
            case .warning: return .high
            case .error: return .urgent
            }
        }()
        // Une erreur garde sa fenêtre de lecture même si d'autres feedbacks arrivent.
        self.canBePreempted = canBePreempted ?? (variant != .error)
    }
}

struct SQQueuedInAppNotification {
    let sequence: UInt64
    let item: SQInAppNotificationItem
}

/// Algorithme pur : priorité décroissante, FIFO à priorité égale et aucune
/// préemption d'un Undo ou d'une erreur visible.
struct SQInAppNotificationQueue {
    private var nextSequence: UInt64 = 0
    private var pending: [SQQueuedInAppNotification] = []
    private(set) var current: SQQueuedInAppNotification?

    @discardableResult
    mutating func offer(_ item: SQInAppNotificationItem) -> Bool {
        let incoming = SQQueuedInAppNotification(sequence: nextSequence, item: item)
        nextSequence &+= 1
        guard let shown = current else {
            current = incoming
            return true
        }
        if shown.item.canBePreempted, incoming.item.priority.rawValue > shown.item.priority.rawValue {
            pending.append(shown)
            current = incoming
            sortPending()
            return true
        }
        pending.append(incoming)
        sortPending()
        return false
    }

    @discardableResult
    mutating func dismiss(id: UUID) -> SQQueuedInAppNotification? {
        guard current?.item.id == id else { return current }
        current = pending.isEmpty ? nil : pending.removeFirst()
        return current
    }

    var pendingItems: [SQInAppNotificationItem] { pending.map(\.item) }

    private mutating func sortPending() {
        pending.sort {
            if $0.item.priority != $1.item.priority {
                return $0.item.priority.rawValue > $1.item.priority.rawValue
            }
            return $0.sequence < $1.sequence
        }
    }
}

@MainActor
final class SQInAppNotificationCenter: ObservableObject {
    @Published private(set) var current: SQInAppNotificationItem?

    private var queue = SQInAppNotificationQueue()
    private var timeoutTask: Task<Void, Never>?

    func show(_ item: SQInAppNotificationItem) {
        if queue.offer(item) { presentCurrent() }
    }

    func showError(_ body: String, title: String? = nil) {
        show(SQInAppNotificationItem(title: title, body: body, variant: .error, duration: .seconds(4)))
    }

    func showUndo(body: String, actionLabel: String, action: @escaping @MainActor () -> Void) {
        show(
            SQInAppNotificationItem(
                body: body,
                variant: .info,
                duration: .seconds(5),
                actionLabel: actionLabel,
                action: action,
                priority: .high,
                canBePreempted: false
            )
        )
    }

    func dismiss(_ id: UUID) {
        guard current?.id == id else { return }
        queue.dismiss(id: id)
        presentCurrent()
    }

    func performAction(_ id: UUID) {
        guard let shown = current, shown.id == id else { return }
        shown.action?()
        dismiss(id)
    }

    private func presentCurrent() {
        timeoutTask?.cancel()
        current = queue.current?.item
        guard let shown = current else { return }

        let announcement = [shown.title, shown.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        if !announcement.isEmpty {
            Task { @MainActor in
                await Task.yield()
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: shown.duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(shown.id)
        }
    }
}

struct SQInAppNotificationHost: View {
    @EnvironmentObject private var center: SQInAppNotificationCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let item = center.current {
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: icon(for: item.variant))
                        .foregroundStyle(tint(for: item.variant))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = item.title, !title.isEmpty {
                            Text(title).font(SQType.caption.weight(.bold))
                        }
                        Text(item.body)
                            .font(SQType.caption.weight(.medium))
                            .lineLimit(3)
                    }
                    .foregroundStyle(SQColor.label)
                    Spacer(minLength: SQSpace.xs)
                    if let actionLabel = item.actionLabel, item.action != nil {
                        Button(actionLabel) { center.performAction(item.id) }
                            .font(SQType.caption.weight(.bold))
                            .tint(tint(for: item.variant))
                            .frame(minHeight: 44)
                    }
                    Button {
                        center.dismiss(item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fermer")
                }
                .padding(.leading, SQSpace.md)
                .padding(.trailing, SQSpace.xs)
                .padding(.vertical, SQSpace.xs)
                .frame(maxWidth: 520)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                // Ombre seule, jamais avec un contour : la variante se lit à l'icône
                // teintée. Le liseré ne sert qu'en OLED et en mode terrain.
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(SQOledPalette.cardStroke, lineWidth: 1)
                }
                .sqShadowDock()
                .padding(.horizontal, SQSpace.md)
                .accessibilityElement(children: .contain)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(item.id)
            }
        }
        .animation(reduceMotion ? nil : SQMotion.snappy, value: center.current?.id)
    }

    private func icon(for variant: SQInAppNotificationVariant) -> String {
        switch variant {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func tint(for variant: SQInAppNotificationVariant) -> Color {
        switch variant {
        case .info: return SQColor.ink2
        case .success: return SQColor.success
        case .warning: return SQColor.warning
        case .error: return SQColor.dangerInk
        }
    }
}
