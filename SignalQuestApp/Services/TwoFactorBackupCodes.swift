import Foundation

/// Codes de secours de la double authentification (contrat 2FA r3.3). Un code vaut le code de
/// l'application partout où la 2FA est demandée ; le serveur normalise ce qui est tapé (casse,
/// espaces, tirets, Crockford) : l'app l'envoie tel quel.
enum TwoFactorBackupCodes {
    static let length = 10
    /// Longueur de saisie : un code tapé avec ses tirets et quelques espaces garde ses 10
    /// caractères utiles.
    static let inputMax = 24

    /// §1 : « Valider » s'active dès que 10 caractères restent, espaces et tirets retirés.
    static func isInputReady(_ input: String) -> Bool {
        input.count <= inputMax && input.filter { $0 != " " && $0 != "-" }.count >= length
    }

    /// Le compteur. Zéro a son propre texte, avant la règle de pluriel (§8).
    static func remainingText(_ remaining: Int) -> String {
        remaining == 0 ? String(localized: "Aucun code de secours restant")
            : String(localized: "\(remaining) codes de secours restants")
    }

    /// « Générés le 15 nov. 2026 » ; `nil` sans date lisible.
    static func generatedOnText(_ generatedAt: String?) -> String? {
        guard let generatedAt, let date = parseDate(generatedAt) else { return nil }
        // Espaces insécables : la date ne se coupe pas en fin de ligne.
        let day = date.formatted(date: .abbreviated, time: .omitted).replacingOccurrences(of: " ", with: "\u{00A0}")
        return String(localized: "Générés le \(day)")
    }

    /// Ligne d'état de la rubrique Sécurité : l'invitation à refaire les codes pour un lot montré ici
    /// sans « J'ai noté mes codes » (règle A), sinon le compteur et la date du lot.
    static func stateText(status: TwoFactorBackupCodeStatus?, unconfirmed: Bool) -> String? {
        if unconfirmed {
            return String(localized: "Tu n’as pas confirmé avoir noté tes codes de secours. Génère-en de nouveaux pour les noter.")
        }
        guard let status else { return nil }
        let count = remainingText(status.remaining)
        guard let generatedOn = generatedOnText(status.generatedAt) else { return count }
        return "\(count) · \(generatedOn)"
    }

    /// ISO 8601 du serveur, avec ou sans millisecondes.
    static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Crée un lot sur cet appareil (activation ou régénération) en tenant le repère de la règle A.
    /// Il est posé AVANT l'envoi : une réponse perdue (réseau, app tuée) laisse une 2FA active dont
    /// les codes n'ont jamais été vus, et la rubrique Sécurité proposera de les refaire. Un refus du
    /// serveur n'a rien créé : le repère d'avant revient. Tant que `generatedAt` n'est pas servi dans
    /// la réponse, il est relu juste après.
    static func createTracked(
        previous: String?,
        markers: TwoFactorBackupCodesMarkerStore,
        create: @Sendable () async throws -> TwoFactorBackupCodeBatch?,
        readStatus: @Sendable () async throws -> TwoFactorBackupCodeStatus
    ) async throws -> TwoFactorBackupCodeBatch? {
        let before = markers.load()
        let pending = TwoFactorBackupCodesMarker.unknown(previous: previous)
        markers.save(pending)
        let batch: TwoFactorBackupCodeBatch?
        do {
            batch = try await create()
        } catch {
            if isRejection(error) { markers.save(before) }
            throw error
        }
        var generatedAt = batch?.generatedAt
        if generatedAt == nil, let status = try? await readStatus(),
           case .batch(let read)? = TwoFactorBackupCodesMarker.reconcile(pending, with: status) {
            generatedAt = read
        }
        markers.save(generatedAt.map { .batch(generatedAt: $0) } ?? pending)
        return batch
    }

    /// Le serveur a répondu non (code faux, configuration expirée, budget épuisé…) : rien n'a été
    /// créé, à la différence d'une réponse perdue ou d'une erreur du serveur.
    static func isRejection(_ error: Error) -> Bool {
        if let failure = error as? TwoFactorEnrollmentError {
            return [.invalidCode, .invalidBackupCode, .expiredSetup, .replacedSetup, .alreadyEnabled].contains(failure)
        }
        if case APIError.http(let status, _, _, _, _) = error { return (400..<500).contains(status) }
        return false
    }
}

/// Repère local « codes non confirmés » (§4, règle A). Il vise le LOT montré sur cet appareil,
/// jamais la 2FA du compte : une activation ou une régénération faite ailleurs ne pousse jamais à
/// régénérer des codes bien notés.
enum TwoFactorBackupCodesMarker: Equatable, Sendable {
    /// Création lancée ici, lot pas encore identifié : réponse perdue, ou `generatedAt` ni servi ni
    /// encore relu. `previous` : le lot qu'elle remplace, qu'une relecture ne prend jamais pour le
    /// nouveau.
    case unknown(previous: String?)
    /// Lot montré ici sans « J'ai noté mes codes ».
    case batch(generatedAt: String)

    /// Le repère après une relecture RÉUSSIE de l'état. Il tombe quand le lot servi n'est plus celui
    /// montré (refait ailleurs) ou que la 2FA est inactive (`generatedAt` nul) ; une création sans
    /// lot identifié adopte le lot servi s'il est nouveau. Une relecture qui échoue ne passe pas
    /// ici : le repère attend la suivante.
    static func reconcile(_ marker: Self?, with status: TwoFactorBackupCodeStatus) -> Self? {
        switch marker {
        case nil:
            return nil
        case .unknown(let previous):
            guard let generatedAt = status.generatedAt, generatedAt != previous else { return nil }
            return .batch(generatedAt: generatedAt)
        case .batch(let generatedAt):
            return status.generatedAt == generatedAt ? marker : nil
        }
    }
}

/// Repère de la règle A, propre au compte et à l'appareil.
struct TwoFactorBackupCodesMarkerStore: Sendable {
    var load: @Sendable () -> TwoFactorBackupCodesMarker?
    var save: @Sendable (TwoFactorBackupCodesMarker?) -> Void

    static func storageKey(userID: String) -> String { "two-factor-backup-codes-marker-v1:\(userID)" }

    static func live(userID: String) -> TwoFactorBackupCodesMarkerStore {
        let key = storageKey(userID: userID)
        return TwoFactorBackupCodesMarkerStore(
            load: {
                guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
                if raw.hasPrefix("unknown:") {
                    let previous = String(raw.dropFirst("unknown:".count))
                    return .unknown(previous: previous.isEmpty ? nil : previous)
                }
                if raw.hasPrefix("batch:") {
                    let generatedAt = String(raw.dropFirst("batch:".count))
                    return generatedAt.isEmpty ? nil : .batch(generatedAt: generatedAt)
                }
                return nil
            },
            save: { marker in
                switch marker {
                case nil: UserDefaults.standard.removeObject(forKey: key)
                case .unknown(let previous)?: UserDefaults.standard.set("unknown:" + (previous ?? ""), forKey: key)
                case .batch(let generatedAt)?: UserDefaults.standard.set("batch:" + generatedAt, forKey: key)
                }
            }
        )
    }
}
