import SwiftUI

/// La question des rapports de plantage (CrashReportingConsent) : au premier
/// lancement, puis une fois après la mise à jour pour ceux qui avaient déjà l'app.
/// Un calque plein écran comme la question du ton. Les deux réponses ont le même
/// poids : refuser est aussi simple qu'accepter, et rien ne part avant un choix.
///
/// Rouverte en feuille depuis l'écran de connexion (seul accès d'un invité au
/// réglage) : le choix en cours y est coché et « Fermer » ne change rien.
struct CrashReportingConsentPrompt: View {
    @ObservedObject var store: CrashReportingConsentStore
    var showsClose = false
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: "ladybug.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Text("Nous aider à corriger les plantages ?")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Si l’app plante ou se fige, un rapport technique peut nous être envoyé : l’endroit du code en cause, la version de l’app et le modèle de l’appareil. Jamais tes messages ni ta position.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tu pourras changer d’avis à tout moment.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                choice(.granted, title: "Envoyer les rapports",
                       detail: String(localized: "Plantages et blocages, sans tes contenus."))
                choice(.denied, title: "Ne pas envoyer",
                       detail: String(localized: "Rien ne part, et les rapports en attente sont supprimés."))

                Link(destination: AppConfig.current.privacyURL) {
                    Text("Lire la politique de confidentialité")
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("crash-consent-privacy")

                if showsClose {
                    GradientButton("Fermer", style: .ghost) { onClose() }
                        .accessibilityIdentifier("crash-consent-close")
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
    }

    private func choice(_ value: CrashReportingConsent.Choice, title: String, detail: String) -> some View {
        let isCurrent = store.choice == value
        return Button {
            store.choose(value)
            onClose()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(LocalizedStringKey(title))
                        .font(SQFont.body(17, .semibold, relativeTo: .body))
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: detail)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(SQType.body.weight(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(SQSpace.lg)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue(Text(verbatim: detail))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("crash-consent-\(value.rawValue)")
    }
}
