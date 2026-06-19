import SwiftUI
import UIKit

/// Écran d'explication (pre-permission priming) affiché AVANT le prompt système
/// de localisation, pour expliquer la finalité et réduire les refus (audit UX-01).
/// Réutilisable par le speedtest et la carte.
struct LocationPrimingSheet: View {
    /// Variante « localisation refusée » : propose d'ouvrir les Réglages au lieu de
    /// déclencher un prompt système qui n'apparaîtra plus (ONB-SEC-01).
    var isDenied: Bool = false
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: SQSpace.lg) {
            SQSheetHandle()
            Spacer()
            Image(systemName: isDenied ? "location.slash.fill" : "location.fill.viewfinder")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 100, height: 100)
                .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: SQSpace.sm) {
                Text(isDenied ? "Localisation désactivée" : "Localiser ta mesure")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                Text(isDenied
                     ? "La localisation est désactivée pour SignalQuest. Active-la dans les Réglages pour situer tes mesures sur la carte. Le test fonctionne quand même sans."
                     : "Pour situer ton speedtest sur la carte communautaire, SignalQuest a besoin de ta position approximative (~100 m). Tu peux refuser : le test fonctionnera quand même, sans apparaître sur la carte.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(spacing: SQSpace.sm) {
                if isDenied {
                    GradientButton("Ouvrir les Réglages", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    GradientButton("Autoriser la localisation", systemImage: "location.fill") { onAllow() }
                }
                Button("Continuer sans") { onSkip() }
                    .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                    .tint(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.xl)
        .signalQuestBackground()
    }
}
