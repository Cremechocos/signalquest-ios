import SwiftUI
import AuthenticationServices

/// Pourquoi l'écran de connexion apparaît dans un onglet réservé aux membres :
/// l'invité y lit ce qu'il y trouvera, au lieu d'un simple mur (TRX-19).
enum LoginContext {
    case community, profile

    var title: String {
        switch self {
        case .community: return String(localized: "Rejoins la communauté")
        case .profile: return String(localized: "Ton espace SignalQuest")
        }
    }

    var message: String {
        switch self {
        case .community:
            return String(localized: "Le fil, l’entraide entre membres et la messagerie demandent un compte gratuit.")
        case .profile:
            return String(localized: "Un compte gratuit garde tes mesures, tes points et tes réglages, sur iPhone comme sur Android.")
        }
    }
}

struct LoginView: View {
    let onContinueAsGuest: (() -> Void)?
    let context: LoginContext?

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
    @State private var pendingAppleConsent: PendingAppleConsent?
    @State private var appeared = false
    @FocusState private var focus: Field?

    private enum Field { case email, password, code }

    private struct PendingAppleConsent: Identifiable {
        let id = UUID()
        let identityToken: String
        let fullName: String?
    }

    init(onContinueAsGuest: (() -> Void)? = nil, context: LoginContext? = nil) {
        self.onContinueAsGuest = onContinueAsGuest
        self.context = context
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if isTwoFactor { twoFactorContent } else { signInContent }
                    }
                    .padding(.horizontal, SQSpace.xl)
                    .padding(.top, SQSpace.sm)
                    .padding(.bottom, SQSpace.lg)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .signalQuestHeroBackground()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                appeared = true
                // « Créer un compte » en fin d'onboarding : l'inscription s'ouvre
                // directement, la connexion reste derrière si on la referme.
                if onboardingEntry.consumeSignupRequest() { showSignup = true }
            }
            .onChangeCompat(of: code) { _, value in
                // Six chiffres saisis : le code part seul, le bouton reste pour réessayer.
                let digits = String(value.filter(\.isNumber).prefix(6))
                if digits != value { code = digits; return }
                if digits.count == 6 { submitCode() }
            }
            .sheet(isPresented: $showSignup) {
                NavigationStack { SignupView() }
            }
            .sheet(isPresented: $showForgotPassword) {
                NavigationStack { ForgotPasswordView(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .sheet(item: $pendingAppleConsent) { credential in
                AppleTermsConsentSheet(identityToken: credential.identityToken, fullName: credential.fullName) {
                    pendingAppleConsent = nil
                }
            }
        }
    }

    // MARK: Connexion

    private var signInContent: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            if let onContinueAsGuest {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: onContinueAsGuest) {
                        Text("Plus tard")
                            .font(SQType.callout(.semibold))
                            .foregroundStyle(SQColor.label)
                            .padding(.horizontal, SQSpace.md2)
                            .frame(minHeight: 36)
                            .background(SQColor.surface, in: Capsule(style: .continuous))
                            .overlay { Capsule(style: .continuous).strokeBorder(SQColor.separator, lineWidth: 1) }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Le libellé lu reste explicite : « Plus tard » seul ne dit pas ce qu'on évite.
                    .accessibilityLabel("Continuer sans compte")
                    .accessibilityIdentifier("login.continueGuest")
                    .disabled(session.isBusy)
                }
            }

            AuthHeader(title: context?.title ?? String(localized: "Connexion"),
                       message: context?.message ?? String(localized: "Retrouve tes mesures, tes amis et tes points."),
                       showsLogo: true)
                .padding(.top, onContinueAsGuest == nil ? SQSpace.xxl : 0)
                .sqAuthAppear(appeared)

            // Raison du retour à la connexion (session expirée, compte suspendu ou
            // supprimé, mot de passe changé), posée par la session.
            if let info = session.infoMessage {
                SQNotice(message: info, systemImage: "info.circle")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("login.info")
            }

            Group {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(SQOledPalette.appleButtonStyle(colorScheme))
                .frame(height: 50)
                .clipShape(Capsule(style: .continuous))
                .accessibilityLabel("Continuer avec Apple")
                .disabled(session.isBusy)

                AuthOrDivider()

                AuthFieldGroup {
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
                    } onTap: { focus = .email }
                    AuthFieldDivider()
                    AuthFieldRow("Mot de passe", isFocused: focus == .password) {
                        AuthPasswordInput(label: "Mot de passe", text: $password, contentType: .password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(login)
                    } onTap: { focus = .password }
                }

                HStack {
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    recoveryButton
                }
                .padding(.top, -SQSpace.sm)

                if let error = session.errorMessage {
                    SQNotice(message: error, systemImage: "exclamationmark.triangle", tone: .danger)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("login.error")
                }

                GradientButton("Se connecter", isBusy: session.isBusy, action: login)
                    .accessibilityIdentifier("login.submit")
            }
            .sqAuthAppear(appeared, delay: 0.08)

            Spacer(minLength: SQSpace.xl)

            VStack(spacing: SQSpace.xs) {
                signupLine
                legalFooter
            }
            .frame(maxWidth: .infinity)
            .sqAuthAppear(appeared, delay: 0.12)
        }
    }

    private func login() {
        guard !session.isBusy else { return }
        focus = nil
        Task { await session.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
    }

    private var recoveryButton: some View {
        Button { showForgotPassword = true } label: {
            Text("Mot de passe oublié ?")
                .font(SQType.caption(.bold))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("login.recovery")
    }

    /// « Pas encore de compte ? Créer un compte » : la question se lit, seul le lien agit.
    private var signupLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.xs) { signupQuestion; signupButton }
            VStack(spacing: 0) { signupQuestion; signupButton }
        }
    }

    private var signupQuestion: some View {
        Text("Pas encore de compte ?")
            .font(SQType.callout)
            .foregroundStyle(SQColor.ink2)
    }

    private var signupButton: some View {
        Button { showSignup = true } label: {
            Text("Créer un compte")
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("login.signup")
    }

    /// Liens légaux discrets (LOGIN-LEGAL-01), URLs centralisées d'AppConfig.
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
                    Text(verbatim: "·").foregroundStyle(SQColor.labelSecondary)
                    privacyLink
                }
            }
        }
        .font(SQType.caption)
        .tint(SQColor.labelSecondary)
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity)
    }

    private var termsLink: some View {
        Link("Conditions d’utilisation", destination: AppConfig.current.termsURL)
            .frame(minHeight: 44)
            .accessibilityIdentifier("login.terms")
    }

    private var privacyLink: some View {
        Link("Confidentialité", destination: AppConfig.current.privacyURL)
            .frame(minHeight: 44)
            .accessibilityIdentifier("login.privacy")
    }

    // MARK: Code de vérification

    private var twoFactorContent: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            MapChipIconButton(systemImage: "chevron.left", label: "Annuler", identifier: "login.twoFactor.cancel") {
                code = ""
                session.cancelTwoFactor()
            }
            SQIconPastille(systemImage: "checkmark.shield", size: 52, font: SQFont.body(22, .semibold, relativeTo: .title3))
            AuthHeader(title: String(localized: "Code de vérification"),
                       message: String(localized: "Saisis le code à 6 chiffres de ton application d’authentification (Google Authenticator, Authy…)."),
                       showsLogo: false)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                AuthCodeBoxes(code: $code, isFocused: focus == .code)
                    .focused($focus, equals: .code)
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("login.twoFactor.error")
                }
            }
            GradientButton("Valider", isBusy: session.isBusy, action: submitCode)
                .disabled(code.count < 6)
                .accessibilityIdentifier("login.twoFactor.submit")
        }
        .onAppear { focus = .code }
    }

    private func submitCode() {
        guard isTwoFactor, code.count == 6, !session.isBusy else { return }
        Task { await session.verify2FA(code: code) }
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
                    acceptedTerms: false
                )
                if case .requiresTerms = outcome {
                    pendingAppleConsent = PendingAppleConsent(identityToken: identityToken,
                                                              fullName: fullName.isEmpty ? nil : fullName)
                }
            }
        case .failure(let error):
            // Annulation utilisateur → silencieux ; autre erreur → message générique.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            session.errorMessage = String(localized: "Connexion Apple impossible. Réessaie.")
        }
    }
}

/// « Une dernière étape » : aucun compte n'est lié à cet identifiant Apple, on le
/// crée seulement après l'acceptation des conditions. Partagée par la connexion et
/// l'inscription.
struct AppleTermsConsentSheet: View {
    let identityToken: String
    let fullName: String?
    let onFinish: () -> Void

    @EnvironmentObject private var session: AuthSessionViewModel
    @State private var acceptedTerms = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack(alignment: .top, spacing: SQSpace.md) {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Avec ton identifiant Apple").sqKicker()
                        Text("Une dernière étape")
                            .font(SQFont.display(22, .bold, relativeTo: .title2))
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                    }
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "login.apple.close", action: onFinish)
                        .disabled(session.isBusy)
                }
                Text("Aucun compte SignalQuest n’est encore lié à cet identifiant Apple. Pour le créer, accepte les conditions.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                AuthConsentCheckbox(isOn: $acceptedTerms, identifier: "login.apple.terms")
                if let error = session.errorMessage {
                    SQNotice(message: error, systemImage: "exclamationmark.triangle", tone: .danger)
                }
                GradientButton("Créer mon compte", systemImage: "apple.logo", isBusy: session.isBusy) {
                    Task {
                        let outcome = await session.signInWithApple(identityToken: identityToken, fullName: fullName,
                                                                    acceptedTerms: acceptedTerms)
                        if case .continued = outcome { onFinish() }
                    }
                }
                .disabled(!acceptedTerms || session.isBusy)
                .accessibilityIdentifier("login.apple.accept")
                Button("Annuler", action: onFinish)
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(SQColor.ink2)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(session.isBusy)
            }
            .padding(SQSpace.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium, .large])
        .sqSheet(background: SQColor.surface)
        .interactiveDismissDisabled(session.isBusy)
    }
}

struct GuestSpeedtestReceiptsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var receipts: [GuestSpeedtestDeletionReceipt] = []
    @State private var receiptToDelete: GuestSpeedtestDeletionReceipt?
    @State private var deletingID: String?
    @State private var errorMessage: String?
    /// Un reçu ne garde que des identifiants : débit et réseau viennent de
    /// l'historique local (`clientSubmissionId` = id du résultat), s'il existe encore.
    @State private var localResults: [String: SpeedtestRunResult] = [:]

    var body: some View {
        List {
            Section {
                if receipts.isEmpty {
                    EmptyStateView(
                        title: "Aucun test partagé",
                        message: "Les speedtests que tu partages sans compte apparaîtront ici. Tu pourras les supprimer à tout moment.",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(receipts) { receipt in
                        let local = localResults[receipt.clientSubmissionId].map(SpeedtestHistoryRow.init(result:))
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            Text(local?.titleLine ?? receipt.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(SQType.heading)
                                .foregroundStyle(SQColor.label)
                            if let local {
                                Text(local.subtitleLine)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
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
                Text("Sans compte, le droit de supprimer ces tests est gardé dans le trousseau de cet appareil. S’il est perdu, SignalQuest ne peut pas le recréer.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SQColor.dangerInk)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Tests partagés")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
            }
        }
        .task {
            refresh()
            let history = await services.speedtest.history()
            localResults = Dictionary(history.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        }
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
            Text("Elle sera effacée des serveurs de SignalQuest et de la carte.")
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
            if !error.isCancellation { errorMessage = error.userFacingMessage }
            Haptics.error()
        }
    }
}

/// Champ Halo : 44 pt, 14 pt de coins, fond tuile et filet de 1 pt (`sqFieldSurface`).
struct SQTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(SQType.body)
            .padding(.horizontal, SQSpace.md2)
            .padding(.vertical, SQSpace.sm2)
            .frame(minHeight: 44)
            // Le fond tuile a la couleur de la page : le filet dessine le champ.
            .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .foregroundStyle(SQColor.label)
            .tint(SQColor.brandRed)
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

// MARK: - Briques Halo des écrans d'authentification

/// Logo de l'app (le dessin de l'icône), titre et phrase d'un écran d'authentification.
struct AuthHeader: View {
    let title: String
    let message: String?
    var showsLogo = true

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            if showsLogo {
                // L'icône de l'app, avec ses coins et un filet : sur le fond crème,
                // elle se lit comme l'icône de l'écran d'accueil.
                Image("SQLogoMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(SQColor.separator, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: SQSpace.xs2) {
                Text(verbatim: title)
                    .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                if let message {
                    Text(verbatim: message)
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Filet « ou avec ton e-mail » entre Apple et le formulaire.
struct AuthOrDivider: View {
    var body: some View {
        HStack(spacing: SQSpace.sm2) {
            Rectangle().fill(SQColor.separator).frame(height: 1)
            Text("ou avec ton e-mail")
                .font(SQType.caption(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize()
            Rectangle().fill(SQColor.separator).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Champs groupés sur une seule carte, séparés par un filet.
struct AuthFieldGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                    .strokeBorder(SQColor.separator, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }
}

struct AuthFieldDivider: View {
    var body: some View {
        Rectangle().fill(SQColor.separator).frame(height: 1).padding(.leading, SQSpace.md2)
    }
}

/// Une rangée : le libellé dans le champ, au-dessus de la saisie. Le libellé n'est
/// pas lu à part : le champ porte déjà son nom accessible.
struct AuthFieldRow<Field: View>: View {
    let label: LocalizedStringKey
    var isFocused = false
    var isError = false
    /// Indication courte à droite du libellé, comme un compteur de caractères.
    var accessory: Text?
    let field: Field
    let onTap: () -> Void

    init(_ label: LocalizedStringKey, isFocused: Bool = false, isError: Bool = false, accessory: Text? = nil,
         @ViewBuilder field: () -> Field, onTap: @escaping () -> Void) {
        self.label = label
        self.isFocused = isFocused
        self.isError = isError
        self.accessory = accessory
        self.field = field()
        self.onTap = onTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xxs) {
            HStack(spacing: SQSpace.sm) {
                Text(label)
                    .foregroundStyle(isError ? SQColor.dangerInk : SQColor.labelSecondary)
                    .accessibilityHidden(true)
                if let accessory {
                    Spacer(minLength: 0)
                    accessory.foregroundStyle(SQColor.labelSecondary)
                }
            }
            .font(SQType.caption(.bold))
            field
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .tint(SQColor.brandRed)
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.sm2)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .overlay(alignment: .leading) {
            if isFocused || isError {
                Rectangle().fill(isError ? SQColor.danger : SQColor.brandRed).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Mot de passe avec l'œil pour relire la saisie : il remplace le champ de confirmation.
struct AuthPasswordInput: View {
    let label: LocalizedStringKey
    @Binding var text: String
    let contentType: UITextContentType
    var identifier: String?
    @State private var revealed = false

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            Group {
                if revealed {
                    TextField(label, text: $text, prompt: Text(verbatim: ""))
                } else {
                    SecureField(label, text: $text, prompt: Text(verbatim: ""))
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(Text(label))
            .modifier(OptionalIdentifier(identifier: identifier))
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Masquer le mot de passe" : "Afficher le mot de passe")
        }
    }

    private struct OptionalIdentifier: ViewModifier {
        let identifier: String?
        func body(content: Content) -> some View {
            if let identifier { content.accessibilityIdentifier(identifier) } else { content }
        }
    }
}

/// Six cases, une par chiffre. Un vrai champ invisible reçoit la saisie (et le
/// remplissage automatique du code) ; les cases ne font que l'afficher.
struct AuthCodeBoxes: View {
    @Binding var code: String
    var isFocused = false

    var body: some View {
        ZStack {
            HStack(spacing: SQSpace.xs2) {
                ForEach(0..<6, id: \.self) { index in
                    let digits = Array(code)
                    let isCurrent = isFocused && index == min(digits.count, 5)
                    Text(verbatim: index < digits.count ? String(digits[index]) : "")
                        .font(SQFont.display(24, .bold, relativeTo: .title2))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                                .strokeBorder(isCurrent ? SQColor.brandRed : SQColor.separator,
                                              lineWidth: isCurrent ? 1.5 : 1)
                        }
                }
            }
            .accessibilityHidden(true)
            TextField("Code à 6 chiffres", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .autocorrectionDisabled()
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 56)
                .accessibilityLabel("Code à 6 chiffres")
                .accessibilityIdentifier("login.twoFactor.code")
        }
    }
}

/// Case à cocher du consentement : la phrase porte les deux liens.
struct AuthConsentCheckbox: View {
    @Binding var isOn: Bool
    let identifier: String

    var body: some View {
        HStack(alignment: .top, spacing: SQSpace.xs2) {
            Button { isOn.toggle() } label: {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? SQColor.brandRed : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isOn ? SQColor.brandRed : SQColor.labelSecondary, lineWidth: 1.5)
                    }
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(SQColor.onAccent)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -11)
            .accessibilityLabel("J’accepte les conditions d’utilisation et la politique de confidentialité.")
            .accessibilityValue(isOn ? Text("Cochée") : Text("Non cochée"))
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityIdentifier(identifier)
            Text(sentence)
                .font(SQType.caption)
                .foregroundStyle(SQColor.ink2)
                .tint(SQColor.accentInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    /// La phrase traduite, avec ses deux passages rendus cliquables.
    private var sentence: AttributedString {
        var text = AttributedString(localized: "J’accepte les conditions d’utilisation et la politique de confidentialité.")
        for (part, url) in [(String(localized: "conditions d’utilisation"), AppConfig.current.termsURL),
                            (String(localized: "politique de confidentialité"), AppConfig.current.privacyURL)] {
            if let range = text.range(of: part) {
                text[range].link = url
                text[range].underlineStyle = .single
            }
        }
        return text
    }
}
