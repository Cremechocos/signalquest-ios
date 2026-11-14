import SwiftUI

/// Déverrouillage de la clé de l'ancien chiffrement (v1), pour lire les
/// anciens messages et les importer (E2EE-AUTO §8). Aucune clé v1 ne se crée
/// ni ne se remplace : le chiffrement automatique n'en écrit plus.
struct E2EEUnlockSheet: View {
    let userId: String
    let service: E2EEServicing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var passwordFocused: Bool
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?
    /// Le compte n'a pas de clé v1 : il n'y a rien à ouvrir ici.
    @State private var hasNoKey = false
    /// Proposer de mémoriser le mot de passe E2EE derrière Face ID / Touch ID.
    @State private var rememberWithBiometric = false
    @State private var revealsPassword = false
    @State private var didAttemptBiometric = false
    /// Apparition douce du badge cadenas (scale 0.9 → 1, SQMotion.emphasized).
    @State private var badgeAppeared = false
    /// Import des anciens messages (E2EE-AUTO §8) : la clé v1 s'ouvre une
    /// dernière fois, et rien n'est mémorisé.
    var importsHistory = false
    var onUnlock: () -> Void

    private var canSubmit: Bool { !isBusy && !hasNoKey && !password.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: "e2ee.key.cancel") { dismiss() }

                VStack(spacing: SQSpace.sm) {
                    badge
                    Text(importsHistory ? "Importer l’ancien historique" : "Déverrouiller")
                        .font(SQFont.display(26, .bold, relativeTo: .title))
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    // Deux mots de passe distincts : celui du compte et celui du
                    // chiffrement. Le texte le dit, pour qu'on ne les confonde pas.
                    Text(hasNoKey
                         ? "Ton compte n’a pas de clé de l’ancien chiffrement : ces anciens messages ne peuvent pas s’ouvrir ici. Ils apparaîtront dès qu’un autre membre les aura importés."
                         : importsHistory
                         ? "Ton mot de passe de chiffrement, différent de celui de ton compte, ouvre une dernière fois tes anciens messages chiffrés pour les passer au nouveau chiffrement. Il ne sera plus demandé."
                         : "Ton mot de passe de chiffrement, choisi à la création de ta clé et différent de celui de ton compte, ouvre tes conversations chiffrées le temps de la session.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)

                if !hasNoKey {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        passwordField

                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }
                    }
                }

                // Proposer la mémorisation biométrique (1re fois, pas à l'import).
                if !hasNoKey, !importsHistory, BiometricAuth.isAvailable, !E2EEBiometric.isEnabled {
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

                if !hasNoKey {
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
                if !hasNoKey {
                    GradientButton(
                        importsHistory ? "Importer" : "Déverrouiller",
                        systemImage: "key.fill",
                        isBusy: isBusy
                    ) {
                        Task { await unlock() }
                    }
                    .disabled(!canSubmit)
                }

                // Déverrouillage biométrique direct (déjà mémorisé).
                if !hasNoKey, E2EEBiometric.isEnabled, E2EEBiometric.hasStored {
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
            if !hasNoKey, E2EEBiometric.isEnabled, E2EEBiometric.hasStored, !didAttemptBiometric {
                didAttemptBiometric = true
                await biometricUnlock()
            } else if !hasNoKey {
                passwordFocused = true
            }
        }
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sqAnimation(.snappy(duration: 0.25), value: error)
        .sqAnimation(.snappy(duration: 0.25), value: hasNoKey)
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
                    TextField("Mot de passe de chiffrement", text: $password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("Mot de passe de chiffrement", text: $password)
                }
            }
            .font(SQType.body)
            .foregroundStyle(SQColor.label)
            .focused($passwordFocused)
            .submitLabel(.go)
            .onSubmit { if canSubmit { Task { await unlock() } } }
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
        Image(systemName: "lock.shield")
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

    private func checkExistingKey() async {
        if let bootstrap = try? await service.bootstrap() {
            // Sans clé v1, il n'y a rien à ouvrir : aucune clé ne se crée ici.
            let noKey = !bootstrap.hasKey || bootstrap.key == nil
            if importsHistory, noKey { dismiss() }
            hasNoKey = noKey
        }
    }

    private func unlock() async {
        passwordFocused = false
        isBusy = true
        defer { isBusy = false }
        do {
            let bootstrap = try await service.bootstrap()
            guard let key = bootstrap.key, bootstrap.hasKey else {
                if importsHistory { dismiss() } else { hasNoKey = true }
                return
            }
            try await service.unlock(userId: userId, password: password, bootstrapKey: key)
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
        await unlock()
    }
}
