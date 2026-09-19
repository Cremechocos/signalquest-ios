import SwiftUI
import AuthenticationServices

struct LoginView: View {
    let onboardingRequest: OnboardingEntryRequest?
    let onOnboardingReserve: (OnboardingEntryRequest) -> OnboardingGuestLease?
    let onOnboardingPresented: (OnboardingGuestLease) -> Bool

    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var onboardingEntry: OnboardingEntryState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var showSignup = false
    @State private var showForgotPassword = false
    @State private var guestPresentation: OnboardingEntryRequest?
    @State private var onboardingLease: OnboardingGuestLease?
    @State private var appeared = false

    init(onboardingRequest: OnboardingEntryRequest? = nil,
         onOnboardingReserve: @escaping (OnboardingEntryRequest) -> OnboardingGuestLease? = { _ in nil },
         onOnboardingPresented: @escaping (OnboardingGuestLease) -> Bool = { _ in false }) {
        self.onboardingRequest = onboardingRequest
        self.onOnboardingReserve = onOnboardingReserve
        self.onOnboardingPresented = onOnboardingPresented
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.xxl) {
                    header
                        .sqAuthAppear(appeared)

                    if !isTwoFactor {
                        GradientButton(String(localized: "Explorer sans compte"), systemImage: "map", style: .secondary) {
                            openGuest(.map)
                        }
                        .accessibilityLabel("Explorer la carte sans compte")
                        .accessibilityIdentifier("login.guestMap")
                        .sqAuthAppear(appeared, delay: 0.11)

                        GradientButton(String(localized: "Tester sans compte"), systemImage: "speedometer", style: .secondary) {
                            openGuest(.measure)
                        }
                        .accessibilityLabel("Lancer un speedtest sans compte")
                        .accessibilityIdentifier("login.guestMeasure")
                        .sqAuthAppear(appeared, delay: 0.12)
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
                            TextField("Code à 6 chiffres", text: $code)
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                                .font(SQFont.display(28, .bold))
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
                            .accessibilityIdentifier("login.submit")

                            HStack {
                                Button("Mot de passe oublié ?") { showForgotPassword = true }
                                    .accessibilityIdentifier("login.recovery")
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.brandRed)
                                Spacer()
                                Button("Créer un compte") { showSignup = true }
                                    .accessibilityIdentifier("login.signup")
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
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
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
                offerOnboardingDestination()
            }
            .onChangeCompat(of: onboardingRequest) { _, _ in offerOnboardingDestination() }
            .onChangeCompat(of: onboardingEntry.guestPresentationRevision) { _, _ in offerOnboardingDestination() }
            .onChangeCompat(of: scenePhase) { _, _ in offerOnboardingDestination() }
            .onChangeCompat(of: isTwoFactor) { _, _ in offerOnboardingDestination() }
            .sheet(isPresented: $showSignup, onDismiss: offerOnboardingDestination) {
                NavigationStack { SignupView() }
            }
            .sheet(isPresented: $showForgotPassword, onDismiss: offerOnboardingDestination) {
                NavigationStack { ForgotPasswordView() }
            }
            .fullScreenCover(item: $guestPresentation, onDismiss: {
                onboardingLease?.release()
                onboardingLease = nil
                offerOnboardingDestination()
            }) { request in
                Group {
                    switch request.destination {
                    case .map: GuestMapPreview()
                    case .measure: GuestSpeedtestPreview()
                    }
                }
                .environmentObject(services)
                .environmentObject(router)
                .onAppear {
                    // Le disque n'est acquitté qu'après apparition, par la
                    // seule réservation encore valide et sa scène active.
                    if let lease = onboardingLease, !lease.didPresent, lease.request.id == request.id {
                        guard scenePhase == .active, onOnboardingPresented(lease) else {
                            lease.release()
                            onboardingLease = nil
                            guestPresentation = nil
                            return
                        }
                    }
                }
            }
        }
    }

    private func offerOnboardingDestination() {
        let eligible = scenePhase == .active && !isTwoFactor && !showSignup && !showForgotPassword
        if let lease = onboardingLease {
            // La consommation du pending après apparition ne referme pas le
            // preview affiché. Seule une réservation non acquittée est révoquée.
            if lease.didPresent { return }
            if !eligible || onboardingRequest?.id != lease.request.id || !lease.isValid {
                lease.release()
                onboardingLease = nil
                if guestPresentation?.id == lease.request.id { guestPresentation = nil }
            } else { return }
        }
        guard eligible, guestPresentation == nil, let onboardingRequest,
              let lease = onOnboardingReserve(onboardingRequest) else { return }
        onboardingLease = lease
        guestPresentation = onboardingRequest
    }

    private func openGuest(_ destination: OnboardingEntryDestination) {
        // Un nouveau geste explicite remplace une intention automatique encore
        // en attente, y compris une réservation dans une autre fenêtre.
        onboardingLease?.release()
        onboardingLease = nil
        if let pending = onboardingEntry.pending { onboardingEntry.consume(pending) }
        router.routeFromOnboarding(to: destination)
        guestPresentation = OnboardingEntryRequest(destination: destination)
    }

    /// Liens légaux discrets (FOCUS « lien légal sur login » — LOGIN-LEGAL-01),
    /// réutilisant les URLs centralisées d'AppConfig comme SignupView.
    private var legalFooter: some View {
        HStack(spacing: SQSpace.xs) {
            Link("Conditions d’utilisation", destination: AppConfig.current.termsURL)
            Text("·").foregroundStyle(SQColor.labelSecondary)
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

/// Mode découverte (ONB-USER-01) : la carte communautaire accessible SANS compte.
/// Les actions contributives nécessitent une connexion (échec géré côté services).
/// Hérite de `services`/`router` de l'environnement (injectés sur RootView).
private struct GuestMapPreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Le commentaire ci-dessus disait déjà que les services viennent de
    /// l'environnement — mais `MapExplorerView()` s'appuyait sur ses valeurs par
    /// défaut et construisait donc un SECOND graphe complet : autre `APIClient`,
    /// autre `DiskCache` sur le même dossier, autre coalescing de refresh.
    @EnvironmentObject private var services: AppServices
    var body: some View {
        NavigationStack {
            MapExplorerView(
                service: services.map,
                antennas: services.antennas,
                markets: services.markets,
                communityOutages: services.communityOutages
            )
                // MapExplorerView masque volontairement sa navigation bar. Une
                // safe-area dédiée garde donc les sorties invité visibles et
                // accessibles, indépendamment de cette préférence interne.
                .safeAreaInset(edge: .top, spacing: 0) {
                    guestNavigationControls
                    .foregroundStyle(SQColor.brandRed)
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 50)
                    .background {
                        Rectangle()
                            .fill(SQColor.surfaceGlass)
                            .background(.ultraThinMaterial)
                            .ignoresSafeArea(edges: .top)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(SQColor.separator)
                            .frame(height: 1 / UIScreen.main.scale)
                    }
                }
        }
    }

    @ViewBuilder
    private var guestNavigationControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: SQSpace.xs) {
                guestTitle
                HStack(spacing: SQSpace.md) {
                    closeButton
                    Spacer(minLength: SQSpace.sm)
                    signInButton
                }
            }
            .padding(.vertical, SQSpace.xs)
        } else {
            HStack(spacing: SQSpace.md) {
                closeButton
                Spacer(minLength: SQSpace.sm)
                guestTitle
                Spacer(minLength: SQSpace.sm)
                signInButton
            }
        }
    }

    private var guestTitle: some View {
        Text("Explorer")
            .font(SQFont.archivo(16, .bold))
            .foregroundStyle(SQColor.label)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isHeader)
    }

    private var closeButton: some View {
        Button("Fermer") { dismiss() }
            .accessibilityIdentifier("guest.close")
            .font(SQFont.archivo(15, .semibold))
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
    }

    private var signInButton: some View {
        Button("Se connecter") { dismiss() }
            .accessibilityIdentifier("guest.signIn")
            .font(SQFont.archivo(14, .bold))
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
    }
}

/// Speedtest utilisable sans compte, avec la même politique de publication
/// des nouvelles mesures et les reçus personnels de suppression.
private struct GuestSpeedtestPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showReceipts = false

    var body: some View {
        NavigationStack {
            SpeedtestView(guestMode: true)
                .navigationTitle("Test invité")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                            .accessibilityIdentifier("guest.close")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Mes reçus") { showReceipts = true }
                            .font(SQFont.archivo(14, .bold))
                            .tint(SQColor.brandRed)
                    }
                }
        }
        .sheet(isPresented: $showReceipts) {
            NavigationStack { GuestSpeedtestReceiptsView() }
        }
    }
}

private struct GuestSpeedtestReceiptsView: View {
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
