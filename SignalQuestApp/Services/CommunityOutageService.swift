import Foundation

/// Signalement communautaire de pannes.
///
/// Lire les pannes d'un site ou d'une emprise de carte, ouvrir la fiche de l'une d'elles, en
/// signaler une, se prononcer, refermer la sienne. La machine à états, les seuils et les points
/// vivent entièrement côté serveur — le client n'en réimplémente rien, il affiche ce qu'on lui rend.
protocol CommunityOutageServicing: Sendable {
    func outages(forSiteId siteId: String, targetKind: String, marketCode: String, operatorKey: String?) async throws -> [CommunityOutage]
    func outages(in bounds: MapBounds, marketCode: String, operatorKey: String?) async throws -> [CommunityOutage]
    func feed(scope: OutageFeedScope, offset: Int, limit: Int) async throws -> (outages: [CommunityOutage], hasMore: Bool)
    func detail(outageId: String) async throws -> CommunityOutage
    func report(_ request: OutageReportRequest) async throws -> OutageWriteResponse
    func vote(outageId: String, kind: String, latitude: Double?, longitude: Double?, accuracyMeters: Double?) async throws -> OutageWriteResponse
    func close(outageId: String) async throws -> OutageWriteResponse
}

final class CommunityOutageService: CommunityOutageServicing {
    private let api: APIClient

    init(api: APIClient) { self.api = api }

    /// Les pannes ouvertes d'un site.
    ///
    /// Jamais mise en cache : `myVote` et `canVote` dépendent de la personne connectée, et un
    /// cache ferait proposer « Confirmer » à quelqu'un qui a déjà voté.
    ///
    /// `targetKind` n'est PAS figé à `anfr` : dans les 44 marchés sans référentiel public, la
    /// seule antenne existante est un site posé à la main (`custom`). Le préfixe de `targetKey`
    /// est ce qui distingue les deux référentiels côté serveur — le figer rendait la panne d'un
    /// site communautaire introuvable depuis sa propre fiche.
    func outages(
        forSiteId siteId: String,
        targetKind: String,
        marketCode: String,
        operatorKey: String?
    ) async throws -> [CommunityOutage] {
        var query = [
            URLQueryItem(name: "targetKey", value: "\(targetKind):\(siteId)"),
            URLQueryItem(name: "marketCode", value: marketCode),
        ]
        if let operatorKey, !operatorKey.isEmpty, operatorKey != "ALL" {
            query.append(URLQueryItem(name: "operatorKey", value: operatorKey))
        }
        let response: CommunityOutagesResponse = try await api.request(
            APIEndpoint(path: "/api/community-outages", method: .get, query: query),
            as: CommunityOutagesResponse.self
        )
        return response.outages
    }

    /// Les pannes visibles sous l'emprise de la carte.
    ///
    /// La liste bornée par bbox, et NON la route de tuiles `/api/android/map/tiles/outages/…`,
    /// pour deux raisons. D'abord le volume : les pannes sont rares et dispersées, alors qu'un
    /// viewport se découpe en une vingtaine de tuiles (cf. `MapSnapshotService.visibleTiles`) —
    /// vingt requêtes dont presque toutes rendraient zéro marqueur, là où l'emprise n'en demande
    /// qu'une. Ensuite le contenu : la tuile AMPUTE l'objet (ni `canVote`, ni `myVote`, ni
    /// `confirmThreshold`, ni l'auteur), si bien que chaque tap sur un marqueur aurait exigé un
    /// second aller-retour avant de savoir s'il faut proposer l'arbitrage. Ici la carte tient
    /// déjà tout ce que la feuille affiche.
    ///
    /// Le prix payé est le cache HTTP de 30 s de la tuile. C'est le bon échange : sur une panne,
    /// la fraîcheur EST la valeur — et `myVote` n'est de toute façon pas cachable.
    func outages(
        in bounds: MapBounds,
        marketCode: String,
        operatorKey: String?
    ) async throws -> [CommunityOutage] {
        // Les `Double` non finis produiraient une URL que le serveur rejette en 500 plutôt qu'en
        // « rien à afficher ». Même garde que les couches de tuiles.
        guard bounds.isFinite else { throw APIError.cancelled }
        var query = [
            URLQueryItem(name: "south", value: "\(bounds.south)"),
            URLQueryItem(name: "west", value: "\(bounds.west)"),
            URLQueryItem(name: "north", value: "\(bounds.north)"),
            URLQueryItem(name: "east", value: "\(bounds.east)"),
            // Plafond serveur. En dessous, une région dense se ferait tronquer en silence sur
            // les pannes les moins récentes, sans que rien ne le signale à l'écran.
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "marketCode", value: marketCode),
        ]
        if let operatorKey, !operatorKey.isEmpty, operatorKey != "ALL" {
            query.append(URLQueryItem(name: "operatorKey", value: operatorKey))
        }
        let response: CommunityOutagesResponse = try await api.request(
            APIEndpoint(path: "/api/community-outages", method: .get, query: query),
            as: CommunityOutagesResponse.self
        )
        return response.outages
    }

    /// La liste paginée, pour la page « Pannes signalées » du profil.
    ///
    /// `mine` retient les pannes où l'on a mis quelque chose — signalée OU arbitrée. Quelqu'un
    /// qui a confirmé dix pannes a contribué autant que celui qui en a signalé une, et sa page
    /// doit le lui montrer.
    func feed(
        scope: OutageFeedScope,
        offset: Int,
        limit: Int
    ) async throws -> (outages: [CommunityOutage], hasMore: Bool) {
        var query = [
            URLQueryItem(name: "scope", value: scope == .mine ? "mine" : "all"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        // « Les miennes » garde une mémoire : une panne rétablie reste quelque chose qu'on a
        // fait, la masquer donnerait l'impression d'avoir contribué moins qu'en réalité.
        if scope == .mine {
            query.append(URLQueryItem(name: "includeClosed", value: "true"))
        }
        let response: CommunityOutagesResponse = try await api.request(
            APIEndpoint(path: "/api/community-outages", method: .get, query: query),
            as: CommunityOutagesResponse.self
        )
        return (response.outages, response.hasMore ?? false)
    }

    /// La fiche d'une panne, avec sa chronologie.
    ///
    /// Une lecture de plus alors que la carte et la liste portent déjà l'objet : c'est la SEULE
    /// route qui charge `timeline`, que les deux autres rendent à `null` pour ne pas payer une
    /// jointure d'événements par ligne. Elle accepte aussi les pannes closes, contrairement à la
    /// liste — une notification « c'est rétabli » ouvre cette fiche.
    func detail(outageId: String) async throws -> CommunityOutage {
        let response: CommunityOutageDetailResponse = try await api.request(
            APIEndpoint(path: "/api/community-outages/\(outageId)"),
            as: CommunityOutageDetailResponse.self
        )
        guard let outage = response.outage else { throw APIError.decoding("outage") }
        return outage
    }

    func report(_ request: OutageReportRequest) async throws -> OutageWriteResponse {
        try await write(path: "/api/community-outages", body: request)
    }

    func vote(
        outageId: String,
        kind: String,
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?
    ) async throws -> OutageWriteResponse {
        try await write(
            path: "/api/community-outages/\(outageId)/vote",
            body: OutageVoteRequest(
                kind: kind,
                latitude: latitude,
                longitude: longitude,
                accuracyMeters: accuracyMeters
            )
        )
    }

    /// L'auteur referme sa panne.
    ///
    /// Route dédiée et non une nature de voix de plus : l'unicité `(panne, personne)` côté serveur
    /// convertirait la ligne `report` de l'auteur, qui perdrait sa propre voix au moment même où il
    /// clôt. Fermer n'est pas se prononcer, c'est disposer de sa contribution.
    ///
    /// Sans corps : le serveur n'attend rien d'autre que l'identité du compte, portée par le
    /// cookie. `requestJSON` aurait exigé un `Encodable` vide inventé pour l'occasion.
    func close(outageId: String) async throws -> OutageWriteResponse {
        try await api.request(
            APIEndpoint(path: "/api/community-outages/\(outageId)/close", method: .post),
            as: OutageWriteResponse.self
        )
    }

    /// Envoi commun.
    ///
    /// L'erreur remonte TELLE QUELLE : c'est `OutageWriteError.message(for:)` qui la met en mots,
    /// au moment de l'afficher. La traduire ici obligerait à rendre une `String` là où l'appelant
    /// a parfois besoin de l'erreur elle-même (annulation à ignorer, 401 à router).
    private func write<Body: Encodable>(path: String, body: Body) async throws -> OutageWriteResponse {
        try await api.requestJSON(path, method: .post, body: body)
    }
}

/// La phrase d'un refus d'ÉCRITURE — signaler, se prononcer, refermer.
///
/// Le serveur ne rédige qu'en français (« Vous êtes trop loin de ce site », « Seul l'auteur peut
/// refermer cette panne ») : affichée telle quelle, cette phrase atteignait un utilisateur
/// anglophone dans une langue qu'il ne lit pas. Le CODE, lui, fait partie du contrat client↔serveur
/// au même titre qu'`ATTESTATION_FAILED` ailleurs — c'est donc sur lui que le client choisit sa
/// phrase, exactement comme Android le fait déjà (`outageWriteErrorRes` / `outageCloseErrorRes`).
///
/// Codes couverts, relevés dans les routes elles-mêmes (`apps/api/app/api/community-outages/`
/// `route.ts`, `[id]/vote/route.ts`, `[id]/close/route.ts`) et dans le type `OutageSignalRejection`
/// de `packages/db/outages.ts`, que les deux dernières remontent en majuscules par leur branche
/// `error.reason.toUpperCase()`.
///
/// ⚠️ `NOT_ELIGIBLE` transporte un motif fin dans `details.refusal` (`too_far`,
/// `inaccurate_position`, `no_position`, `no_history`) que cette table n'exploite PAS :
/// `APIError.http` ne porte ni `details` ni aucun autre champ libre, et l'y ajouter aurait touché
/// la vingtaine de sites qui filtrent ce cas dans toute l'app. La phrase unique ci-dessous nomme
/// donc les deux remèdes — s'approcher, ou avoir relevé du signal — au lieu du seul qui s'applique.
enum OutageWriteError {
    /// La phrase à afficher, quelle que soit l'erreur reçue.
    ///
    /// Une erreur qui n'est pas un refus HTTP (coupure réseau, réponse illisible) garde son propre
    /// libellé : `APIError.errorDescription` le rend déjà localisé et côté client.
    static func message(for error: Error) -> String {
        guard let api = error as? APIError,
              case .http(let status, let code, _, _, _) = api
        else { return error.localizedDescription }
        return phrase(forCode: code) ?? APIError.statusFallback(status)
    }

    /// `nil` quand le code n'est pas connu de cette table : l'appelant retombe alors sur le repli
    /// par statut HTTP, jamais sur la phrase du serveur.
    static func phrase(forCode code: String?) -> String? {
        switch code?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "UNAUTHORIZED":
            return String(localized: "Connectez-vous pour signaler une panne ou vous prononcer.")
        case "NOT_FOUND", "OUTAGE_NOT_FOUND":
            return String(localized: "Cette panne n'existe plus.")
        case "NOT_AUTHOR":
            return String(localized: "Seul l'auteur du signalement peut refermer cette panne.")
        case "OUTAGE_CLOSED":
            return String(localized: "Cette panne est refermée. Signalez-en une nouvelle si le problème dure.")
        case "SELF_CONFIRMATION":
            return String(localized: "Vous ne pouvez pas confirmer votre propre signalement.")
        case "ALREADY_REPORTED", "DUPLICATE_REPORT":
            return String(localized: "Vous avez déjà signalé cette panne.")
        case "OPEN_CONFLICT":
            return String(localized: "Une panne est déjà ouverte sur ce site pour cet opérateur.")
        case "NOT_ELIGIBLE":
            return String(localized: "Approchez-vous du site, ou relevez-y du signal : c'est ce qui vous permet de vous prononcer.")
        case "POSITION_REQUIRED":
            return String(localized: "Activez la localisation pour signaler une panne ici.")
        case "UNKNOWN_SITE", "INVALID_TARGET_KIND":
            return String(localized: "Ce site n'a pas été reconnu.")
        case "MISSING_SCOPE", "INVALID_OPERATOR":
            return String(localized: "Impossible de rattacher ce signalement à un opérateur.")
        case "COMMENT_TOO_LONG":
            return String(localized: "Le commentaire est trop long.")
        case "PAYLOAD_TOO_LARGE":
            return String(localized: "Les mesures jointes sont trop volumineuses.")
        default:
            return nil
        }
    }
}
