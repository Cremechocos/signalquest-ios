import SwiftUI

/// Écran bloquant affiché quand le serveur déclare la version installée trop
/// ancienne (`VersionPolicyState.updateRequired`).
///
/// Volontairement sans échappatoire : c'est le seul moyen de garantir qu'un
/// durcissement de contrat backend ne casse pas silencieusement les anciennes
/// versions. En contrepartie, la décision de l'afficher est protégée par
/// plusieurs garde-fous en amont (`VersionPolicyService.evaluate`) — une
/// politique incohérente ou un numéro de build illisible ne bloque jamais.
struct ForcedUpdateView: View {
    let message: String?
    let storeURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            SQColor.bg.ignoresSafeArea()
            VStack(spacing: SQSpace.lg) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Text("Mise à jour requise")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                Text(message ?? "Cette version de SignalQuest n'est plus prise en charge. Mets l'application à jour pour continuer.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                if let storeURL {
                    GradientButton("Mettre à jour", systemImage: "arrow.up.forward.app") {
                        openURL(storeURL)
                    }
                }
            }
            .padding(SQSpace.xxl)
        }
        .accessibilityIdentifier("forcedUpdate.screen")
    }
}
