import SwiftUI

struct PasswordResetRoute: Identifiable {
    enum Content { case form(PasswordResetRequest), invalid, completed }
    let id: UUID
    let content: Content

    init(request: PasswordResetRequest) { id = request.id; content = .form(request) }
    init(id: UUID = UUID(), content: Content) { self.id = id; self.content = content }

    func contains(_ request: PasswordResetRequest) -> Bool {
        guard case .form(let current) = content else { return false }
        return current.token == request.token
    }
}

struct PasswordResetScreen: View {
    let route: PasswordResetRoute
    let onClose: () -> Void
    let onSuccess: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch route.content {
                case .form(let request):
                    PasswordResetForm(request: request, onSuccess: onSuccess)
                case .invalid:
                    message(title: "Ce lien est invalide", text: "Demande un nouveau lien depuis Mot de passe oublié, puis ouvre-le depuis ton e-mail.")
                case .completed:
                    message(title: "Mot de passe mis à jour", text: "Tu peux maintenant te connecter avec ton nouveau mot de passe.")
                }
            }
            .navigationTitle("Nouveau mot de passe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer", action: onClose).accessibilityIdentifier("auth.reset.close")
                }
            }
        }
        .background(AppSensitiveContentMarker())
    }

    private func message(title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                Text(title).font(SQType.title).accessibilityAddTraits(.isHeader)
                Text(text).font(SQType.body).foregroundStyle(SQColor.labelSecondary)
                Button("Fermer", action: onClose).frame(minHeight: 44)
            }
            .padding(SQSpace.xl)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .signalQuestBackground()
    }
}

private struct PasswordResetForm: View {
    let request: PasswordResetRequest
    let onSuccess: () -> Void
    @EnvironmentObject private var session: AuthSessionViewModel
    @State private var password = ""
    @State private var confirmation = ""
    @State private var submission: Task<Void, Never>?
    @State private var submissionID: UUID?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Text("Choisis ton nouveau mot de passe")
                    .font(SQType.title)
                    .accessibilityAddTraits(.isHeader)
                Text("Ce changement concerne le compte associé au lien reçu par e-mail.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                SecureField("Nouveau mot de passe", text: $password)
                    .textContentType(.newPassword)
                    .textFieldStyle(SQTextFieldStyle())
                    .accessibilityIdentifier("auth.reset.password")
                SecureField("Confirmer", text: $confirmation)
                    .textContentType(.newPassword)
                    .textFieldStyle(SQTextFieldStyle())
                    .accessibilityIdentifier("auth.reset.confirmation")
                if let issue = error ?? passwordIssue {
                    Text(issue).font(SQType.caption).foregroundStyle(SQColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("auth.reset.error")
                }
                GradientButton("Mettre à jour", systemImage: "checkmark.shield", isBusy: submissionID != nil) { submit() }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("auth.reset.submit")
            }
            .padding(SQSpace.xl)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .signalQuestBackground()
        .onDisappear { cancelSubmission() }
        .onChangeCompat(of: session.state) { _, _ in
            cancelSubmission()
            password = ""
            confirmation = ""
        }
    }

    private var passwordIssue: String? {
        guard !password.isEmpty else { return nil }
        if password.count < 8 { return String(localized: "Le mot de passe doit faire au moins 8 caractères.") }
        if !confirmation.isEmpty, password != confirmation { return String(localized: "Les deux mots de passe ne correspondent pas.") }
        return nil
    }

    private var canSubmit: Bool {
        password.count >= 8 && password == confirmation && submissionID == nil && !session.isBusy
    }

    private func submit() {
        guard canSubmit else { return }
        let id = UUID(), newPassword = password
        submissionID = id
        error = nil
        submission = Task {
            defer { if submissionID == id { submissionID = nil; submission = nil } }
            let ok = await session.resetPassword(token: request.token, newPassword: newPassword)
            guard !Task.isCancelled, submissionID == id else { return }
            if ok {
                password = ""
                confirmation = ""
                onSuccess()
            } else { error = session.errorMessage }
        }
    }

    private func cancelSubmission() {
        submissionID = nil
        submission?.cancel()
        submission = nil
    }
}
