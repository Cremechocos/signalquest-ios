import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var showSignup = false
    @State private var showForgotPassword = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.xxl) {
                    header
                        .sqAuthAppear(appeared)

                    VStack(alignment: .leading, spacing: SQSpace.lg) {
                        Text(isTwoFactor ? "Validation 2FA" : "Connexion")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)

                        if isTwoFactor {
                            TextField("Code TOTP", text: $code)
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                                .font(SQFont.display(28, .black))
                                .multilineTextAlignment(.center)
                                .textFieldStyle(SQTextFieldStyle())
                            GradientButton("Valider le code", systemImage: "checkmark.shield", isBusy: session.isBusy) {
                                Task { await session.verify2FA(code: code) }
                            }
                            Button("Annuler") { session.cancelTwoFactor() }
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.brandRed)
                                .frame(maxWidth: .infinity)
                        } else {
                            TextField("Email", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textFieldStyle(SQTextFieldStyle())
                            SecureField("Mot de passe", text: $password)
                                .textContentType(.password)
                                .textFieldStyle(SQTextFieldStyle())
                            GradientButton("Se connecter", systemImage: "arrow.right.circle", isBusy: session.isBusy) {
                                Task { await session.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
                            }

                            HStack {
                                Button("Mot de passe oublié ?") { showForgotPassword = true }
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.brandRed)
                                Spacer()
                                Button("Créer un compte") { showSignup = true }
                                    .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
                                    .foregroundStyle(SQColor.brandRed)
                            }
                        }

                        if let error = session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(SQColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(SQSpace.xl)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(SQColor.label, lineWidth: 2)
                    }
                    .sqAuthAppear(appeared, delay: 0.08)

                    legalFooter
                        .sqAuthAppear(appeared, delay: 0.14)
                }
                .padding(SQSpace.xl)
            }
            .background { SQAuthHalo() }
            .signalQuestHeroBackground()
            .onAppear { appeared = true }
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
    private var legalFooter: some View {
        HStack(spacing: SQSpace.xs) {
            Link("Conditions d’utilisation", destination: AppConfig.current.termsURL)
            Text("·").foregroundStyle(SQColor.labelTertiary)
            Link("Confidentialité", destination: AppConfig.current.privacyURL)
        }
        .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
        .tint(SQColor.brandRed)
        .frame(maxWidth: .infinity)
        .padding(.top, SQSpace.sm)
    }

    private var isTwoFactor: Bool {
        if case .requires2FA = session.state { return true }
        return false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md + 2) {
            Image("SQLogoMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .stroke(SQColor.separator, lineWidth: 1)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Réseau mobile, à nu").sqKicker()
                Text("SignalQuest")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
            }
        }
        .padding(.top, SQSpace.huge + SQSpace.sm)
    }
}

struct SQTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(SQType.body)
            .padding(SQSpace.md + 2)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .stroke(SQColor.separator, lineWidth: 1.5)
            }
            .foregroundStyle(SQColor.label)
            .autocorrectionDisabled()
    }
}

// MARK: - Shared auth styling (hero halo + soft appear)

/// Voile rouge très discret en haut de l'écran d'auth. La DA éditoriale est à
/// plat : on garde juste une touche de chaleur rouge, sans le mesh coloré.
struct SQAuthHalo: View {
    var body: some View {
        Ellipse()
            .fill(SQColor.brandRed.opacity(0.10))
            .frame(width: 420, height: 260)
            .blur(radius: 90)
            .offset(x: -60, y: -240)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

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
