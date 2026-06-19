import SwiftUI

/// Déverrouillage (ou première création) de la clé E2EE. Si le compte n'a pas
/// encore de clé côté serveur, le même mot de passe sert à en générer une —
/// parité avec le flux Android `createBootstrap`.
struct E2EEUnlockSheet: View {
    let userId: String
    let service: E2EEServicing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var passwordFocused: Bool
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?
    @State private var needsCreation = false
    /// Apparition douce du badge cadenas (scale 0.9 → 1, SQMotion.emphasized).
    @State private var badgeAppeared = false
    var onUnlock: () -> Void

    private var canSubmit: Bool { password.count >= (needsCreation ? 6 : 1) && !isBusy }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.lg) {
                    badge
                        .padding(.top, SQSpace.md)

                    VStack(spacing: SQSpace.xs + 2) {
                        Text(needsCreation ? "Créer ta clé" : "Déverrouiller")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                            .multilineTextAlignment(.center)
                        Text(needsCreation
                             ? "Aucune clé E2EE n'existe encore pour ce compte. Choisis un mot de passe : il chiffre ta clé privée et lui seul peut la déverrouiller — ne le perds pas."
                             : "Ton mot de passe SignalQuest déverrouille la clé de chiffrement en mémoire, le temps de la session.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        SecureField(needsCreation ? "Nouveau mot de passe E2EE" : "Mot de passe", text: $password)
                            .textContentType(needsCreation ? .newPassword : .password)
                            .textFieldStyle(SQTextFieldStyle())
                            .focused($passwordFocused)
                            .submitLabel(needsCreation ? .done : .go)
                            .onSubmit { if canSubmit { Task { await unlockOrCreate() } } }

                        if needsCreation {
                            Label("6 caractères minimum. Ce mot de passe ne quitte jamais ton appareil.", systemImage: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(SQColor.labelTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(SQSpace.lg + 2)
            }
            .scrollDismissesKeyboard(.interactively)
            .signalQuestBackground()
            .navigationTitle("Chiffrement E2EE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandOrange)
                }
            }
            // Bouton d'action ÉPINGLÉ : reste visible au-dessus du clavier (le détent
            // medium + clavier masquait l'action quand elle était dans le scroll).
            .safeAreaInset(edge: .bottom) {
                GradientButton(
                    needsCreation ? "Créer et activer" : "Déverrouiller",
                    systemImage: "key.fill",
                    isBusy: isBusy
                ) {
                    Task { await unlockOrCreate() }
                }
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.5)
                .padding(.horizontal, SQSpace.lg + 2)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQSpace.md)
                .background(.ultraThinMaterial)
            }
            .task {
                await checkExistingKey()
                passwordFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sqAnimation(.snappy(duration: 0.25), value: error)
        .sqAnimation(.snappy(duration: 0.25), value: needsCreation)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(SQGradient.signal)
                .frame(width: 76, height: 76)
                .shadow(color: SQColor.brandPink.opacity(0.45), radius: 18, y: 6)
            Image(systemName: needsCreation ? "lock.badge.clock" : "lock.shield")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
        }
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
            needsCreation = !bootstrap.hasKey || bootstrap.key == nil
        }
    }

    private func unlockOrCreate() async {
        passwordFocused = false
        isBusy = true
        defer { isBusy = false }
        do {
            let bootstrap = try await service.bootstrap()
            if let key = bootstrap.key, bootstrap.hasKey {
                try await service.unlock(userId: userId, password: password, bootstrapKey: key)
            } else {
                try await service.generateAndRegisterKey(userId: userId, password: password)
            }
            Haptics.success()
            onUnlock()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
