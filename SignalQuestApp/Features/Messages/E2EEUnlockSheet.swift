import SwiftUI

/// Déverrouillage (ou première création) de la clé E2EE. Si le compte n'a pas
/// encore de clé côté serveur, le même mot de passe sert à en générer une —
/// parité avec le flux Android `createBootstrap`.
struct E2EEUnlockSheet: View {
    let userId: String
    let service: E2EEServicing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?
    @State private var needsCreation = false
    /// Apparition douce du badge cadenas (scale 0.9 → 1, SQMotion.emphasized).
    @State private var badgeAppeared = false
    var onUnlock: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                    SQSheetHandle()
                    VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                        ZStack {
                            Circle()
                                .fill(SQGradient.signal)
                                .frame(width: 72, height: 72)
                                .shadow(color: SQColor.brandPink.opacity(0.45), radius: 18, y: 6)
                            Image(systemName: needsCreation ? "lock.badge.clock" : "lock.shield")
                                .font(.title2.weight(.semibold))
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
                        Text(needsCreation ? "Créer ta clé" : "Déverrouiller")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                        Text(needsCreation
                             ? "Aucune clé E2EE n'existe encore pour ce compte. Choisis un mot de passe : il chiffre ta clé privée, et lui seul peut la déverrouiller — ne le perds pas."
                             : "Ton mot de passe SignalQuest déverrouille la clé en mémoire.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                        SecureField(needsCreation ? "Nouveau mot de passe E2EE" : "Mot de passe", text: $password)
                            .textContentType(needsCreation ? .newPassword : .password)
                            .textFieldStyle(SQTextFieldStyle())
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.danger)
                        }
                        GradientButton(
                            needsCreation ? "Créer et activer" : "Déverrouiller",
                            systemImage: "key.fill",
                            isBusy: isBusy
                        ) {
                            Task { await unlockOrCreate() }
                        }
                        .disabled(password.count < (needsCreation ? 6 : 1))
                    }
                }
                .padding(SQSpace.lg + 2)
            }
            .signalQuestBackground()
            .navigationTitle("Chiffrement E2EE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandOrange)
                }
            }
            .task { await checkExistingKey() }
        }
        .presentationDetents([.medium])
    }

    private func checkExistingKey() async {
        if let bootstrap = try? await service.bootstrap() {
            needsCreation = !bootstrap.hasKey || bootstrap.key == nil
        }
    }

    private func unlockOrCreate() async {
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
