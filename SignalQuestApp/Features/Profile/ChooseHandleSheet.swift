import SwiftUI

/// Feuille de choix ou de changement du nom d'utilisateur (identité membre v1), ouverte depuis
/// le profil et son édition : saisie sans « @ », vérifiée sur la route du profil, qui répond
/// aussi le délai de 30 jours entre deux changements.
struct ChooseHandleSheet: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss

    /// Appelé après un enregistrement réussi avec le nouveau nom d'utilisateur normalisé
    /// (la session a déjà repris le profil renvoyé).
    var onSuccess: (String) -> Void

    @StateObject private var username = UsernameAvailabilityModel()
    @State private var errorText: String?
    @State private var isBusy = false
    @FocusState private var focused: Bool

    private var user: AuthUser? {
        if case .authenticated(let user) = session.state { return user }
        return nil
    }

    private var current: String? {
        guard let handle = user?.handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else { return nil }
        return handle
    }

    /// Aperçu du lien public : le nom saisi s'il est valide, sinon le nom actuel.
    private var previewHandle: String {
        if UserHandle.isValid(normalized: username.normalized) { return username.normalized }
        return current ?? String(localized: "ton-nom")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    Text("Unique et public : c’est par lui qu’on te trouve et qu’on te mentionne. Ton profil : \(UserHandle.profileLink(previewHandle))")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    AuthFieldGroup {
                        AuthFieldRow(current == nil ? "Nom d’utilisateur" : "Nouveau nom d’utilisateur",
                                     isFocused: focused, isError: username.isNegative) {
                            UsernameTextField(text: $username.input, identifier: "profile.handle.field")
                                .submitLabel(.done)
                                .focused($focused)
                                .onSubmit { Task { await submit() } }
                        } onTap: { focused = true }
                        UsernameStatusLine(model: username)
                            .padding(.horizontal, SQSpace.md2)
                            .padding(.bottom, SQSpace.sm2)
                    }

                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        if let current {
                            Text("L’ancien lien \(UserHandle.profileLink(current)) mènera toujours à ton profil.")
                        }
                        Text(user?.needsHandleConfirmation == true && current != nil
                             ? String(localized: "Le changer est gratuit cette fois-ci. Ensuite, il faudra attendre 30 jours entre deux changements.")
                             : String(localized: "Tu pourras le changer ensuite, avec 30 jours d’attente entre deux changements."))
                    }
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let errorText {
                        SQNotice(message: errorText, systemImage: "exclamationmark.triangle", tone: .danger)
                            .sqAnnounce(errorText)
                    }

                    GradientButton("Enregistrer", systemImage: "checkmark.circle.fill", isBusy: isBusy) {
                        Task { await submit() }
                    }
                    .disabled(!username.canSubmit || isBusy)
                    .accessibilityIdentifier("profile.handle.save")
                }
                .padding(SQSpace.lg)
                .sqReadableWidth(560)
            }
            .scrollDismissesKeyboard(.interactively)
            .signalQuestBackground()
            .navigationTitle("Nom d’utilisateur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }.tint(SQColor.labelSecondary)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            username.current = current
            username.check = { [users = services.users] in try await users.checkHandleAvailability($0) }
            focused = true
        }
    }

    private func submit() async {
        guard username.canSubmit, !isBusy else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }
        let handle = username.normalized
        do {
            let updated = try await services.users.updateProfile(UserProfilePatch(
                name: nil, handle: handle, bio: nil, avatarUrl: nil
            ))
            session.applyProfileIdentity(updated)
            Haptics.success()
            onSuccess(handle)
            dismiss()
        } catch let APIError.http(_, code, _, _, _) where code == "HANDLE_ALREADY_USED" || code == "HANDLE_INVALID" {
            username.reject(code: code)
        } catch {
            Haptics.error()
            errorText = error.userFacingMessage
        }
    }
}
