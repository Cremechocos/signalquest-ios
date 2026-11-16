import Foundation

/// Refus du serveur que l'écran du Bilan sait montrer (contrat Abonnements v1.20 §3).
enum MonthlyRecapError: Error, Equatable {
    /// 403 `PREMIUM_REQUIRED` : le compte n'a pas ou plus Premium.
    case premiumRequired
    /// 404 `RECAP_NOT_FOUND` : mois clos sans aucune activité.
    case notFound
    /// 409 `RECAP_NOT_READY` : mois en cours ou pas encore figé.
    case notReady
    /// 422 `INVALID_MONTH` / `INVALID_IMAGE_OPTION` : mois hors des 12 derniers mois clos.
    case invalidMonth
    /// Réseau, serveur ou réponse illisible : « Réessayer ».
    case unavailable

    static func from(_ error: Error) -> MonthlyRecapError {
        if let known = error as? MonthlyRecapError { return known }
        guard case let APIError.http(status, code, _, _, _) = error else { return .unavailable }
        switch (status, code) {
        case (403, "PREMIUM_REQUIRED"): return .premiumRequired
        case (404, _): return .notFound
        case (409, _): return .notReady
        case (422, _): return .invalidMonth
        default: return .unavailable
        }
    }
}

/// Options de l'image de partage. Toujours toutes envoyées : le serveur ne devine rien.
struct MonthlyRecapImageOptions: Equatable, Sendable {
    var language: String
    var formal: Bool
    var imperial: Bool
    var showIdentity: Bool

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "address", value: formal ? "vous" : "tu"),
            URLQueryItem(name: "units", value: imperial ? "mi" : "km"),
            URLQueryItem(name: "identity", value: showIdentity ? "1" : "0"),
        ]
    }
}

protocol MonthlyRecapServicing: Sendable {
    /// Les 12 derniers mois clos, du plus récent au plus ancien.
    func months() async throws -> [MonthlyRecapMonth]
    /// Le Bilan figé d'un mois. Hors ligne, le dernier Bilan lu de ce compte est rendu.
    func recap(month: String) async throws -> MonthlyRecap
    /// L'image 1080 × 1350 du serveur, PNG.
    func image(month: String, options: MonthlyRecapImageOptions) async throws -> Data
    /// Déconnexion volontaire : les Bilans gardés pour la lecture hors ligne quittent l'appareil.
    func eraseLocalData(ownerScopeId: String) async
}

final class MonthlyRecapService: MonthlyRecapServicing {
    private let api: APIClient
    /// Un Bilan est figé : on garde la dernière lecture de chaque mois, par compte, pour
    /// le relire sans réseau. Jamais servi après un 403 : Premium terminé, rien ne s'affiche.
    private let cache: DiskCache

    init(api: APIClient, cache: DiskCache = DiskCache(
        folderName: "SignalQuestRecapCache", fileProtection: .completeUntilFirstUserAuthentication,
        maxBytes: 2 * 1024 * 1024, maxAge: 400 * 24 * 60 * 60
    )) {
        self.api = api
        self.cache = cache
    }

    func months() async throws -> [MonthlyRecapMonth] {
        do {
            return try await api.request(APIEndpoint(path: "/api/me/recap"), as: MonthlyRecapMonthList.self).months
        } catch {
            throw MonthlyRecapError.from(error)
        }
    }

    func recap(month: String) async throws -> MonthlyRecap {
        guard MonthlyRecapLink.isMonth(month) else { throw MonthlyRecapError.invalidMonth }
        let ownerScopeId = LocalAccountScope.sessionSnapshot()?.ownerScopeId
        let key = ownerScopeId.map { Self.cacheKey(ownerScopeId: $0, month: month) }
        do {
            let recap = try await api.request(APIEndpoint(path: "/api/me/recap/\(month)"), as: MonthlyRecap.self)
            if let key { try? await cache.write(recap, for: key) }
            return recap
        } catch {
            let mapped = MonthlyRecapError.from(error)
            // Premium terminé : aucun Bilan de ce compte ne reste lisible sur l'appareil.
            if mapped == .premiumRequired, let ownerScopeId {
                await eraseLocalData(ownerScopeId: ownerScopeId)
            }
            if mapped == .unavailable, Self.isOffline(error), let key,
               let kept = try? await cache.read(MonthlyRecap.self, for: key) {
                return kept
            }
            throw mapped
        }
    }

    func image(month: String, options: MonthlyRecapImageOptions) async throws -> Data {
        guard MonthlyRecapLink.isMonth(month) else { throw MonthlyRecapError.invalidMonth }
        do {
            return try await api.requestData(APIEndpoint(path: "/api/me/recap/\(month)/image", query: options.queryItems))
        } catch {
            throw MonthlyRecapError.from(error)
        }
    }

    func eraseLocalData(ownerScopeId: String) async {
        await cache.removeAll(withPrefix: Self.cachePrefix(ownerScopeId: ownerScopeId))
    }

    static func cachePrefix(ownerScopeId: String) -> String {
        "recap-\(LocalAccountScope.storageNamespace(for: ownerScopeId))-"
    }

    static func cacheKey(ownerScopeId: String, month: String) -> String {
        cachePrefix(ownerScopeId: ownerScopeId) + month
    }

    private static func isOffline(_ error: Error) -> Bool {
        if case APIError.transport = error { return true }
        return false
    }
}
