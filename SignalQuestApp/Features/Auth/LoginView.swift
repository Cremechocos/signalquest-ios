import SwiftUI
import AuthenticationServices

struct LoginView: View {
    let onContinueAsGuest: (() -> Void)?

    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var onboardingEntry: OnboardingEntryState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var showSignup = false
    @State private var showForgotPassword = false
    @State private var appeared = false

    init(onContinueAsGuest: (() -> Void)? = nil) {
        self.onContinueAsGuest = onContinueAsGuest
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.xxl) {
                    header
                        .sqAuthAppear(appeared)

                    if !isTwoFactor, let onContinueAsGuest {
                        Button("Continuer sans compte", action: onContinueAsGuest)
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.accentInk)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(session.isBusy)
                            .accessibilityIdentifier("login.continueGuest")
                            .sqAuthAppear(appeared, delay: 0.11)
                    }

                    VStack(alignment: .leading, spacing: SQSpace.lg) {
                        Text(isTwoFactor ? "Validation 2FA" : "Connexion")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)

                        if isTwoFactor {
                            Text("Saisis le code à 6 chiffres de ton application d’authentification (Google Authenticator, Authy…).")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            VStack(alignment: .leading, spacing: SQSpace.xs) {
                                SQFormFieldLabel("Code à 6 chiffres")
                                TextField("Code à 6 chiffres", text: $code,
                                          prompt: SQFormPrompt.text("Code à 6 chiffres"))
                                    .textContentType(.oneTimeCode)
                                    .keyboardType(.numberPad)
                                    .font(SQFont.display(28, .bold))
                                    .multilineTextAlignment(.center)
                                    .textFieldStyle(SQTextFieldStyle())
                                    .accessibilityLabel("Code à 6 chiffres")
                            }
                            GradientButton("Valider le code", systemImage: "checkmark.shield", isBusy: session.isBusy) {
                                Task { await session.verify2FA(code: code) }
                            }
                            Button("Annuler") { session.cancelTwoFactor() }
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.brandRed)
                                .frame(maxWidth: .infinity)
                        } else {
                            VStack(alignment: .leading, spacing: SQSpace.xs) {
                                SQFormFieldLabel("Email")
                                TextField("Email", text: $email, prompt: SQFormPrompt.text("Email"))
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                    .textContentType(.username)
                                    .textFieldStyle(SQTextFieldStyle())
                                    .accessibilityLabel("Email")
                            }
                            VStack(alignment: .leading, spacing: SQSpace.xs) {
                                SQFormFieldLabel("Mot de passe")
                                SecureField("Mot de passe", text: $password,
                                            prompt: SQFormPrompt.text("Mot de passe"))
                                    .textContentType(.password)
                                    .textFieldStyle(SQTextFieldStyle())
                                    .accessibilityLabel("Mot de passe")
                            }
                            GradientButton("Se connecter", systemImage: "arrow.right.circle", isBusy: session.isBusy) {
                                Task { await session.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
                            }
                            .accessibilityIdentifier("login.submit")

                            accountActions
                        }

                        if let error = session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(SQColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(SQSpace.xl)
                    .sqSoftCard()
                    .sqAuthAppear(appeared, delay: 0.08)

                    if !isTwoFactor {
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            handleAppleSignIn(result)
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 56)
                        .clipShape(Capsule(style: .continuous))
                        .accessibilityLabel("Continuer avec Apple")
                        .sqAuthAppear(appeared, delay: 0.10)
                    }

                    legalFooter
                        .sqAuthAppear(appeared, delay: 0.14)
                }
                .padding(SQSpace.xl)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .signalQuestHeroBackground()
            .onAppear {
                appeared = true
            }
            .sheet(isPresented: $showSignup) {
                NavigationStack { SignupView() }
            }
            .sheet(isPresented: $showForgotPassword) {
                NavigationStack { ForgotPasswordView() }
            }
        }
    }

    /// Liens légaux discrets (FOCUS « lien légal sur login » — LOGIN-LEGAL-01),
    /// réutilisant les URLs centralisées d'AppConfig comme SignupView.
    @ViewBuilder
    private var accountActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                recoveryButton
                signupButton
            }
        } else {
            HStack {
                recoveryButton
                Spacer()
                signupButton
            }
        }
    }

    private var recoveryButton: some View {
        Button { showForgotPassword = true } label: {
            Text("Mot de passe oublié ?")
                .font(SQType.caption)
                .foregroundStyle(SQColor.brandRed)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
        }
            .accessibilityIdentifier("login.recovery")
    }

    private var signupButton: some View {
        Button { showSignup = true } label: {
            Text("Créer un compte")
                .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(SQColor.brandRed)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
        }
            .accessibilityIdentifier("login.signup")
    }

    private var legalFooter: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.xs) {
                    termsLink
                    privacyLink
                }
            } else {
                HStack(spacing: SQSpace.xs) {
                    termsLink
                    Text("·").foregroundStyle(SQColor.labelSecondary)
                    privacyLink
                }
            }
        }
        .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
        .tint(SQColor.brandRed)
        .frame(maxWidth: .infinity)
        .padding(.top, SQSpace.sm)
    }

    private var termsLink: some View {
        Link("Conditions d’utilisation", destination: AppConfig.current.termsURL)
            .frame(minHeight: 48)
            .accessibilityIdentifier("login.terms")
    }

    private var privacyLink: some View {
        Link("Confidentialité", destination: AppConfig.current.privacyURL)
            .frame(minHeight: 48)
            .accessibilityIdentifier("login.privacy")
    }

    private var isTwoFactor: Bool {
        if case .requires2FA = session.state { return true }
        return false
    }

    /// Traite le résultat du bouton « Continuer avec Apple » : extrait le jeton
    /// d'identité (JWT signé par Apple) + le nom (fourni UNIQUEMENT à la 1re
    /// autorisation) et délègue au ViewModel.
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
            // Annulation utilisateur → silencieux ; autre erreur → message générique.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            session.errorMessage = "Connexion Apple impossible. Réessaie."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md + 2) {
            Image("SQLogoMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("SignalQuest")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                Text("Mesure, comprends et partage ton réseau")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(.top, SQSpace.huge + SQSpace.sm)
    }
}

struct GuestSpeedtestReceiptsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var receipts: [GuestSpeedtestDeletionReceipt] = []
    @State private var receiptToDelete: GuestSpeedtestDeletionReceipt?
    @State private var deletingID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if receipts.isEmpty {
                    EmptyStateView(
                        title: "Aucun reçu",
                        message: "Après un speedtest invité synchronisé, son droit de suppression apparaîtra ici.",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            Text(receipt.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(SQType.heading)
                                .foregroundStyle(SQColor.label)
                            Text("Mesure \(receipt.id.prefix(10))…")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                            Button(role: .destructive) {
                                receiptToDelete = receipt
                            } label: {
                                Label(
                                    deletingID == receipt.id ? "Suppression…" : "Supprimer cette mesure",
                                    systemImage: "trash"
                                )
                            }
                            .disabled(deletingID != nil)
                        }
                        .padding(.vertical, SQSpace.xs)
                    }
                }
            } footer: {
                Text("Les reçus sont chiffrés dans le trousseau de cet appareil. SignalQuest ne peut pas recréer un reçu perdu.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SQColor.danger)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Reçus invités")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
            }
        }
        .task { refresh() }
        .confirmationDialog(
            "Supprimer définitivement cette mesure ?",
            isPresented: Binding(
                get: { receiptToDelete != nil },
                set: { if !$0 { receiptToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer la mesure", role: .destructive) {
                guard let receipt = receiptToDelete else { return }
                Task { await delete(receipt) }
            }
            Button("Annuler", role: .cancel) { receiptToDelete = nil }
        } message: {
            Text("Le reçu sera effacé uniquement après confirmation du serveur.")
        }
    }

    private func refresh() {
        receipts = services.speedtest.guestDeletionReceipts()
    }

    private func delete(_ receipt: GuestSpeedtestDeletionReceipt) async {
        deletingID = receipt.id
        errorMessage = nil
        receiptToDelete = nil
        defer { deletingID = nil }
        do {
            try await services.speedtest.deleteGuestSpeedtest(receipt)
            refresh()
            Haptics.success()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            Haptics.error()
        }
    }
}

/// Champ « Crème & Terre cuite » : capsule 44, fond `SurfaceMuted`, sans
/// bordure (règle No-Border) — le focus passe par la teinte brique native.
struct SQTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(SQType.body)
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.md)
            .frame(minHeight: 44)
            .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
            .foregroundStyle(SQColor.label)
            .tint(SQColor.brandRed)
            .autocorrectionDisabled()
    }
}

// MARK: - Shared auth styling (soft appear)

/// Entrée douce (offset + opacity) des blocs d'un écran Auth au premier
/// affichage. Reduce Motion est respecté via `sqAnimation`.
private struct SQAuthAppearModifier: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
            .sqAnimation(SQMotion.emphasized.delay(delay), value: appeared)
    }
}

extension View {
    func sqAuthAppear(_ appeared: Bool, delay: Double = 0) -> some View {
        modifier(SQAuthAppearModifier(appeared: appeared, delay: delay))
    }
}
