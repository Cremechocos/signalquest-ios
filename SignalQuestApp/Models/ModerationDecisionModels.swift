import Foundation

/// Décision de modération qui vise le compte connecté (contrat MOD-1,
/// `contracts/moderation-decisions-v1.json` du serveur, révision 1.2).
///
/// POURQUOI. Le DSA impose d'expliquer chaque décision à la personne visée (motif,
/// règle, part d'automatisation : art. 17) et de lui ouvrir un recours pendant
/// 6 mois (art. 20). Le serveur écrit une décision par action d'un modérateur, et
/// depuis G7 (#1482) par masquage automatique après signalements.
///
/// Décodage tolérant : `action`, `target.type` et `appeal.status` restent des
/// chaînes brutes. Une valeur que l'app ne connaît pas encore (un futur état du
/// contrat) s'affiche sous un libellé générique au lieu de faire tomber la liste.
struct ModerationDecision: Decodable, Identifiable, Equatable, Sendable {
    struct Target: Decodable, Equatable, Sendable {
        let type: String
        let id: String
        let createdAt: Date?
        /// Extrait de 140 caractères au plus ; absent pour un contenu chiffré.
        let excerpt: String?
        /// Chemin de la miniature, servie au seul auteur avec sa session.
        let thumbnailPath: String?

        enum CodingKeys: String, CodingKey { case type, id, createdAt, excerpt, thumbnailUrl }

        init(type: String, id: String, createdAt: Date? = nil, excerpt: String? = nil, thumbnailPath: String? = nil) {
            self.type = type
            self.id = id
            self.createdAt = createdAt
            self.excerpt = excerpt
            self.thumbnailPath = thumbnailPath
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.decodeFlexibleString(forKey: .type) ?? ""
            id = c.decodeFlexibleString(forKey: .id) ?? ""
            createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
            excerpt = c.decodeFlexibleString(forKey: .excerpt)
            // Seul le chemin de cette route est suivi : jamais une adresse servie au hasard.
            thumbnailPath = c.decodeFlexibleString(forKey: .thumbnailUrl).flatMap(ModerationDecision.thumbnailPath(_:))
        }
    }

    struct AccountRestriction: Decodable, Equatable, Sendable {
        /// `suspended` ou `photo_upload_banned`.
        let type: String
        let until: Date?

        enum CodingKeys: String, CodingKey { case type, until }

        init(type: String, until: Date?) {
            self.type = type
            self.until = until
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.decodeFlexibleString(forKey: .type) ?? ""
            until = try? c.decodeIfPresent(Date.self, forKey: .until)
        }
    }

    struct Reason: Decodable, Equatable, Sendable {
        let code: String
        /// Libellé du motif, traduit par le serveur dans la langue demandée.
        let label: String?
        /// Précision libre du modérateur, montrée telle quelle (jamais traduite).
        let text: String?

        enum CodingKeys: String, CodingKey { case code, label, text }

        init(code: String, label: String?, text: String? = nil) {
            self.code = code
            self.label = label
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = c.decodeFlexibleString(forKey: .code) ?? "other"
            label = c.decodeFlexibleString(forKey: .label)
            text = c.decodeFlexibleString(forKey: .text)
        }
    }

    /// Règle de la communauté citée, dans la version en vigueur au moment de la décision.
    struct Rule: Decodable, Equatable, Sendable {
        let id: String
        let version: String
        let title: String
    }

    struct Appeal: Decodable, Equatable, Sendable {
        /// Vrai tant qu'aucun recours n'est déposé et que le délai court : le serveur décide.
        let possible: Bool
        let deadline: Date?
        /// `none`, `pending`, `accepted`, `rejected` (contrat v1), ou une valeur plus récente.
        let status: String
        let filedAt: Date?
        let decidedAt: Date?
        /// « Recours accepté : la décision est annulée », traduit par le serveur.
        let outcomeLabel: String?
        /// Précision de la personne qui a réexaminé, montrée telle quelle.
        let outcomeText: String?

        enum CodingKeys: String, CodingKey { case possible, deadline, status, filedAt, decidedAt, outcomeLabel, outcomeText }

        init(possible: Bool, deadline: Date?, status: String, filedAt: Date? = nil, decidedAt: Date? = nil,
             outcomeLabel: String? = nil, outcomeText: String? = nil) {
            self.possible = possible
            self.deadline = deadline
            self.status = status
            self.filedAt = filedAt
            self.decidedAt = decidedAt
            self.outcomeLabel = outcomeLabel
            self.outcomeText = outcomeText
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            possible = (try? c.decodeIfPresent(Bool.self, forKey: .possible)) ?? false
            deadline = try? c.decodeIfPresent(Date.self, forKey: .deadline)
            status = c.decodeFlexibleString(forKey: .status) ?? "none"
            filedAt = try? c.decodeIfPresent(Date.self, forKey: .filedAt)
            decidedAt = try? c.decodeIfPresent(Date.self, forKey: .decidedAt)
            outcomeLabel = c.decodeFlexibleString(forKey: .outcomeLabel)
            outcomeText = c.decodeFlexibleString(forKey: .outcomeText)
        }

        static let closed = Appeal(possible: false, deadline: nil, status: "none")
    }

    let id: String
    let decidedAt: Date?
    let target: Target
    /// `removed`, `hidden`, `rejected`, `warning`, `account_suspended`,
    /// `photo_upload_banned`, `none`, ou une valeur plus récente.
    let action: String
    let accountRestriction: AccountRestriction?
    let until: Date?
    let reason: Reason
    let rule: Rule?
    /// Décision prise sans regard humain (masquage par signalements, filtre).
    let automated: Bool
    let appeal: Appeal

    enum CodingKeys: String, CodingKey {
        case id, decidedAt, target, action, accountRestriction, until, reason, rule, automated, appeal
    }

    init(id: String, decidedAt: Date?, target: Target, action: String, accountRestriction: AccountRestriction? = nil,
         until: Date? = nil, reason: Reason, rule: Rule? = nil, automated: Bool, appeal: Appeal) {
        self.id = id
        self.decidedAt = decidedAt
        self.target = target
        self.action = action
        self.accountRestriction = accountRestriction
        self.until = until
        self.reason = reason
        self.rule = rule
        self.automated = automated
        self.appeal = appeal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.decodeFlexibleString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "id"))
        }
        self.id = id
        decidedAt = try? c.decodeIfPresent(Date.self, forKey: .decidedAt)
        target = (try? c.decodeIfPresent(Target.self, forKey: .target)) ?? Target(type: "", id: "")
        action = c.decodeFlexibleString(forKey: .action) ?? ""
        accountRestriction = try? c.decodeIfPresent(AccountRestriction.self, forKey: .accountRestriction)
        until = try? c.decodeIfPresent(Date.self, forKey: .until)
        reason = (try? c.decodeIfPresent(Reason.self, forKey: .reason)) ?? Reason(code: "other", label: nil)
        rule = try? c.decodeIfPresent(Rule.self, forKey: .rule)
        automated = (try? c.decodeIfPresent(Bool.self, forKey: .automated)) ?? false
        // Sans bloc de recours lisible, on ne propose pas de recours : le serveur refuserait.
        appeal = (try? c.decodeIfPresent(Appeal.self, forKey: .appeal)) ?? .closed
    }

    /// Préfixe des miniatures servies par MOD-1.
    static let thumbnailPrefix = "/api/me/moderation/decisions/"

    /// Le chemin d'une miniature MOD-1, ou `nil` pour toute autre adresse.
    static func thumbnailPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "/thumbnail"
        guard trimmed.hasPrefix(thumbnailPrefix), trimmed.hasSuffix(suffix),
              trimmed.count > thumbnailPrefix.count + suffix.count else { return nil }
        // Entre les deux, un identifiant du serveur et rien d'autre (ni `/`, ni `..`, ni `?`).
        let id = trimmed.dropFirst(thumbnailPrefix.count).dropLast(suffix.count)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard id.count <= 64, id.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return trimmed
    }
}

/// Une page de `/api/me/moderation/decisions`.
struct ModerationDecisionsPage: Decodable, Equatable, Sendable {
    let decisions: [ModerationDecision]
    let nextCursor: String?
    /// Décisions jamais vues. Le serveur marque vues une décision et toutes les plus
    /// anciennes : les non vues sont donc toujours les plus récentes, en tête de liste.
    let unseenCount: Int

    enum CodingKeys: String, CodingKey { case decisions, nextCursor, unseenCount }

    init(decisions: [ModerationDecision], nextCursor: String?, unseenCount: Int) {
        self.decisions = decisions
        self.nextCursor = nextCursor
        self.unseenCount = unseenCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decisions = c.decodeLossyArray([ModerationDecision].self, forKey: .decisions)
        nextCursor = c.decodeFlexibleString(forKey: .nextCursor)
        unseenCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .unseenCount)) ?? 0)
    }
}

/// Règles de la communauté citées par les décisions (`/api/public/community-rules`).
struct CommunityRulesDocument: Decodable, Equatable, Sendable {
    struct Rule: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let summary: String
        let text: String
    }

    let version: String
    /// Date d'entrée en vigueur, `yyyy-mm-dd`.
    let effectiveDate: Date?
    /// Vrai quand la langue demandée n'est pas rédigée : le serveur sert l'anglais.
    let fallback: Bool
    let rules: [Rule]

    enum CodingKeys: String, CodingKey { case version, effectiveDate, fallback, rules }

    init(version: String, effectiveDate: Date?, fallback: Bool, rules: [Rule]) {
        self.version = version
        self.effectiveDate = effectiveDate
        self.fallback = fallback
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decodeFlexibleString(forKey: .version) ?? ""
        effectiveDate = try? c.decodeIfPresent(Date.self, forKey: .effectiveDate)
        fallback = (try? c.decodeIfPresent(Bool.self, forKey: .fallback)) ?? false
        rules = c.decodeLossyArray([Rule].self, forKey: .rules)
    }
}

/// Bornes du message de recours (contrat : `appealMessage`).
enum ModerationAppealLimits {
    static let minimum = 10
    static let maximum = 2000
}
