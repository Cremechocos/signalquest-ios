import CryptoKit
import Foundation

/// §2.1 : la clé d'identité de compte (UIK) de la v2 à approbations, sur les
/// appareils entrés en v2 avant la bascule. Plus rien ne la crée ni ne la
/// transmet (E2EE-AUTO lot 10) : seule la vérification des anciens signataires
/// (`legacySigners`) la lit encore, tant que le serveur sert les routes v2
/// (§12, avant l'étape 5). Au repos dans le coffre E2EE du compte, classe
/// `WhenUnlockedThisDeviceOnly`, jamais synchronisée.
final class E2EEV2AccountIdentityStore: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case invalidRecord
        case otherAccount
    }

    static func key(ownerNamespace: String) -> String { "uik-v1:\(ownerNamespace)" }

    private let tokenStore: TokenStore
    private let allowsOwner: @Sendable (String) -> Bool

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee"),
         allowsOwner: @escaping @Sendable (String) -> Bool = { E2EEV2VaultBoundary.allows($0) }) {
        self.tokenStore = tokenStore
        self.allowsOwner = allowsOwner
    }

    func load(ownerNamespace: String) throws -> P256.Signing.PrivateKey? {
        guard allowsOwner(ownerNamespace) else { throw Failure.otherAccount }
        guard let raw = try tokenStore.string(for: Self.key(ownerNamespace: ownerNamespace)) else { return nil }
        guard let data = Data(base64Encoded: raw),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
            throw Failure.invalidRecord
        }
        return key
    }
}

/// Ce que sait faire cette app, tel que l'annuaire du chiffrement automatique
/// le prête à chaque appareil actif du journal (E2EE-AUTO §7) et que les
/// réactions lisent. Le document de capacités signé n'est plus publié : depuis
/// la bascule, le serveur ne le lit plus (époques marquées, appels).
enum E2EEV2CapabilitiesPublicationStore {
    /// Ce qu'iOS sait lire en v2 : texte, modification, suppression ; « appels
    /// vérifiés » seulement quand le verrou d'appels est ouvert (§10.0), les
    /// médias chiffrés au jalon B. Les réactions (D.16) s'annoncent ensemble,
    /// enveloppe v3, `REACTION` et `reactions`, une fois le chiffrement
    /// automatique actif.
    static var announcesReactions: Bool { SQFeatures.e2eeReactionsEnabled && E2EEV2ServerGate.autoActive }
    static var envelopeVersions: [String] { announcesReactions ? ["2", "3"] : ["2"] }
    static var kinds: [String] {
        announcesReactions ? ["DELETE", "EDIT", "REACTION", "TEXT"] : ["DELETE", "EDIT", "TEXT"]
    }
    static var features: [String] {
        var features: [String] = []
        #if DEBUG
        if announcesCallsForLocalQA { features = ["calls"] }
        #endif
        if features.isEmpty, E2EEV2CallRuntimeGate.allowsControlPlane() { features = ["calls"] }
        if announcesReactions { features.append("reactions") }
        return features
    }
    #if DEBUG
    /// Essai d'appel local (tests, pile en boucle locale) : « appels » annoncé
    /// sans ouvrir le verrou global. N'existe pas en Release.
    nonisolated(unsafe) static var announcesCallsForLocalQA = false
    #endif
}
