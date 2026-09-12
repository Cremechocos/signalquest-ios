import SwiftUI

struct ForgotPasswordView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @StateObject private var challenge = MobileChallengePresenter()
    @State private var email = ""
    @State private var emailRequested = false
    @State private var appeared = false
    @State private var submission: Task<Void, Never>?
    @State private var submissionID: UUID?
    @State private var challengeError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header.sqAuthAppear(appeared)
                VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                    if emailRequested {
                        Text("Consulte tes e-mails")
                            .font(SQType.title)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("auth.recovery.sent")
                        Text("Si un compte correspond à cette adresse, un lien de réinitialisation t’a été envoyé. Ouvre ce lien pour choisir ton nouveau mot de passe.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Utiliser une autre adresse") {
                            emailRequested = false
                            challengeError = nil
                            session.errorMessage = nil
                        }
                        .font(SQType.subhead)
                        .frame(minHeight: 44)
                    } else {
                        Text("Réinitialiser le mot de passe")
                            .font(SQType.title)
                        Text("Saisis ton adresse e-mail. Tu recevras un lien pour choisir un nouveau mot de passe.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textFieldStyle(SQTextFieldStyle())
                            .accessibilityIdentifier("auth.recovery.email")
                        GradientButton("Envoyer le lien", systemImage: "paperplane.fill",
                                       isBusy: submissionID != nil || session.isBusy) { submit() }
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("auth.recovery.submit")
                    }
                    if let error = challengeError ?? session.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(SQColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("auth.recovery.error")
                    }
                }
                .foregroundStyle(SQColor.label)
                .padding(SQSpace.xl)
                .sqSoftCard()
                .sqAuthAppear(appeared, delay: 0.08)

                Button("Retour à la connexion") { dismiss() }
                    .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(SQSpace.xl)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .signalQuestHeroBackground()
        .onAppear { appeared = true }
        .mobileChallenge(using: challenge)
        .onDisappear { cancelSubmission() }
        .onChangeCompat(of: session.state) { _, state in
            guard case .loggedOut = state else { cancelSubmission(); return }
        }
        .navigationBarTitleDisplayMode(.inline)
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
                challengeError = error.localizedDescription
            }
        }
    }

    private func cancelSubmission() {
        submissionID = nil
        submission?.cancel()
        submission = nil
        challenge.cancel()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Image(systemName: "key.horizontal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 46, height: 46)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text("Mot de passe oublié ?")
                .font(SQType.display)
                .foregroundStyle(SQColor.label)
        }
        .padding(.top, SQSpace.xxxl + SQSpace.xs)
    }
}
