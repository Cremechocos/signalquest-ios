import SwiftUI

struct ForgotPasswordView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var resetToken = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var step: Step = .requestEmail
    @State private var appeared = false

    enum Step { case requestEmail, enterToken }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header
                    .sqAuthAppear(appeared)

                VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                    switch step {
                        case .requestEmail:
                            Text("Réinitialiser le mot de passe")
                                .font(SQType.title)
                                .foregroundStyle(SQColor.label)
                            Text("On t’envoie un lien avec un code à 8 caractères. Copie-le dans l’écran suivant.")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                            TextField("Email", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textFieldStyle(SQTextFieldStyle())
                            GradientButton("Envoyer le lien", systemImage: "paperplane.fill", isBusy: session.isBusy) {
                                Task {
                                    await session.forgotPassword(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
                                    if session.errorMessage == nil { step = .enterToken }
                                }
                            }
                            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        case .enterToken:
                            Text("Nouveau mot de passe")
                                .font(SQType.title)
                                .foregroundStyle(SQColor.label)
                            TextField("Code de réinitialisation", text: $resetToken)
                                .textInputAutocapitalization(.never)
                                .textFieldStyle(SQTextFieldStyle())
                            SecureField("Nouveau mot de passe", text: $newPassword)
                                .textContentType(.newPassword)
                                .textFieldStyle(SQTextFieldStyle())
                            SecureField("Confirmer", text: $confirmation)
                                .textContentType(.newPassword)
                                .textFieldStyle(SQTextFieldStyle())
                            GradientButton("Mettre à jour", systemImage: "checkmark.shield", isBusy: session.isBusy) {
                                Task {
                                    let ok = await session.resetPassword(
                                        token: resetToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                        newPassword: newPassword
                                    )
                                    if ok { dismiss() }
                                }
                            }
                            .disabled(!canReset)
                        }

                        if let info = session.infoMessage {
                            Label(info, systemImage: "checkmark.circle")
                                .font(.footnote)
                                .foregroundStyle(SQColor.success)
                        }
                    if let error = session.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(SQColor.danger)
                    }
                }
                .padding(SQSpace.xl)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .stroke(SQColor.label, lineWidth: 2)
                }
                .sqAuthAppear(appeared, delay: 0.08)

                Button("Retour à la connexion") { dismiss() }
                    .buttonStyle(.plain)
                    .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
                    .sqAuthAppear(appeared, delay: 0.14)
            }
            .padding(SQSpace.xl)
        }
        .background { SQAuthHalo() }
        .signalQuestHeroBackground()
        .onAppear { appeared = true }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canReset: Bool {
        !resetToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmation &&
        !session.isBusy
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Image(systemName: "key.horizontal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Récupération").sqKicker()
                Text("Mot de passe oublié ?")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
            }
        }
        .padding(.top, SQSpace.xxxl + SQSpace.xs)
    }
}
