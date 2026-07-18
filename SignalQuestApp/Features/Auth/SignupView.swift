import SwiftUI
import AuthenticationServices

struct SignupView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var acceptedTerms = false
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl + 2) {
                header
                    .sqAuthAppear(appeared)

                VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                    Text("Créer un compte")
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)

                    TextField("Nom affiché", text: $name)
                        .textContentType(.name)
                        .textFieldStyle(SQTextFieldStyle())

                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textFieldStyle(SQTextFieldStyle())

                    SecureField("Mot de passe (min. 8 caractères)", text: $password)
                        .textContentType(.newPassword)
                        .textFieldStyle(SQTextFieldStyle())

                    SecureField("Confirmer le mot de passe", text: $passwordConfirm)
                        .textContentType(.newPassword)
                        .textFieldStyle(SQTextFieldStyle())

                    Toggle(isOn: $acceptedTerms) {
                        Text("J’accepte les conditions d’utilisation et la politique de confidentialité.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .tint(SQColor.brandRed)

                    HStack(spacing: SQSpace.md) {
                        Link("Conditions d’utilisation", destination: Self.termsURL)
                        Text("·").foregroundStyle(SQColor.labelTertiary)
                        Link("Politique de confidentialité", destination: Self.privacyURL)
                    }
                    .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
                    .tint(SQColor.brandRed)

                    if let error = session.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(SQColor.danger)
                    } else if let info = passwordIssue {
                        Label(info, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(SQColor.labelSecondary)
                    }

                    GradientButton("Créer mon compte", systemImage: "person.crop.circle.badge.plus", isBusy: session.isBusy) {
                        Task { await session.signup(email: trimmedEmail, password: password, name: trimmedName) }
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)
                }
                .padding(SQSpace.xl)
                .sqSoftCard()
                .sqAuthAppear(appeared, delay: 0.08)

                HStack(spacing: SQSpace.md) {
                    Rectangle().fill(SQColor.separator).frame(height: 1)
                    Text("ou").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                    Rectangle().fill(SQColor.separator).frame(height: 1)
                }
                .sqAuthAppear(appeared, delay: 0.1)

                SignInWithAppleButton(.signUp) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 56)
                .clipShape(Capsule(style: .continuous))
                // Même exigence contractuelle que le formulaire e-mail : sans
                // acceptation des CGU, on ne crée pas de compte (UXP-12).
                .disabled(!acceptedTerms)
                .opacity(acceptedTerms ? 1 : 0.5)
                .accessibilityLabel("S’inscrire avec Apple")
                .accessibilityHint(acceptedTerms ? "" : "Accepte d’abord les conditions d’utilisation")
                .sqAuthAppear(appeared, delay: 0.12)

                Button("J'ai déjà un compte") { dismiss() }
                    .buttonStyle(.plain)
                    .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
                    .sqAuthAppear(appeared, delay: 0.14)
            }
            .padding(SQSpace.xl)
        }
        .signalQuestHeroBackground()
        .onAppear { appeared = true }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// « S'inscrire avec Apple » : Apple crée le compte à la 1re autorisation
    /// (ou connecte si l'identité existe déjà). Même flux que sur l'écran de login.
    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                session.errorMessage = "Jeton Apple manquant. Réessaie."
                return
            }
            let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            Task {
                await session.signInWithApple(
                    identityToken: identityToken,
                    fullName: fullName.isEmpty ? nil : fullName
                )
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            session.errorMessage = "Connexion Apple impossible. Réessaie."
        }
    }

    // URLs légales centralisées et vérifiées dans AppConfig (/terms, /privacy).
    private static var termsURL: URL { AppConfig.current.termsURL }
    private static var privacyURL: URL { AppConfig.current.privacyURL }

    private var passwordIssue: String? {
        if password.isEmpty { return nil }
        if password.count < 8 { return "Le mot de passe doit faire au moins 8 caractères." }
        if password != passwordConfirm { return "Les deux mots de passe ne correspondent pas." }
        return nil
    }

    private var canSubmit: Bool {
        !trimmedEmail.isEmpty &&
        !trimmedName.isEmpty &&
        password.count >= 8 &&
        password == passwordConfirm &&
        acceptedTerms &&
        !session.isBusy
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Image(systemName: "person.badge.plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 46, height: 46)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text("Rejoins SignalQuest")
                .font(SQType.display)
                .foregroundStyle(SQColor.label)
            Text("Cartographie la 4G/5G en France avec une communauté de passionnés.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.top, SQSpace.xxxl + SQSpace.xs)
    }
}
