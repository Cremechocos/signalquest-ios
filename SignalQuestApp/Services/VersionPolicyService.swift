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

enum ClientWriteStatus: Equatable, Sendable {
    case current
    case legacyAllowed
    case legacyGrace
    case blocked
}

struct ClientProtocolPolicy: Equatable, Sendable {
    let serverProtocolVersion: Int
    let minWriteProtocol: Int
    let legacyWriteDeadline: Date?
    let serverCapabilities: Set<String>
    let writeStatus: ClientWriteStatus

    static let fallback = ClientProtocolPolicy(
        serverProtocolVersion: 1,
        minWriteProtocol: 1,
        legacyWriteDeadline: nil,
        serverCapabilities: [],
        writeStatus: .current
    )
}

enum ClientProtocolContract {
    static let currentProtocolVersion = 1
    static let protocolVersionHeader = E2EEV2ProtocolWire.protocolVersionHeader
    static let capabilitiesHeaderName = E2EEV2ProtocolWire.capabilitiesHeader
    static let capabilities: Set<String> = [
        "exact_schedules_v2",
        "message_reminder_idempotency_v1",
        "network_identity_v2",
        "push_recipient_scope_v2",
    ]
    static let capabilitiesHeader = capabilities.sorted().joined(separator: ",")

    static func evaluateWriteStatus(
        minWriteProtocol: Int,
        legacyWriteDeadline: Date?,
        now: Date = Date()
    ) -> ClientWriteStatus {
        let normalizedMinimum = (1...100).contains(minWriteProtocol) ? minWriteProtocol : 1
        if currentProtocolVersion >= normalizedMinimum { return .current }
        guard let legacyWriteDeadline else { return .legacyAllowed }
        return now < legacyWriteDeadline ? .legacyGrace : .blocked
    }
}

enum E2EEV2ActivationDecision: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case securityReviewRequired
        case protocolVersionRequired
        case capabilityMissing
    }

    case enabled
    case disabled(reason: Reason, missingCapabilities: Set<String>)
}

enum E2EEV2ActivationPolicy {
    static let protocolVersion = E2EEV2ProtocolWire.version
    static let contractPreviewCapability = E2EEV2ProtocolWire.contractPreviewCapability
    static let deviceIdentityCapability = E2EEV2ProtocolWire.deviceIdentityCapability
    static let messageEnvelopeCapability = E2EEV2ProtocolWire.messageEnvelopeCapability
    static let encryptedMediaCapability = "e2ee_encrypted_media_v2"
    static let historyMigrationCapability = "e2ee_history_migration_v2"
    static let verifiedCallsCapability = "e2ee_verified_calls_v2"

    static let requiredWriteCapabilities: Set<String> = [
        deviceIdentityCapability,
        messageEnvelopeCapability,
    ]
    static let requiredFullCapabilities = requiredWriteCapabilities.union([
        encryptedMediaCapability,
        historyMigrationCapability,
        verifiedCallsCapability,
    ])

    static func evaluate(
        policy: ClientProtocolPolicy,
        securityReviewApproved: Bool,
        requiredCapabilities: Set<String> = requiredWriteCapabilities,
        clientProtocolVersion: Int = ClientProtocolContract.currentProtocolVersion,
        clientCapabilities: Set<String> = ClientProtocolContract.capabilities
    ) -> E2EEV2ActivationDecision {
        guard securityReviewApproved else {
            return .disabled(reason: .securityReviewRequired, missingCapabilities: [])
        }
        guard clientProtocolVersion >= protocolVersion,
              policy.serverProtocolVersion >= protocolVersion else {
            return .disabled(reason: .protocolVersionRequired, missingCapabilities: [])
        }
        let missing = Set(requiredCapabilities.filter { capability in
            !clientCapabilities.contains(capability) || !policy.serverCapabilities.contains(capability)
        })
        return missing.isEmpty
            ? .enabled
            : .disabled(reason: .capabilityMissing, missingCapabilities: missing)
    }
}

struct AppVersionPolicy: Decodable, Equatable, Sendable {
    let minVersionCode: Int
    let recommendedVersionCode: Int
    let warnMessage: String?
    let blockMessage: String?
    let storeURL: URL?
    let serverProtocolVersion: Int
    let minWriteProtocol: Int
    let legacyWriteDeadline: Date?
    let serverCapabilities: Set<String>

    enum CodingKeys: String, CodingKey {
        case minVersionCode, recommendedVersionCode, warnMessage, blockMessage, storeUrl
        case serverProtocolVersion, minWriteProtocol, legacyWriteDeadline, serverCapabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minVersionCode = (try? c.decodeIfPresent(Int.self, forKey: .minVersionCode)) as? Int ?? 1
        recommendedVersionCode = (try? c.decodeIfPresent(Int.self, forKey: .recommendedVersionCode)) as? Int ?? 1
        warnMessage = c.decodeFlexibleString(forKey: .warnMessage)
        blockMessage = c.decodeFlexibleString(forKey: .blockMessage)
        storeURL = c.decodeLossyURL(forKey: .storeUrl)
        serverProtocolVersion = ((try? c.decodeIfPresent(Int.self, forKey: .serverProtocolVersion)) ?? nil)
            .flatMap { (1...100).contains($0) ? $0 : nil } ?? 1
        minWriteProtocol = ((try? c.decodeIfPresent(Int.self, forKey: .minWriteProtocol)) ?? nil)
            .flatMap { (1...100).contains($0) ? $0 : nil } ?? 1
        legacyWriteDeadline = c.decodeFlexibleString(forKey: .legacyWriteDeadline)
            .flatMap(SQDateParsing.parse)
        let rawCapabilities = (try? c.decodeIfPresent([String].self, forKey: .serverCapabilities)) ?? nil
        serverCapabilities = Set((rawCapabilities ?? []).compactMap { raw in
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil else {
                return nil
            }
            return normalized
        })
    }

    init(
        minVersionCode: Int,
        recommendedVersionCode: Int,
        warnMessage: String?,
        blockMessage: String?,
        storeURL: URL?,
        serverProtocolVersion: Int = 1,
        minWriteProtocol: Int = 1,
        legacyWriteDeadline: Date? = nil,
        serverCapabilities: Set<String> = []
    ) {
        self.minVersionCode = minVersionCode
        self.recommendedVersionCode = recommendedVersionCode
        self.warnMessage = warnMessage
        self.blockMessage = blockMessage
        self.storeURL = storeURL
        self.serverProtocolVersion = serverProtocolVersion
        self.minWriteProtocol = minWriteProtocol
        self.legacyWriteDeadline = legacyWriteDeadline
        self.serverCapabilities = serverCapabilities
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
    @Published private(set) var protocolPolicy: ClientProtocolPolicy = .fallback

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
            protocolPolicy = ClientProtocolPolicy(
                serverProtocolVersion: policy.serverProtocolVersion,
                minWriteProtocol: policy.minWriteProtocol,
                legacyWriteDeadline: policy.legacyWriteDeadline,
                serverCapabilities: policy.serverCapabilities,
                writeStatus: ClientProtocolContract.evaluateWriteStatus(
                    minWriteProtocol: policy.minWriteProtocol,
                    legacyWriteDeadline: policy.legacyWriteDeadline
                )
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
