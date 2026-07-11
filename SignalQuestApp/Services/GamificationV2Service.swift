import Foundation

// Contrat aligné sur l'app Android (source de vérité) :
// - GET  /api/gamification/v2/home        → { profile, season, radar[], quests[], … }
// - POST /api/gamification/v2/quest-claim → body { questKey, scopeKey },
//   réponse { alreadyClaimed, award: { pointsAwarded, totalPoints, level } }
// On ne décode ICI que ce dont l'UI iOS a besoin (saison + quêtes), de façon
// tolérante : tous les champs sont optionnels ou munis d'une valeur par défaut,
// un champ manquant ne doit jamais faire échouer l'écran.

struct GamificationV2Season: Decodable, Equatable {
    let code: String?
    let name: String?

    enum CodingKeys: String, CodingKey { case code, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.decodeFlexibleString(forKey: .code)
        name = c.decodeFlexibleString(forKey: .name)
    }
}

struct GamificationV2Quest: Decodable, Identifiable, Equatable {
    let key: String
    /// Périmètre de la quête (jour/semaine/saison courante) — exigé par le
    /// backend lors du claim, au même titre que la clé.
    let scopeKey: String?
    let title: String?
    let description: String?
    /// `daily` / `weekly` / `seasonal` / `event` / `local` (Android : cadenceLabel).
    let cadence: String?
    let progressValue: Int
    let targetValue: Int
    /// `active` / `completed` / `claimed`.
    let status: String?
    let rewardXp: Int

    var id: String { "\(key)#\(scopeKey ?? "")" }
    var isCompleted: Bool { status == "completed" }
    var isClaimed: Bool { status == "claimed" }
    /// Réclamable = terminée mais récompense pas encore encaissée.
    var isClaimable: Bool { isCompleted && !isClaimed }
    var progress: Double {
        guard targetValue > 0 else { return 0 }
        // Une quête réclamée/terminée est pleine même si le backend a remis
        // le compteur de progression à zéro pour la période suivante.
        if isClaimed || isCompleted { return 1 }
        return min(1, Double(progressValue) / Double(targetValue))
    }

    enum CodingKeys: String, CodingKey {
        case key, scopeKey, title, description, cadence
        case progressValue, targetValue, status, rewardXp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.decodeFlexibleString(forKey: .key) ?? UUID().uuidString
        scopeKey = c.decodeFlexibleString(forKey: .scopeKey)
        title = c.decodeFlexibleString(forKey: .title)
        description = c.decodeFlexibleString(forKey: .description)
        cadence = c.decodeFlexibleString(forKey: .cadence)
        progressValue = (try? c.decodeIfPresent(Int.self, forKey: .progressValue)) ?? 0
        targetValue = max(1, (try? c.decodeIfPresent(Int.self, forKey: .targetValue)) ?? 1)
        status = c.decodeFlexibleString(forKey: .status)
        rewardXp = (try? c.decodeIfPresent(Int.self, forKey: .rewardXp)) ?? 0
    }

    /// Copie marquée « réclamée » — mise à jour optimiste après un claim réussi.
    func markedClaimed() -> GamificationV2Quest {
        GamificationV2Quest(
            key: key, scopeKey: scopeKey, title: title, description: description,
            cadence: cadence, progressValue: progressValue, targetValue: targetValue,
            status: "claimed", rewardXp: rewardXp
        )
    }

    init(
        key: String, scopeKey: String?, title: String?, description: String?,
        cadence: String?, progressValue: Int, targetValue: Int, status: String?, rewardXp: Int
    ) {
        self.key = key
        self.scopeKey = scopeKey
        self.title = title
        self.description = description
        self.cadence = cadence
        self.progressValue = progressValue
        self.targetValue = max(1, targetValue)
        self.status = status
        self.rewardXp = rewardXp
    }
}

struct GamificationV2Home: Decodable, Equatable {
    let season: GamificationV2Season?
    /// Liste complète des quêtes de la période (l'UI groupe par cadence).
    let quests: [GamificationV2Quest]
    /// Sélection « radar » mise en avant côté Android — repli si `quests` est vide.
    let radar: [GamificationV2Quest]

    enum CodingKeys: String, CodingKey { case season, quests, radar }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        season = try? c.decodeIfPresent(GamificationV2Season.self, forKey: .season)
        quests = c.decodeLossyArray([GamificationV2Quest].self, forKey: .quests)
        radar = c.decodeLossyArray([GamificationV2Quest].self, forKey: .radar)
    }

    /// Quêtes affichables (liste complète, sinon radar), dédupliquées par id.
    var displayQuests: [GamificationV2Quest] {
        let source = quests.isEmpty ? radar : quests
        var seen = Set<String>()
        return source.filter { seen.insert($0.id).inserted }
    }
}

struct GamificationV2QuestClaim: Decodable {
    let alreadyClaimed: Bool
    let pointsAwarded: Int

    enum CodingKeys: String, CodingKey { case alreadyClaimed, award }
    private struct Award: Decodable {
        let pointsAwarded: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alreadyClaimed = (try? c.decodeIfPresent(Bool.self, forKey: .alreadyClaimed)) ?? false
        let award = try? c.decodeIfPresent(Award.self, forKey: .award)
        pointsAwarded = award?.pointsAwarded ?? 0
    }
}

protocol GamificationV2Servicing: Sendable {
    func home() async throws -> GamificationV2Home
    @discardableResult
    func claim(questKey: String, scopeKey: String?) async throws -> GamificationV2QuestClaim
}

final class GamificationV2Service: GamificationV2Servicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func home() async throws -> GamificationV2Home {
        try await api.request(APIEndpoint(path: "/api/gamification/v2/home"), as: GamificationV2Home.self)
    }

    @discardableResult
    func claim(questKey: String, scopeKey: String?) async throws -> GamificationV2QuestClaim {
        struct Body: Encodable {
            let questKey: String
            let scopeKey: String?
        }
        return try await api.requestJSON(
            "/api/gamification/v2/quest-claim",
            body: Body(questKey: questKey, scopeKey: scopeKey)
        )
    }
}
