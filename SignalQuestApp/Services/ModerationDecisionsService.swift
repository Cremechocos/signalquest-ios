import Foundation

/// Décisions de modération du compte connecté et leurs recours (contrat MOD-1),
/// les mêmes que sur Android : `/api/me/moderation/decisions`.
protocol ModerationDecisionsServicing: Sendable {
    func page(cursor: String?, limit: Int) async throws -> ModerationDecisionsPage
    func decision(id: String) async throws -> ModerationDecision
    /// Dépose le recours (une fois, dans les 6 mois) et rend la décision à jour.
    func appeal(decisionId: String, message: String) async throws -> ModerationDecision
    /// Marque vues cette décision et toutes les plus anciennes ; rend le nouveau compte.
    @discardableResult
    func markSeen(upTo decisionId: String) async throws -> Int
    func thumbnail(path: String) async throws -> Data
    /// Règles de la communauté, dans une version donnée ou la version en vigueur.
    func communityRules(version: String?) async throws -> CommunityRulesDocument
}

final class ModerationDecisionsService: ModerationDecisionsServicing {
    private let api: APIClient
    private let locale: @Sendable () -> String
    private let formal: @Sendable () -> Bool

    /// La langue et le ton se lisent à chaque appel : ils peuvent changer pendant
    /// que le processus vit (ton choisi dans les Réglages).
    init(api: APIClient,
         locale: @escaping @Sendable () -> String = { AccountLocaleSync.appLocale },
         formal: @escaping @Sendable () -> Bool = { SQAddress.isFormal }) {
        self.api = api
        self.locale = locale
        self.formal = formal
    }

    /// iOS n'envoie pas d'`Accept-Language` : la langue des libellés du serveur
    /// (motif, règle, issue du recours) passe par `?locale=`, comme le prévoit le contrat.
    private var localeItem: URLQueryItem { URLQueryItem(name: "locale", value: locale()) }

    func page(cursor: String?, limit: Int = 20) async throws -> ModerationDecisionsPage {
        if AppEnvironment.usesDemoData { return ModerationDecisionsDemo.page }
        var query = [localeItem, URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/me/moderation/decisions", query: query),
            as: ModerationDecisionsPage.self
        )
    }

    func decision(id: String) async throws -> ModerationDecision {
        if AppEnvironment.usesDemoData {
            guard let decision = ModerationDecisionsDemo.page.decisions.first(where: { $0.id == id }) else {
                throw APIError.http(status: 404, code: "NOT_FOUND", message: "", requestId: nil, retryAfter: nil)
            }
            return decision
        }
        guard let id = Self.safeId(id) else { throw Self.notFound }
        return try await api.request(
            APIEndpoint(path: "/api/me/moderation/decisions/\(id)", query: [localeItem]),
            as: DecisionEnvelope.self
        ).decision
    }

    func appeal(decisionId: String, message: String) async throws -> ModerationDecision {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return ModerationDecisionsDemo.appealed(try await decision(id: decisionId))
        }
        guard let decisionId = Self.safeId(decisionId) else { throw Self.notFound }
        // `?locale=` : la décision rendue garde les libellés dans la langue de l'app.
        let body = try JSONEncoder.signalQuest.encode(["message": message.trimmingCharacters(in: .whitespacesAndNewlines)])
        return try await api.request(
            APIEndpoint(path: "/api/me/moderation/decisions/\(decisionId)/appeal",
                        method: .post, query: [localeItem],
                        headers: ["Content-Type": "application/json"], body: body),
            as: DecisionEnvelope.self
        ).decision
    }

    @discardableResult
    func markSeen(upTo decisionId: String) async throws -> Int {
        struct Body: Encodable { let upTo: String }
        struct Response: Decodable { let unseenCount: Int }
        if AppEnvironment.usesDemoData { return 0 }
        guard let decisionId = Self.safeId(decisionId) else { throw Self.notFound }
        let response: Response = try await api.requestJSON(
            "/api/me/moderation/decisions/seen", body: Body(upTo: decisionId)
        )
        return max(0, response.unseenCount)
    }

    func thumbnail(path: String) async throws -> Data {
        guard let path = ModerationDecision.thumbnailPath(path) else {
            throw APIError.invalidURL(path)
        }
        return try await api.requestData(APIEndpoint(path: path))
    }

    func communityRules(version: String?) async throws -> CommunityRulesDocument {
        if AppEnvironment.usesDemoData { return ModerationDecisionsDemo.rules }
        var query = [localeItem, URLQueryItem(name: "addressForm", value: formal() ? "formal" : "informal")]
        if let version, !version.isEmpty { query.append(URLQueryItem(name: "version", value: version)) }
        // Route publique et mise en cache par le serveur : pas de session à joindre.
        return try await api.request(
            APIEndpoint(path: "/api/public/community-rules", query: query, authenticated: false),
            as: CommunityRulesDocument.self
        )
    }

    private struct DecisionEnvelope: Decodable { let decision: ModerationDecision }

    /// Un identifiant venu d'un push ne doit jamais changer de route (`/`, `..`) :
    /// le client encode le chemin lui-même, on n'admet donc que la forme des identifiants
    /// du serveur. Tout autre identifiant vaut « décision introuvable ».
    static func safeId(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard (1...64).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static let notFound = APIError.http(status: 404, code: "NOT_FOUND", message: "", requestId: nil, retryAfter: nil)
}

/// Décisions de démonstration (`--demo-data`) : captures et recette sans compte réel.
enum ModerationDecisionsDemo {
    private static let now = Date()
    private static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private static var french: Bool { AccountLocaleSync.appLocale == "fr" }

    static var page: ModerationDecisionsPage {
        ModerationDecisionsPage(decisions: [
            ModerationDecision(
                id: "demo-auto-post",
                decidedAt: daysAgo(0.1),
                target: .init(type: "social_post", id: "post-1", createdAt: daysAgo(1),
                              excerpt: french ? "La 5G vient d’être coupée sur tout le quartier, tout le monde y perd." : "5G has just been switched off across the whole area, everyone loses out."),
                action: "hidden",
                reason: .init(code: "misinformation", label: french ? "Information inexacte" : "Inaccurate information"),
                rule: .init(id: "R5", version: "1.0.1", title: french ? "Des informations exactes" : "Accurate information"),
                automated: true,
                appeal: .init(possible: true, deadline: daysAgo(-182), status: "none")
            ),
            ModerationDecision(
                id: "demo-photo",
                decidedAt: daysAgo(12),
                target: .init(type: "photo", id: "photo-1", createdAt: daysAgo(14)),
                action: "removed",
                reason: .init(code: "privacy", label: french ? "Atteinte à la vie privée" : "Privacy violation",
                              text: french ? "Une plaque d’immatriculation est lisible au premier plan." : "A number plate is readable in the foreground."),
                rule: .init(id: "R3", version: "1.0.1", title: french ? "Protéger la vie privée" : "Protect privacy"),
                automated: false,
                appeal: .init(possible: false, deadline: daysAgo(-170), status: "rejected", filedAt: daysAgo(11), decidedAt: daysAgo(9),
                              outcomeLabel: french ? "Recours rejeté : la décision est maintenue" : "Appeal rejected: the decision stands",
                              outcomeText: french ? "La plaque reste lisible même en réduisant l’image." : "The plate is still readable even at a smaller size.")
            ),
            ModerationDecision(
                id: "demo-account",
                decidedAt: daysAgo(40),
                target: .init(type: "account", id: "user-1"),
                action: "photo_upload_banned",
                accountRestriction: .init(type: "photo_upload_banned", until: daysAgo(-20)),
                reason: .init(code: "spam", label: french ? "Spam ou publicité" : "Spam or advertising"),
                rule: .init(id: "R6", version: "1.0.0", title: french ? "Ni spam ni publicité" : "No spam or advertising"),
                automated: false,
                appeal: .init(possible: false, deadline: daysAgo(-140), status: "pending", filedAt: daysAgo(38))
            ),
        ], nextCursor: nil, unseenCount: 1)
    }

    static func appealed(_ decision: ModerationDecision) -> ModerationDecision {
        ModerationDecision(id: decision.id, decidedAt: decision.decidedAt, target: decision.target, action: decision.action,
                           accountRestriction: decision.accountRestriction, until: decision.until, reason: decision.reason,
                           rule: decision.rule, automated: decision.automated,
                           appeal: .init(possible: false, deadline: decision.appeal.deadline, status: "pending", filedAt: Date()))
    }

    static var rules: CommunityRulesDocument {
        let rules: [CommunityRulesDocument.Rule] = french ? [
            .init(id: "R1", title: "Respecter les personnes", summary: "Ni harcèlement, ni insulte, ni menace, ni propos haineux.", text: ""),
            .init(id: "R3", title: "Protéger la vie privée", summary: "Pas de données personnelles d’autrui, ni de visage ou de plaque reconnaissable.", text: ""),
            .init(id: "R5", title: "Des informations exactes", summary: "Pas de fausse identification, de faux signalement ni de mesure truquée.",
                  text: "Les identifications, signalements de panne et mesures décrivent ce que tu as réellement constaté. Fausser les données ou les points de la communauté est sanctionné."),
            .init(id: "R6", title: "Ni spam ni publicité", summary: "Pas de messages répétés, de liens commerciaux ou de démarchage.", text: ""),
        ] : [
            .init(id: "R1", title: "Respect people", summary: "No harassment, insults, threats or hate speech.", text: ""),
            .init(id: "R3", title: "Protect privacy", summary: "No personal data of others, no recognisable faces or number plates.", text: ""),
            .init(id: "R5", title: "Accurate information", summary: "No false identifications, fake reports or tampered measurements.",
                  text: "Identifications, outage reports and measurements describe what you actually observed. Falsifying community data or points is sanctioned."),
            .init(id: "R6", title: "No spam or advertising", summary: "No repeated messages, commercial links or solicitation.", text: ""),
        ]
        return CommunityRulesDocument(version: "1.0.1", effectiveDate: SQDateParsing.parse("2026-10-19"), fallback: false, rules: rules)
    }
}
