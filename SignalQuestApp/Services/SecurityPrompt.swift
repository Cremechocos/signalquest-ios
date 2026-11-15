import Foundation

/// Carte « Protège ton compte » (contrat 2FA r3.4, §6), calculée par le serveur dans
/// `GET /api/auth/me` (`user.securityPrompt`). Lue comme facultative : un champ absent, mal formé
/// ou une raison inconnue ne casse jamais la lecture du profil, et ne montre rien.
struct SecurityPrompt: Codable, Equatable, Sendable {
    enum Reason: String, Sendable {
        case noTwoFactor = "no_2fa"
        case noBackupCodes = "no_backup_codes"
    }

    var show: Bool
    /// Valeur servie telle quelle ; `knownReason` ne garde que les raisons que l'app sait montrer.
    var reason: String?
    var snoozedUntil: String?

    var knownReason: Reason? { reason.flatMap(Reason.init(rawValue:)) }

    init(show: Bool, reason: String?, snoozedUntil: String? = nil) {
        self.show = show
        self.reason = reason
        self.snoozedUntil = snoozedUntil
    }

    private enum CodingKeys: String, CodingKey { case show, reason, snoozedUntil }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        show = (try? container?.decodeIfPresent(Bool.self, forKey: .show)) ?? false
        reason = (try? container?.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        snoozedUntil = (try? container?.decodeIfPresent(String.self, forKey: .snoozedUntil)) ?? nil
    }
}

/// Réponse de `POST /api/me/security-prompt/snooze`.
struct SecurityPromptSnoozeResponse: Decodable, Sendable {
    let securityPrompt: SecurityPrompt?
}

/// Repères locaux de la carte, par compte et par appareil (§6, règles d'Android du 16/11).
/// - `armed` : un moment est arrivé (envoi chiffré réussi, appareil ajouté au compte, push
///   « Nouvel appareil ») ; la carte s'évalue au prochain retour de la liste Messages.
/// - `shownDay` : jour LOCAL où la carte s'est montrée, au plus une fois par jour.
/// - `snoozePending` : « Plus tard » pas encore reçu par le serveur, posé avant l'envoi.
struct SecurityPromptMoments {
    let userID: String
    private let defaults: UserDefaults

    init(userID: String, defaults: UserDefaults = .standard) {
        self.userID = userID
        self.defaults = defaults
    }

    /// Le compte de la session courante, s'il y en a un.
    static func current() -> SecurityPromptMoments? {
        guard let session = LocalAccountScope.sessionSnapshot() else { return nil }
        return SecurityPromptMoments(ownerScopeId: session.ownerScopeId)
    }

    init?(ownerScopeId: String, defaults: UserDefaults = .standard) {
        guard ownerScopeId.hasPrefix("user:") else { return nil }
        self.init(userID: String(ownerScopeId.dropFirst("user:".count)), defaults: defaults)
    }

    private func key(_ name: String) -> String { "security-prompt-\(name)-v1:\(userID)" }

    var isArmed: Bool { defaults.bool(forKey: key("armed")) }
    func arm() { defaults.set(true, forKey: key("armed")) }
    func disarm() { defaults.removeObject(forKey: key("armed")) }

    var shownDay: String? { defaults.string(forKey: key("shown-day")) }
    func markShown(day: String) { defaults.set(day, forKey: key("shown-day")) }

    var snoozePending: Bool { defaults.bool(forKey: key("snooze-pending")) }
    func setSnoozePending(_ pending: Bool) {
        if pending { defaults.set(true, forKey: key("snooze-pending")) } else { defaults.removeObject(forKey: key("snooze-pending")) }
    }

    /// Jour local `yyyy-MM-dd`, dans le calendrier grégorien quel que soit celui de l'appareil.
    static func localDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// La carte en tête de la liste Messages. Un moment ne la montre pas tout de suite : il l'arme, et
/// elle s'évalue à chaque retour de la liste au premier plan. Une fois montrée, elle reste jusqu'à
/// « Plus tard », jusqu'à son bouton, ou jusqu'à la fin du processus ; quitter l'écran n'est pas
/// « Plus tard ».
@MainActor
final class SecurityPromptCoordinator: ObservableObject {
    struct Card: Equatable {
        let userID: String
        let reason: SecurityPrompt.Reason
    }

    @Published private(set) var card: Card?
    private var isEvaluating = false
    private let now: () -> Date
    private let defaults: UserDefaults

    init(now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard) {
        self.now = now
        self.defaults = defaults
    }

    /// La carte du compte affiché ; jamais celle d'un autre compte.
    func card(for userID: String?) -> Card? {
        guard let card, card.userID == userID else { return nil }
        return card
    }

    /// Retour de la liste Messages au premier plan : « Plus tard » en attente d'abord (tant qu'il
    /// n'est pas parti, aucune carte), puis le moment armé, le plafond du jour, enfin le profil relu.
    func evaluate(
        userID: String,
        readPrompt: () async throws -> SecurityPrompt?,
        snooze: () async throws -> Void
    ) async {
        guard !isEvaluating else { return }
        if let card, card.userID != userID { self.card = nil }
        guard card == nil else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        let moments = SecurityPromptMoments(userID: userID, defaults: defaults)
        if moments.snoozePending {
            await sendSnooze(moments, snooze: snooze)
            guard !moments.snoozePending else { return }
        }
        guard moments.isArmed else { return }
        let today = SecurityPromptMoments.localDay(now())
        // Déjà vue aujourd'hui : le moment tombe, sans lire le profil.
        guard moments.shownDay != today else { return moments.disarm() }
        let prompt: SecurityPrompt?
        do {
            prompt = try await readPrompt()
        } catch {
            // Profil illisible : le moment attend la prochaine évaluation.
            return
        }
        guard moments.isArmed else { return }
        moments.disarm()
        guard let prompt, prompt.show, let reason = prompt.knownReason else { return }
        moments.markShown(day: today)
        card = Card(userID: userID, reason: reason)
    }

    /// « Plus tard » : la carte part tout de suite ; le report de 30 jours est envoyé, et renvoyé à
    /// la prochaine évaluation s'il n'est pas arrivé.
    func later(snooze: () async throws -> Void) async {
        guard let card else { return }
        self.card = nil
        let moments = SecurityPromptMoments(userID: card.userID, defaults: defaults)
        moments.setSnoozePending(true)
        await sendSnooze(moments, snooze: snooze)
    }

    /// Le bouton de la carte ouvre Réglages › Sécurité : la carte s'en va, sans report.
    func dismissForAction() {
        card = nil
    }

    private func sendSnooze(_ moments: SecurityPromptMoments, snooze: () async throws -> Void) async {
        do {
            try await snooze()
            moments.setSnoozePending(false)
        } catch {
            if Self.dropsSnooze(after: error) { moments.setSnoozePending(false) }
        }
    }

    /// Le serveur a répondu non (4xx sauf 429) ou il n'y a plus de session : renvoyer ne servirait à
    /// rien. Réseau, 429 et 5xx : on renverra.
    nonisolated static func dropsSnooze(after error: Error) -> Bool {
        switch error {
        case APIError.missingAuthToken: return true
        case APIError.http(let status, _, _, _, _): return (400..<500).contains(status) && status != 429
        default: return false
        }
    }

    /// Les moments (§6) : un envoi chiffré réussi depuis cet appareil, un appareil ajouté au compte
    /// vu dans le journal, ou le push « Nouvel appareil » reçu.
    nonisolated static func arm(ownerScopeId: String) {
        SecurityPromptMoments(ownerScopeId: ownerScopeId)?.arm()
    }
}

/// `POST /api/me/security-prompt/snooze` : session exigée, corps vide, report de 30 jours pour le
/// compte. Idempotent.
struct SecurityPromptService: Sendable {
    let api: APIClient

    func snooze() async throws {
        _ = try await api.request(APIEndpoint(path: "/api/me/security-prompt/snooze", method: .post),
                                  as: SecurityPromptSnoozeResponse.self)
    }
}
