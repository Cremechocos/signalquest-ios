import SwiftUI

struct ForgotPasswordView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @StateObject private var challenge = MobileChallengePresenter()
    @State private var email: String
    @State private var emailRequested = false
    @State private var appeared = false
    @State private var submission: Task<Void, Never>?
    @State private var submissionID: UUID?
    @State private var challengeError: String?

    @FocusState private var emailFocused: Bool

    /// L'adresse déjà saisie sur la connexion est reprise.
    init(email: String = "") {
        _email = State(initialValue: email)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "auth.recovery.close") { dismiss() }
                }
                if emailRequested {
                    SQIconPastille(systemImage: "envelope", size: 52, tint: SQColor.success, fill: SQColor.successSoft,
                                   font: SQFont.body(22, .semibold, relativeTo: .title3))
                    VStack(alignment: .leading, spacing: SQSpace.xs2) {
                        Text("Consulte tes e-mails")
                            .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
                            .foregroundStyle(SQColor.label)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("auth.recovery.sent")
                        Text("Si un compte correspond à \(email.trimmingCharacters(in: .whitespacesAndNewlines)), un lien t’a été envoyé. Il ouvre l’app pour choisir ton nouveau mot de passe.")
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GradientButton("Retour à la connexion", style: .secondary) { dismiss() }
                    Button("Utiliser une autre adresse") {
                        emailRequested = false
                        challengeError = nil
                        session.errorMessage = nil
                    }
                    .font(SQType.callout(.bold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    AuthHeader(title: String(localized: "Mot de passe oublié ?"),
                               message: String(localized: "Indique ton e-mail : tu recevras un lien pour en choisir un nouveau."),
                               showsLogo: false)
                        .sqAuthAppear(appeared)
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        AuthFieldGroup {
                            AuthFieldRow("Email", isFocused: emailFocused) {
                                TextField("Email", text: $email, prompt: SQFormPrompt.text("nom@exemple.fr"))
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                    .textContentType(.username)
                                    .autocorrectionDisabled()
                                    .submitLabel(.send)
                                    .focused($emailFocused)
                                    .onSubmit(submit)
                                    .accessibilityLabel("Email")
                                    .accessibilityIdentifier("auth.recovery.email")
                            } onTap: { emailFocused = true }
                        }
                        if let error = challengeError ?? session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("auth.recovery.error")
                                .sqAnnounce(error)
                        }
                    }
                    .sqAuthAppear(appeared, delay: 0.08)
                    GradientButton("Envoyer le lien", isBusy: submissionID != nil || session.isBusy) { submit() }
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("auth.recovery.submit")
                        .sqAuthAppear(appeared, delay: 0.08)
                }
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
            // Erreur globale à la session : on repart d'un écran sans reste d'une autre saisie.
            session.errorMessage = nil
        }
        .mobileChallenge(using: challenge)
        .onDisappear { cancelSubmission() }
        .onChangeCompat(of: session.state) { _, state in
            guard case .loggedOut = state else { cancelSubmission(); return }
        }
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            submissionID == nil && !session.isBusy && !challenge.isBusy
    }

    private func submit() {
        guard canSubmit else { return }
        let id = UUID(), address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        submissionID = id
        challengeError = nil
        submission = Task {
            defer { if submissionID == id { submissionID = nil; submission = nil } }
            do {
                let context = try session.beginPublicForm()
                let proof = try await challenge.request(origin: AppConfig.current.appBaseURL, action: .passwordReset,
                    language: locale.language.languageCode?.identifier ?? "en", theme: colorScheme == .dark ? "dark" : "light")
                guard !Task.isCancelled, submissionID == id else { return }
                let acknowledged = await session.forgotPassword(email: address, proof: proof, context: context)
                guard !Task.isCancelled, submissionID == id else { return }
                emailRequested = acknowledged
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
}
