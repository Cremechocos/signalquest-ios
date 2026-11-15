import SwiftUI

/// Carte « Protège ton compte » (contrat 2FA r3.4, §6 et §8) en tête de la liste Messages, comme
/// sur Android : pas de croix ; « Plus tard » la reporte de 30 jours pour le compte, le bouton
/// ouvre Réglages › Sécurité, où la rubrique gère l'activation et les codes.
struct SecurityPromptCardView: View {
    let reason: SecurityPrompt.Reason
    let onAction: () -> Void
    let onLater: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var title: LocalizedStringKey {
        reason == .noTwoFactor ? "Protège ton compte" : "Génère tes codes de secours"
    }

    private var message: LocalizedStringKey {
        reason == .noTwoFactor ? "Active la double authentification : un code en plus de ton mot de passe."
            : "Ils te permettent de te connecter si tu perds ton téléphone."
    }

    private var actionTitle: String {
        reason == .noTwoFactor ? String(localized: "Activer") : String(localized: "Générer de nouveaux codes")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                if !dynamicTypeSize.isAccessibilitySize {
                    SQIconPastille(systemImage: "shield.fill", size: 36, tint: SQColor.accentInk)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(title)
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Les deux boutons sur une ligne quand ils tiennent ; sinon l'action en pleine largeur, puis
            // « Plus tard » centré dessous.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SQSpace.md) {
                    Spacer(minLength: 0)
                    laterButton
                    actionButton.fixedSize(horizontal: true, vertical: false)
                }
                VStack(spacing: SQSpace.xs) {
                    actionButton
                    laterButton
                }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSoftCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messages.securityPrompt")
    }

    private var laterButton: some View {
        Button(action: onLater) {
            Text("Plus tard")
                .font(SQType.subhead(.semibold))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.sm)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityIdentifier("messages.securityPrompt.later")
    }

    private var actionButton: some View {
        GradientButton(actionTitle, action: onAction)
            .accessibilityIdentifier("messages.securityPrompt.action")
    }
}
