import SwiftUI
import AuthenticationServices

struct SignupView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @StateObject private var challenge = MobileChallengePresenter()
    @State private var submission: Task<Void, Never>?
    @State private var submissionID: UUID?
    @State private var challengeError: String?

    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var acceptedTerms = false
    @State private var appeared = false
    @State private var pendingAppleConsent: PendingAppleConsent?
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    private struct PendingAppleConsent: Identifiable {
        let id = UUID()
        let identityToken: String
        let fullName: String?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "auth.signup.close") { dismiss() }
                }
                AuthHeader(title: String(localized: "Créer un compte"),
                           message: String(localized: "Gratuit. Tes mesures et tes points te suivent, sur iPhone comme sur Android."),
                           showsLogo: false)
                    .sqAuthAppear(appeared)

                Group {
                    // Toujours actif : un nouveau compte Apple passe par « Une dernière
                    // étape », qui demande le consentement (UXP-12).
                    SignInWithAppleButton(.signUp) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(SQOledPalette.appleButtonStyle(colorScheme))
                    .frame(height: 50)
                    .clipShape(Capsule(style: .continuous))
                    .disabled(session.isBusy || submissionID != nil || challenge.isBusy)
                    .accessibilityLabel("S’inscrire avec Apple")

                    AuthOrDivider()

                    AuthFieldGroup {
                        AuthFieldRow("Nom affiché", isFocused: focus == .name) {
                            TextField("Nom affiché", text: $name, prompt: SQFormPrompt.text("Ex. Alex Martin"))
                                .textContentType(.name)
                                .submitLabel(.next)
                                .focused($focus, equals: .name)
                                .onSubmit { focus = .email }
                                .accessibilityLabel("Nom affiché")
                                .accessibilityIdentifier("auth.signup.name")
                        } onTap: { focus = .name }
                        AuthFieldDivider()
                        AuthFieldRow("Email", isFocused: focus == .email) {
                            TextField("Email", text: $email, prompt: SQFormPrompt.text("nom@exemple.fr"))
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .focused($focus, equals: .email)
                                .onSubmit { focus = .password }
                                .accessibilityLabel("Email")
                                .accessibilityIdentifier("auth.signup.email")
                        } onTap: { focus = .email }
                        // L'erreur du serveur porte presque toujours sur l'adresse :
                        // elle s'affiche juste sous ce champ.
                        if let error = challengeError ?? session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, SQSpace.md2)
                                .padding(.bottom, SQSpace.sm2)
                                .accessibilityIdentifier("auth.signup.error")
                                .sqAnnounce(error)
                        }
                        AuthFieldDivider()
                        AuthFieldRow("Mot de passe", isFocused: focus == .password) {
                            AuthPasswordInput(label: "Mot de passe", text: $password, contentType: .newPassword,
                                              identifier: "auth.signup.password")
                                .submitLabel(.done)
                                .focused($focus, equals: .password)
                        } onTap: { focus = .password }
                    }

                    Label {
                        Text("8 caractères minimum")
                    } icon: {
                        Image(systemName: password.count >= 8 ? "checkmark" : "info.circle")
                    }
                    .font(SQType.caption(password.count >= 8 ? .semibold : .regular))
                    .foregroundStyle(password.count >= 8 ? SQColor.success : SQColor.labelSecondary)
                    .padding(.leading, SQSpace.xs)
                    .padding(.top, -SQSpace.sm)
                    .accessibilityIdentifier("auth.signup.passwordRule")

                    AuthConsentCheckbox(isOn: $acceptedTerms, identifier: "auth.signup.terms")

                    GradientButton("Créer mon compte", isBusy: session.isBusy || submissionID != nil) {
                        // `canSubmit` exige déjà `acceptedTerms` : on transmet
                        // la valeur réelle plutôt qu'un `true` littéral, pour
                        // qu'un futur contournement de la validation n'aboutisse
                        // pas à enregistrer un consentement qui n'a pas eu lieu.
                        submit()
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("auth.signup.submit")

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: SQSpace.xs) { loginQuestion; loginButton }
                        VStack(spacing: 0) { loginQuestion; loginButton }
                    }
                    .frame(maxWidth: .infinity)
                }
                .sqAuthAppear(appeared, delay: 0.08)
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .signalQuestHeroBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            appeared = true
            // L'erreur est globale à la session : sans cela, celle d'une connexion
            // ratée s'afficherait déjà sous le champ Email à l'ouverture.
            session.errorMessage = nil
        }
        .mobileChallenge(using: challenge)
        .onDisappear { cancelSubmission() }
        .onChangeCompat(of: session.state) { _, state in
            guard case .loggedOut = state else { cancelSubmission(); return }
        }
        .sheet(item: $pendingAppleConsent) { credential in
            AppleTermsConsentSheet(identityToken: credential.identityToken, fullName: credential.fullName) {
                pendingAppleConsent = nil
            }
        }
    }

    private var loginQuestion: some View {
        Text("Déjà un compte ?")
            .font(SQType.callout)
            .foregroundStyle(SQColor.ink2)
    }

    private var loginButton: some View {
        Button { dismiss() } label: {
            Text("Se connecter")
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("auth.signup.login")
    }

    private func submit() {
        guard canSubmit else { return }
        let id = UUID(), email = trimmedEmail, name = trimmedName, password = password, terms = acceptedTerms
        submissionID = id
        challengeError = nil
        submission = Task {
            defer { if submissionID == id { submissionID = nil; submission = nil } }
            do {
                let context = try session.beginPublicForm()
                let proof = try await challenge.request(origin: AppConfig.current.appBaseURL, action: .signup,
                    language: locale.language.languageCode?.identifier ?? "en", theme: colorScheme == .dark ? "dark" : "light")
                guard !Task.isCancelled, submissionID == id else { return }
                await session.signup(email: email, password: password, name: name, acceptedTerms: terms,
                                     proof: proof, context: context)
            } catch {
                guard !Task.isCancelled, submissionID == id else { return }
                challengeError = error.userFacingMessage
            }
        }
    }

    private func cancelSubmission() {
        submissionID = nil
        submission?.cancel()
        submission = nil
        challenge.cancel()
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
                session.errorMessage = String(localized: "Jeton Apple manquant. Réessaie.")
                return
            }
            let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            Task {
                let outcome = await session.signInWithApple(
                    identityToken: identityToken,
                    fullName: fullName.isEmpty ? nil : fullName,
                    acceptedTerms: acceptedTerms
                )
                if case .requiresTerms = outcome {
                    pendingAppleConsent = PendingAppleConsent(identityToken: identityToken,
                                                              fullName: fullName.isEmpty ? nil : fullName)
                }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            session.errorMessage = String(localized: "Connexion Apple impossible. Réessaie.")
        }
    }

    private var canSubmit: Bool {
        !trimmedEmail.isEmpty &&
        !trimmedName.isEmpty &&
        password.count >= 8 &&
        acceptedTerms &&
        !session.isBusy && submissionID == nil && !challenge.isBusy
    }
}
