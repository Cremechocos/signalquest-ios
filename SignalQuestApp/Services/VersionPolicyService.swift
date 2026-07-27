import Foundation
import os

/// Verdict de la politique de version serveur.
enum VersionPolicyState: Equatable, Sendable {
    /// Aucune réponse exploitable — l'app fonctionne normalement.
    case unknown
    case upToDate
    case updateRecommended(message: String?, storeURL: URL?)
    case updateRequired(message: String?, storeURL: URL?)

    var blocksApp: Bool {
        if case .updateRequired = self { return true }
        return false
    }
}

struct AppVersionPolicy: Decodable, Equatable, Sendable {
    let minVersionCode: Int
    let recommendedVersionCode: Int
    let warnMessage: String?
    let blockMessage: String?
    let storeURL: URL?

    enum CodingKeys: String, CodingKey {
        case minVersionCode, recommendedVersionCode, warnMessage, blockMessage, storeUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minVersionCode = (try? c.decodeIfPresent(Int.self, forKey: .minVersionCode)) as? Int ?? 1
        recommendedVersionCode = (try? c.decodeIfPresent(Int.self, forKey: .recommendedVersionCode)) as? Int ?? 1
        warnMessage = c.decodeFlexibleString(forKey: .warnMessage)
        blockMessage = c.decodeFlexibleString(forKey: .blockMessage)
        storeURL = c.decodeLossyURL(forKey: .storeUrl)
    }

    init(minVersionCode: Int, recommendedVersionCode: Int, warnMessage: String?, blockMessage: String?, storeURL: URL?) {
        self.minVersionCode = minVersionCode
        self.recommendedVersionCode = recommendedVersionCode
        self.warnMessage = warnMessage
        self.blockMessage = blockMessage
        self.storeURL = storeURL
    }
}

/// Permet de forcer une mise à jour sans passer par une revue App Store.
///
/// C'est le prérequis du durcissement de contrats côté backend : sans lui,
/// resserrer un schéma (par exemple rendre `acceptedTerms` obligatoire à
/// l'inscription) casserait silencieusement toutes les versions déjà
/// installées.
///
/// Porté de `VersionPolicyManager.kt`, avec la même tolérance aux erreurs :
/// l'appel est best-effort, tout échec laisse l'état à `.unknown` et l'app
/// continue normalement. Un service de blocage qui bloque parce que le réseau
/// est tombé serait pire que pas de service du tout.
@MainActor
final class VersionPolicyService: ObservableObject {
    @Published private(set) var state: VersionPolicyState = .unknown

    private let api: APIClient
    private let currentBuild: Int?
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "VersionPolicy")

    /// `CFBundleVersion` doit être un entier : c'est `CURRENT_PROJECT_VERSION`,
    /// que la cible app expose désormais comme build setting. S'il n'est pas
    /// analysable, on renvoie `nil` et AUCUN blocage n'est possible — un défaut
    /// de configuration ne doit jamais mettre l'app hors service.
    nonisolated static func parseBuildNumber(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Tolère « 12.3 » (schéma parfois utilisé en TestFlight) en ne gardant
        // que la composante majeure.
        let major = raw.split(separator: ".").first.map(String.init) ?? raw
        return Int(major)
    }

    init(api: APIClient, bundle: Bundle = .main) {
        self.api = api
        self.currentBuild = Self.parseBuildNumber(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// Best-effort : ne lève jamais, ne bloque jamais sur erreur.
    func refresh() async {
        guard let currentBuild else {
            logger.error("CFBundleVersion non analysable : politique de version ignorée.")
            return
        }
        do {
            let policy: AppVersionPolicy = try await api.request(
                APIEndpoint(
                    path: "/api/app/version-policy",
                    query: [URLQueryItem(name: "platform", value: "ios")],
                    authenticated: false
                ),
                as: AppVersionPolicy.self
            )
            state = Self.evaluate(policy: policy, currentBuild: currentBuild)
        } catch {
            guard !error.isCancellation else { return }
            logger.warning("Récupération de la politique de version échouée : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Séparée de l'appel réseau pour être testable, et parce que c'est ici que
    /// se joue le risque : une erreur de comparaison rend l'app inutilisable
    /// pour tout le monde d'un coup.
    nonisolated static func evaluate(policy: AppVersionPolicy, currentBuild: Int) -> VersionPolicyState {
        // Garde-fou : une politique incohérente (valeurs négatives, minimum
        // au-dessus du recommandé) est traitée comme absente plutôt que comme un
        // ordre de blocage.
        guard policy.minVersionCode > 0, policy.recommendedVersionCode > 0,
              policy.minVersionCode <= policy.recommendedVersionCode else {
            return .unknown
        }
        if currentBuild < policy.minVersionCode {
            return .updateRequired(message: policy.blockMessage, storeURL: policy.storeURL)
        }
        if currentBuild < policy.recommendedVersionCode {
            return .updateRecommended(message: policy.warnMessage, storeURL: policy.storeURL)
        }
        return .upToDate
    }
}
