import SwiftUI
import AuthenticationServices

/// Déverrouillage (ou première création) de la clé E2EE. Si le compte n'a pas
/// encore de clé côté serveur, le même mot de passe sert à en générer une —
/// parité avec le flux Android `createBootstrap`.
struct E2EEUnlockSheet: View {
    let userId: String
    let service: E2EEServicing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var passwordFocused: Bool
    @FocusState private var confirmationFocused: Bool
    @State private var password = ""
    /// Création : la clé ne se récupère pas, une faute de frappe la rendrait
    /// inutilisable (SOC-08).
    @State private var confirmation = ""
    @State private var isBusy = false
    @State private var error: String?
    @State private var needsCreation = false
    /// Mot de passe oublié : une nouvelle clé remplace l'ancienne, sur preuve du
    /// compte (SOC-08).
    @State private var isReplacing = false
    @State private var accountPassword = ""
    /// Proposer de mémoriser le mot de passe E2EE derrière Face ID / Touch ID.
    @State private var rememberWithBiometric = false
    @State private var revealsPassword = false
    @State private var didAttemptBiometric = false
    /// Apparition douce du badge cadenas (scale 0.9 → 1, SQMotion.emphasized).
    @State private var badgeAppeared = false
    var onUnlock: () -> Void

    /// Création ou remplacement : un nouveau mot de passe, saisi deux fois.
    private var choosesNewPassword: Bool { needsCreation || isReplacing }

    private var newPasswordIsValid: Bool { password.count >= 6 && password == confirmation }

    private var canSubmit: Bool {
        guard !isBusy else { return false }
        if isReplacing { return newPasswordIsValid && !accountPassword.isEmpty }
        return needsCreation ? newPasswordIsValid : !password.isEmpty
    }

    private var confirmationMismatch: Bool {
        choosesNewPassword && !confirmation.isEmpty && confirmation != password
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: "e2ee.key.cancel") { dismiss() }

                VStack(spacing: SQSpace.sm) {
                    badge
                    Text(isReplacing ? "Nouvelle clé" : needsCreation ? "Créer ta clé" : "Déverrouiller")
                        .font(SQFont.display(26, .bold, relativeTo: .title))
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    // Deux mots de passe distincts : celui du compte et celui du
                    // chiffrement. Le texte le dit, pour qu'on ne les confonde pas.
                    Text(isReplacing
                         ? "Ton ancien mot de passe ne se retrouve pas. Une nouvelle clé remplace l’ancienne : chaque conversation chiffrée redevient lisible quand un autre participant la rouvre, son app te renvoyant la clé. Tes autres appareils se déverrouilleront avec le nouveau mot de passe."
                         : needsCreation
                         ? "Choisis un mot de passe de chiffrement, différent de celui de ton compte. Lui seul ouvre tes conversations chiffrées : s’il est perdu, personne ne peut le retrouver, pas même SignalQuest, et les messages chiffrés deviennent illisibles."
                         : "Ton mot de passe de chiffrement, choisi à la création de ta clé et différent de celui de ton compte, ouvre tes conversations chiffrées le temps de la session.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    passwordField

                    if choosesNewPassword {
                        SecureField("Confirme ce mot de passe", text: $confirmation)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .padding(.horizontal, SQSpace.lg)
                            .padding(.vertical, SQSpace.sm2)
                            .frame(minHeight: 50)
                            .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                            .focused($confirmationFocused)
                            .submitLabel(.done)
                            .onSubmit { if canSubmit { Task { await unlockOrCreate() } } }
                            .accessibilityIdentifier("e2ee.key.confirmation")
                        if confirmationMismatch {
                            Label("Les deux mots de passe ne correspondent pas.", systemImage: "exclamationmark.circle")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if choosesNewPassword {
                        Label("6 caractères minimum. Ce mot de passe ne quitte jamais ton appareil.", systemImage: "info.circle")
                            .font(SQType.caption)
                            // `Label` porte du texte : `labelTertiary` est
                            // désormais réservé aux éléments graphiques (3:1),
                            // pas au texte courant (4,5:1).
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isReplacing {
                        accountConfirmation
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }

                    if !needsCreation {
                        Button {
                            Haptics.selection()
                            startReplacing(!isReplacing)
                        } label: {
                            Text(isReplacing ? "J’ai retrouvé mon mot de passe" : "Mot de passe oublié ?")
                                .font(SQType.subhead(.semibold))
                                .foregroundStyle(SQColor.accentInk)
                                .padding(.horizontal, SQSpace.xs)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityIdentifier("e2ee.key.forgot")
                    }
                }

                // Proposer la mémorisation biométrique (1re fois, pas en création).
                if !choosesNewPassword, BiometricAuth.isAvailable, !E2EEBiometric.isEnabled {
                    Toggle(isOn: $rememberWithBiometric) {
                        HStack(spacing: SQSpace.md) {
                            Image(systemName: BiometricAuth.kind.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(SQColor.label)
                                .frame(width: 36, height: 36)
                                .background(SQColor.chip, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                                .accessibilityHidden(true)
                            Text("Mémoriser avec \(BiometricAuth.kind.label)")
                                .font(SQType.body(.semibold))
                                .foregroundStyle(SQColor.label)
                        }
                    }
                    .tint(SQColor.brandRed)
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 56)
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }

                if !choosesNewPassword {
                    Text("Ce mot de passe ne quitte jamais ton appareil.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        // Actions ÉPINGLÉES : elles restent visibles au-dessus du clavier (le
        // détent medium + clavier masquait l'action quand elle était dans le scroll).
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: SQSpace.sm) {
                GradientButton(
                    isReplacing ? "Remplacer ma clé" : needsCreation ? "Créer et activer" : "Déverrouiller",
                    systemImage: "key.fill",
                    isBusy: isBusy
                ) {
                    Task {
                        if isReplacing { await replaceKey(using: .password(accountPassword)) }
                        else { await unlockOrCreate() }
                    }
                }
                .disabled(!canSubmit)

                // Déverrouillage biométrique direct (déjà mémorisé).
                if !choosesNewPassword, E2EEBiometric.isEnabled, E2EEBiometric.hasStored {
                    GradientButton(
                        String(localized: "Déverrouiller avec \(BiometricAuth.kind.label)"),
                        systemImage: BiometricAuth.kind.systemImage,
                        style: .secondary
                    ) {
                        Task { await biometricUnlock() }
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.md)
            .background(SQColor.bg.ignoresSafeArea(edges: .bottom))
        }
        .task {
            await checkExistingKey()
            // Déverrouillage biométrique automatique si déjà mémorisé.
            if !needsCreation, E2EEBiometric.isEnabled, E2EEBiometric.hasStored, !didAttemptBiometric {
                didAttemptBiometric = true
                await biometricUnlock()
            } else {
                passwordFocused = true
            }
        }
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sqAnimation(.snappy(duration: 0.25), value: error)
        .sqAnimation(.snappy(duration: 0.25), value: needsCreation)
    }

    /// Champ du mot de passe de chiffrement : clé à gauche, œil pour l'afficher.
    private var passwordField: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "key")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
            // Pas de `textContentType` mot de passe : iOS proposait un mot de
            // passe fort et l'enregistrait pour le compte SignalQuest.
            Group {
                if revealsPassword {
                    TextField(isReplacing ? "Nouveau mot de passe de chiffrement" : "Mot de passe de chiffrement", text: $password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField(isReplacing ? "Nouveau mot de passe de chiffrement" : "Mot de passe de chiffrement", text: $password)
                }
            }
            .font(SQType.body)
            .foregroundStyle(SQColor.label)
            .focused($passwordFocused)
            .submitLabel(choosesNewPassword ? .next : .go)
            .onSubmit {
                if choosesNewPassword { confirmationFocused = true }
                else if canSubmit { Task { await unlockOrCreate() } }
            }
            Button {
                revealsPassword.toggle()
                passwordFocused = true
            } label: {
                Image(systemName: revealsPassword ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealsPassword ? "Masquer le mot de passe" : "Afficher le mot de passe")
        }
        .padding(.leading, SQSpace.lg)
        .padding(.trailing, SQSpace.xs)
        .frame(minHeight: 50)
        .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    /// Bouclier vert sur pastille douce : la clé protège, elle n'alerte pas.
    private var badge: some View {
        Image(systemName: choosesNewPassword ? "lock.badge.clock" : "lock.shield")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(SQColor.success)
            .frame(width: 60, height: 60)
            .background(SQColor.successSoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .scaleEffect(badgeAppeared ? 1 : 0.9)
            .opacity(badgeAppeared ? 1 : 0)
            .onAppear {
                withAnimation(SQMotion.resolve(SQMotion.emphasized, reduceMotion)) {
                    badgeAppeared = true
                }
            }
            .accessibilityHidden(true)
    }

    /// Preuve du compte pour le remplacement : son mot de passe, ou Apple pour
    /// un compte créé avec Apple. Le serveur refuse un code reçu par e-mail ici.
    private var accountConfirmation: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Confirme ton compte")
                .font(SQType.caption.weight(.semibold))
                .foregroundStyle(SQColor.label)
            SecureField("Mot de passe du compte", text: $accountPassword)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.sm2)
                .frame(minHeight: 44)
                .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .submitLabel(.go)
                .onSubmit { if canSubmit { Task { await replaceKey(using: .password(accountPassword)) } } }
                .accessibilityIdentifier("e2ee.key.accountPassword")
            Text("Compte créé avec Apple ? Confirme plutôt avec Apple.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                handleAppleConfirmation(result)
            }
            .signInWithAppleButtonStyle(SQOledPalette.appleButtonStyle(colorScheme))
            .frame(height: 44)
            .clipShape(Capsule())
            .disabled(!newPasswordIsValid || isBusy)
            .opacity(newPasswordIsValid && !isBusy ? 1 : 0.5)
        }
    }

    private func startReplacing(_ replacing: Bool) {
        isReplacing = replacing
        password = ""
        confirmation = ""
        accountPassword = ""
        error = nil
        passwordFocused = true
    }

    private func handleAppleConfirmation(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                error = String(localized: "Jeton Apple manquant. Réessaie.")
                return
            }
            Task { await replaceKey(using: .apple(identityToken: identityToken)) }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code == .canceled { return }
            error = String(localized: "Réauthentification Apple impossible. Réessaie.")
        }
    }

    private func replaceKey(using reauthentication: E2EEV2BootstrapReauthentication) async {
        guard newPasswordIsValid, !isBusy else { return }
        passwordFocused = false
        confirmationFocused = false
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.replaceForgottenKey(
                userId: userId, password: password, reauthentication: reauthentication
            )
            // L'ancien mot de passe mémorisé n'ouvre plus rien : on garde le nouveau.
            if E2EEBiometric.isEnabled { E2EEBiometric.store(password: password) }
            Haptics.success()
            onUnlock()
            dismiss()
        } catch {
            self.error = error.userFacingMessage
            Haptics.error()
        }
    }

    private func checkExistingKey() async {
        if let bootstrap = try? await service.bootstrap() {
            needsCreation = !bootstrap.hasKey || bootstrap.key == nil
        }
    }

    private func unlockOrCreate() async {
        passwordFocused = false
        confirmationFocused = false
        isBusy = true
        defer { isBusy = false }
        do {
            let bootstrap = try await service.bootstrap()
            if let key = bootstrap.key, bootstrap.hasKey {
                try await service.unlock(userId: userId, password: password, bootstrapKey: key)
            } else {
                try await service.generateAndRegisterKey(userId: userId, password: password)
            }
            // Mémorise le mot de passe derrière la biométrie si demandé (unlock réussi).
            if rememberWithBiometric, BiometricAuth.isAvailable {
                E2EEBiometric.store(password: password)
            }
            Haptics.success()
            onUnlock()
            dismiss()
        } catch {
            self.error = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Déverrouillage E2EE via Face ID / Touch ID : lit le mot de passe mémorisé
    /// (déclenche la biométrie) puis exécute le déverrouillage normal.
    private func biometricUnlock() async {
        guard let stored = await E2EEBiometric.retrieve(reason: String(localized: "Déverrouille ta messagerie chiffrée")) else {
            passwordFocused = true
            return
        }
        password = stored
        await unlockOrCreate()
    }
}
