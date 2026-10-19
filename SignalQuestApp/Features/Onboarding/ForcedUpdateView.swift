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

    /// Identifiant App Store de l'app (App Store Connect).
    private static let appStoreID = "6778608659"

    /// Le lien du serveur est facultatif : sans repli, l'écran bloquant
    /// n'avait aucun bouton (AF-PROF-08). Un build TestFlight se met à jour
    /// dans TestFlight, un build App Store dans l'App Store.
    private var updateURL: URL? { Self.resolvedUpdateURL(storeURL: storeURL) }

    /// Partagé avec la rangée « Mise à jour recommandée » du Profil.
    static func resolvedUpdateURL(storeURL: URL?) -> URL? {
        if let storeURL { return storeURL }
        let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        return URL(string: isTestFlight
            ? "itms-beta://beta.itunes.apple.com/v1/app/\(appStoreID)"
            : "itms-apps://apps.apple.com/app/id\(appStoreID)")
    }

    /// Le message du serveur n'existe qu'en français : ailleurs, le texte traduit.
    private var serverMessage: String? {
        guard let message, Locale.current.language.languageCode?.identifier == "fr" else { return nil }
        return message
    }

    var body: some View {
        ZStack {
            SQColor.bg.ignoresSafeArea()
            // Aux grandes tailles de texte ou en paysage, le contenu défile au lieu d'être coupé :
            // cet écran n'offre aucune autre sortie.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
        }
        .accessibilityIdentifier("forcedUpdate.screen")
    }

    private var content: some View {
        VStack(spacing: SQSpace.lg) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 52))
                .foregroundStyle(SQColor.brandRed)
                .accessibilityHidden(true)
            Text("Mise à jour requise")
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            Group {
                if let serverMessage {
                    Text(serverMessage)
                } else {
                    Text("Cette version de SignalQuest n'est plus prise en charge. Mets l'application à jour pour continuer.")
                }
            }
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
            if let updateURL {
                GradientButton("Mettre à jour", systemImage: "arrow.up.forward.app") {
                    openURL(updateURL)
                }
            }
        }
        .padding(SQSpace.xxl)
        .frame(maxWidth: .infinity)
    }
}
