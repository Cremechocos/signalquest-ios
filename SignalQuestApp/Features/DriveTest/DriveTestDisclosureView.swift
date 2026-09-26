import SwiftUI

/// Présente le Drive Test recentré sur les mesures de débit, leur publication
/// et la conservation sans envoi des anciens brouillons de couverture.
struct DriveTestDisclosureView: View {
    /// Vu au moins une fois : l'écran ne réapparaît plus.
    static let seenKey = "drivetest_speedtests_disclosure_seen_v2"

    let onAcknowledge: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    SQSheetHandle()

                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(SQColor.brandRed)
                            .sqDecorative()
                        Text("Ce qu'un Drive Test partage")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                        Text("Le Drive Test enchaîne des tests de débit pendant ton trajet, selon la distance et le plafond de données choisis.")
                            .font(SQFont.body(14))
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        row(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "Des résultats, sans collecte de couverture",
                            detail: "Chaque speedtest garde ses débits, sa latence et sa position. Le suivi du trajet sert à espacer les tests ; aucun enregistrement de couverture n’est créé."
                        )
                        row(
                            icon: "mappin.and.ellipse",
                            title: "La position exacte de chaque speedtest",
                            detail: "Les nouveaux speedtests éligibles sont publiés à leur position exacte. Tes zones privées restent protégées ; tu peux masquer un résultat depuis ton historique."
                        )
                        row(
                            icon: "speedometer",
                            title: "Des données mobiles, en quantité",
                            detail: "Un speedtest consomme son débit multiplié par sa durée : environ 375 Mo à 300 Mb/s. La session s'arrête d'elle-même au plafond que tu as choisi, et le volume consommé s'affiche en direct."
                        )
                        row(
                            icon: "lock.shield",
                            title: "Jamais sous VPN",
                            detail: "Un VPN empêche une attribution fiable de l’opérateur. Les mesures sous VPN ne sont pas publiées."
                        )
                    }

                    Text("Les anciens brouillons de couverture restent sur cet appareil et ne sont plus envoyés automatiquement.")
                        .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)

                    GradientButton("J'ai compris", systemImage: "checkmark") {
                        UserDefaults.standard.set(true, forKey: Self.seenKey)
                        Haptics.selection()
                        onAcknowledge()
                    }
                    .padding(.top, SQSpace.xs)
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Drive Test")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 34, height: 34)
                .background(SQColor.accentSoft, in: Circle())
                .sqDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SQFont.body(14.5, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(detail)
                    .font(SQFont.body(12.5))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Un point d'information se lit d'un bloc ; le balayer en deux morceaux
        // (titre puis détail) casse le propos.
        .accessibilityElement(children: .combine)
    }
}
