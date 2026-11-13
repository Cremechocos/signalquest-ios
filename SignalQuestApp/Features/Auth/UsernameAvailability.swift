import SwiftUI

/// Champ « Nom d'utilisateur » (identité membre v1) : la saisie est normalisée comme le fait le
/// serveur, puis vérifiée 350 ms après la dernière frappe. Partagé par l'inscription, l'étape
/// Apple, l'écran « Ton nom d'utilisateur » et la feuille de changement.
@MainActor
final class UsernameAvailabilityModel: ObservableObject {
    enum Status: Equatable {
        case idle, checking, available, taken, invalid, unchanged, error
        case cooldown(days: Int)
    }

    @Published var input = "" { didSet { if input != oldValue { scheduleCheck() } } }
    @Published private(set) var status: Status = .idle

    /// Nom d'utilisateur actuel du membre connecté : le ressaisir n'est pas un changement.
    var current: String?
    /// La route de vérification : publique sans compte, celle du profil une fois connecté.
    /// Posée par l'écran à son apparition, avant toute saisie.
    var check: (@Sendable (String) async throws -> HandleAvailability)?
    private var task: Task<Void, Never>?

    init(current: String? = nil, check: (@Sendable (String) async throws -> HandleAvailability)? = nil) {
        self.current = current
        self.check = check
    }

    var normalized: String { UserHandle.normalize(input) }
    var canSubmit: Bool { status == .available }

    /// Refus du serveur à l'enregistrement (course entre deux inscriptions, nom invalide).
    func reject(code: String?) {
        task?.cancel()
        status = code == "HANDLE_ALREADY_USED" ? .taken : .invalid
    }

    private func scheduleCheck() {
        task?.cancel()
        let candidate = normalized
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .idle; return }
        guard UserHandle.isValid(normalized: candidate) else { status = .invalid; return }
        if let current, candidate == current { status = .unchanged; return }
        guard let check else { status = .error; return }
        status = .checking
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let result: Status
            do {
                let answer = try await check(candidate)
                if answer.code == "HANDLE_COOLDOWN" || answer.cooldownActive == true {
                    result = .cooldown(days: answer.remainingDays ?? 0)
                } else if answer.available {
                    result = .available
                } else if answer.code == "HANDLE_ALREADY_USED" || answer.code == nil {
                    result = .taken
                } else {
                    result = .invalid
                }
            } catch {
                result = .error
            }
            guard !Task.isCancelled, let self, self.normalized == candidate else { return }
            self.status = result
        }
    }

    /// Texte de l'état, ou `nil` quand il n'y a rien à dire.
    var statusText: String? {
        switch status {
        case .idle: return nil
        case .checking: return String(localized: "Vérification de la disponibilité…")
        case .available:
            // Le serveur transforme au lieu de refuser : on montre ce qui sera enregistré.
            return normalized == input
                ? String(localized: "Disponible")
                : String(localized: "Disponible, enregistré comme \(normalized)")
        case .taken: return String(localized: "Déjà pris : choisis-en un autre.")
        case .invalid: return String(localized: "2 caractères minimum (lettres, chiffres, « . », « _ » ou « - »).")
        case .unchanged: return String(localized: "C’est déjà ton nom d’utilisateur.")
        case .error: return String(localized: "Impossible de vérifier pour le moment.")
        case .cooldown(let days):
            return days <= 1
                ? String(localized: "Tu pourras changer de nom d’utilisateur dans 1 jour.")
                : String(localized: "Tu pourras changer de nom d’utilisateur dans \(days) jours.")
        }
    }

    var isNegative: Bool {
        switch status {
        case .taken, .invalid, .error, .cooldown: return true
        default: return false
        }
    }
}

/// Ligne d'état sous le champ, annoncée par VoiceOver quand elle change.
struct UsernameStatusLine: View {
    @ObservedObject var model: UsernameAvailabilityModel

    var body: some View {
        if let text = model.statusText {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                if model.status == .checking {
                    SQSpinner().accessibilityHidden(true)
                } else {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(SQType.caption(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("username.status")
            .task(id: text) {
                guard model.status != .checking else { return }
                UIAccessibility.post(notification: .announcement, argument: text)
            }
        }
    }

    private var symbol: String {
        switch model.status {
        case .available: return "checkmark"
        case .taken: return "xmark"
        case .unchanged: return "info.circle"
        default: return "exclamationmark.circle"
        }
    }

    private var color: Color {
        if model.status == .available { return SQColor.success }
        if model.isNegative { return SQColor.dangerInk }
        return SQColor.labelSecondary
    }
}

/// Saisie du nom d'utilisateur, sans « @ » : la forme du clavier et du remplissage automatique.
struct UsernameTextField: View {
    @Binding var text: String
    var identifier: String
    /// À l'inscription, l'e-mail garde le rôle d'identifiant pour le trousseau.
    var contentType: UITextContentType? = .username

    var body: some View {
        TextField("Nom d’utilisateur", text: $text, prompt: SQFormPrompt.text("Ex. alex38"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(contentType)
            .keyboardType(.asciiCapable)
            .accessibilityLabel("Nom d’utilisateur")
            .accessibilityIdentifier(identifier)
    }
}
