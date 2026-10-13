import SwiftUI

/// Présente le Drive Test recentré sur les mesures de débit, leur publication
/// et la conservation sans envoi des anciens brouillons de couverture.
struct DriveTestDisclosureView: View {
    /// Vu au moins une fois : l'écran ne réapparaît plus.
    static let seenKey = "drivetest_speedtests_disclosure_seen_v2"

    let onAcknowledge: () -> Void
    /// La mention des anciens brouillons ne concerne que les appareils qui en ont.
    @State private var hasLegacyCoverageDrafts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                // Fermer vaut « J'ai compris » : la feuille informe, elle ne
                // demande rien d'autre.
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "drivetest.disclosure.close") {
                    acknowledge()
                }
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    SQIconPastille(systemImage: "point.topleft.down.to.point.bottomright.curvepath", size: 48,
                                   tint: SQColor.accentInk, fill: SQColor.accentSoft,
                                   font: .system(size: 20, weight: .semibold))
                    Text("Ce qu'un Drive Test partage")
                        .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .sqHeader()
                    Text("Le Drive Test enchaîne des tests de débit pendant ton trajet, selon la distance et le plafond de données choisis.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    row(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Seulement des speedtests",
                        detail: "Chaque speedtest garde ses débits, sa latence et sa position. Le trajet sert seulement à espacer les tests."
                    )
                    rowDivider
                    row(
                        icon: "mappin.and.ellipse",
                        title: "La position exacte de chaque speedtest",
                        detail: "Les nouveaux speedtests éligibles sont publiés à leur position exacte. Tes zones privées restent protégées. Pour masquer un résultat, touche son point sur la carte du trajet ; le site SignalQuest permet aussi de le faire ensuite."
                    )
                    rowDivider
                    row(
                        icon: "speedometer",
                        title: "Des données mobiles, en quantité",
                        detail: "Le volume consommé s'affiche en direct. La session s'arrête après le test qui atteint le plafond ; ce test peut le dépasser."
                    )
                    rowDivider
                    row(
                        icon: "lock.shield",
                        title: "Jamais sous VPN",
                        detail: "Un VPN empêche une attribution fiable de l’opérateur. Les mesures sous VPN ne sont pas publiées."
                    )
                }
                .padding(.horizontal, SQSpace.cardPadding)
                .sqCardBackground()

                if hasLegacyCoverageDrafts {
                    Text("Les anciens brouillons de couverture restent sur cet appareil et ne sont plus envoyés automatiquement.")
                        .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SQSpace.xs)
                }

                GradientButton("J'ai compris", systemImage: "checkmark") { acknowledge() }
                    .padding(.top, SQSpace.xs)
            }
            .padding(SQSpace.lg)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .task {
            hasLegacyCoverageDrafts = await Task.detached(priority: .utility) {
                !LocalCoverageArchiveReader.load().entries.isEmpty
            }.value
        }
    }

    private func acknowledge() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        Haptics.selection()
        onAcknowledge()
    }

    private var rowDivider: some View {
        Divider().overlay(SQColor.separator).padding(.leading, 34 + SQSpace.md)
    }

    private func row(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            SQIconPastille(systemImage: icon, size: 34, font: .system(size: 15, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SQFont.body(15, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("drivetest.disclosure.title")
                // 13,5 pt sur la carte blanche : sous 13 pt, le brun secondaire
                // perd son contraste une fois rendu.
                Text(detail)
                    .font(SQFont.body(13.5, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("drivetest.disclosure.detail")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SQSpace.sm2)
        // Un point d'information se lit d'un bloc ; le balayer en deux morceaux
        // (titre puis détail) casse le propos.
        .accessibilityElement(children: .combine)
    }
}
