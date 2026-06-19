import SwiftUI

/// Feuille de choix / changement du @handle (identifiant unique de mention), avec
/// vérification de disponibilité en temps réel et gestion du cooldown 30 j. Réutilisée
/// par le Feed (gate à l'arrivée si aucun handle) et l'édition de profil.
struct ChooseHandleSheet: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    /// Appelé après un enregistrement réussi avec le nouveau handle normalisé
    /// (l'appelant rafraîchit la session et/ou son affichage local).
    var onSuccess: (String) -> Void

    private enum Status { case idle, checking, available, taken, invalid, error, cooldown }

    @State private var input = ""
    @State private var status: Status = .idle
    @State private var message = ""
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var checkTask: Task<Void, Never>?

    private var normalized: String { Self.normalizeHandle(input) }
    private var isNegative: Bool {
        status == .taken || status == .invalid || status == .error || status == .cooldown
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    Text("C’est votre identifiant unique (@pseudo) pour être mentionné dans le fil et la messagerie, et il s’affiche sur votre profil. Modifiable une fois tous les 30 jours.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                        .sqFadeUp()

                    HStack(spacing: SQSpace.sm) {
                        Text("@")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                        TextField("pseudo", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .onChangeCompat(of: input) { _, _ in scheduleCheck() }
                        statusIcon
                    }
                    .padding(SQSpace.md)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(isNegative ? SQColor.danger : SQColor.separator, lineWidth: 1)
                    }
                    .sqFadeUp()

                    Text(message.isEmpty
                        ? "Lettres, chiffres, « . », « _ » et « - ». 2 à 32 caractères."
                        : (normalized.isEmpty ? message : "@\(normalized) · \(message)"))
                        .font(SQType.caption)
                        .foregroundStyle(messageColor)

                    if let errorText {
                        Text(errorText)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }

                    GradientButton("Continuer", systemImage: "checkmark.circle.fill", isBusy: isBusy) {
                        Task { await submit() }
                    }
                    .disabled(status != .available || isBusy)
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Nom d’utilisateur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Plus tard") { dismiss() }.tint(SQColor.labelSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .checking:
            ProgressView()
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .taken, .invalid, .error, .cooldown:
            Image(systemName: "xmark.circle.fill").foregroundStyle(SQColor.danger)
        case .idle:
            EmptyView()
        }
    }

    private var messageColor: Color {
        if status == .available { return Color.green }
        if isNegative { return SQColor.danger }
        return SQColor.labelSecondary
    }

    private func scheduleCheck() {
        checkTask?.cancel()
        errorText = nil
        let candidate = normalized
        if candidate.isEmpty {
            status = .idle; message = ""
            return
        }
        if candidate.count < 2 {
            status = .invalid; message = "Minimum 2 caractères."
            return
        }
        let raw = input
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run { status = .checking; message = "Vérification de la disponibilité…" }
            do {
                let a = try await services.users.checkHandleAvailability(raw)
                if Task.isCancelled { return }
                await MainActor.run {
                    if a.code == "HANDLE_COOLDOWN" || (a.cooldownActive ?? false) {
                        status = .cooldown
                        message = Self.cooldownMessage(a.remainingDays ?? 0)
                    } else if a.available {
                        status = .available; message = "Disponible."
                    } else {
                        status = .taken; message = "Déjà pris par un autre membre."
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { status = .error; message = "Impossible de vérifier pour le moment." }
            }
        }
    }

    private func submit() async {
        guard status == .available, !isBusy else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }
        do {
            _ = try await services.users.updateProfile(UserProfilePatch(
                name: nil, handle: normalized, bio: nil, avatarUrl: nil
            ))
            Haptics.success()
            onSuccess(normalized)
            dismiss()
        } catch let APIError.http(_, code, serverMessage, _, _) {
            let msg = serverMessage ?? "Échec de l’enregistrement."
            switch code {
            case "HANDLE_COOLDOWN": status = .cooldown; message = msg
            case "HANDLE_ALREADY_USED": status = .taken; message = msg
            default: errorText = msg
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func cooldownMessage(_ days: Int) -> String {
        days <= 1
            ? "Vous pourrez changer de nom d’utilisateur dans 1 jour."
            : "Vous pourrez changer de nom d’utilisateur dans \(days) jours."
    }

    /// Normalisation client (aperçu + longueur min) alignée sur le backend :
    /// minuscule, sans accent, charset `[a-z0-9_.-]`, bords nettoyés, 32 max.
    static func normalizeHandle(_ value: String) -> String {
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
        var result = ""
        var lastDash = false
        for ch in folded {
            if ch == "@" && result.isEmpty { continue }
            if (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "_" || ch == "." || ch == "-" {
                result.append(ch); lastDash = false
            } else if !lastDash {
                result.append("-"); lastDash = true
            }
        }
        while let f = result.first, f == "-" || f == "." || f == "_" { result.removeFirst() }
        while let l = result.last, l == "-" || l == "." || l == "_" { result.removeLast() }
        return String(result.prefix(32))
    }
}
