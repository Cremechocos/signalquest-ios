import SwiftUI

/// Information affichée UNE FOIS avant le tout premier Drive Test.
///
/// Un Drive Test publie systématiquement : c'est sa raison d'être, et lui greffer
/// un interrupteur reviendrait à proposer un mode « contribuer sans contribuer ».
/// Mais publier une trace de déplacement sans aucun contrôle impose au minimum
/// d'en informer clairement — c'est ce que regardent la revue App Store
/// (guideline 5.1.1) et le RGPD (art. 13).
///
/// Ce n'est donc PAS un consentement : il n'y a rien à accepter ni à refuser, un
/// seul bouton. Le texte doit dire la vérité sans l'euphémiser, y compris la
/// précision réelle publiée — un écran rassurant mais faux serait pire que pas
/// d'écran du tout.
struct DriveTestDisclosureView: View {
    /// Vu au moins une fois : l'écran ne réapparaît plus.
    static let seenKey = "drivetest_disclosure_seen"

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
                        Text("Un Drive Test sert à cartographier le réseau. Ce que tu enregistres est publié sur la carte communautaire — c'est le principe, il n'y a pas de réglage pour l'en empêcher.")
                            .font(SQFont.body(14))
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        row(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "La génération, pas le signal",
                            detail: "iOS ne donne accès à aucune mesure radio. On enregistre la technologie disponible le long du trajet (5G, 4G, ou aucun réseau), jamais une puissance de signal."
                        )
                        row(
                            icon: "mappin.and.ellipse",
                            title: "Une position arrondie à environ 50 mètres",
                            detail: "Ta position exacte n'est jamais publiée : chaque point est ramené sur une grille d'environ 50 m. Cela reste un déplacement identifiable à l'échelle du pâté de maisons — garde-le en tête avant de partir de chez toi."
                        )
                        row(
                            icon: "speedometer",
                            title: "Des données mobiles, en quantité",
                            detail: "Un speedtest consomme son débit multiplié par sa durée : environ 375 Mo à 300 Mb/s. La session s'arrête d'elle-même au plafond que tu as choisi, et le volume consommé s'affiche en direct."
                        )
                        row(
                            icon: "lock.shield",
                            title: "Jamais sous VPN",
                            detail: "Sous tunnel, l'opérateur détecté est celui de la sortie du VPN : la mesure serait attribuée au mauvais réseau. Rien n'est alors ni enregistré ni publié."
                        )
                    }

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
