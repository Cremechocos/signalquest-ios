import Foundation

/// Livraison serveur des transactions App Store : envoie la preuve JWS d'une
/// transaction StoreKit au backend, qui la vérifie côté serveur (App Store Server
/// API — validation de la chaîne de signature jusqu'à la racine Apple) puis
/// renvoie l'état d'entitlement canonique multiplateforme.
///
/// C'est le maillon volontairement absent tant que la validation serveur n'était
/// pas prête : sans lui, `EntitlementsStore` ne peut déclencher aucun débit
/// (`EntitlementsError.transactionDeliveryUnavailable`). L'`EntitlementsStore`
/// reste par ailleurs gardé par les flags `SQFeatures.storeKit*`, si bien que la
/// simple présence de ce synchroniseur n'ouvre pas les achats à elle seule.
struct AppStoreTransactionSynchronizer: AppStoreTransactionSyncing {
    /// Endpoint backend de validation Apple. Contrat attendu (ticket `map-nextjs`,
    /// additif/idempotent) : reçoit un `AppStoreTransactionProof` (JWS
    /// `signedTransaction` + identifiants), vérifie le JWS avec l'App Store Server
    /// API, met à jour l'entitlement `apple_appstore`, et répond avec le MÊME
    /// format que le GET `/api/billing/subscription` (`BillingSubscriptionResponse`).
    /// L'idempotence est portée par `transactionId` : rejouer une transaction ne
    /// doit jamais octroyer un droit en double.
    static let verifyEndpoint = "/api/billing/apple/verify"

    private let api: APIClientProtocol

    init(api: APIClientProtocol) {
        self.api = api
    }

    func synchronize(_ proof: AppStoreTransactionProof) async throws -> EntitlementSnapshot {
        let body = try JSONEncoder.signalQuest.encode(proof)
        let response = try await api.request(
            APIEndpoint(
                path: Self.verifyEndpoint,
                method: .post,
                headers: ["Content-Type": "application/json"],
                body: body,
                // Idempotence forte : le backend déduplique sur la transaction Apple,
                // et un rejeu automatique (refresh 401, backoff 429) réutilise la même clé.
                idempotencyKey: proof.transactionId
            ),
            as: BillingSubscriptionResponse.self
        )
        return EntitlementSnapshot(response: response)
    }
}
