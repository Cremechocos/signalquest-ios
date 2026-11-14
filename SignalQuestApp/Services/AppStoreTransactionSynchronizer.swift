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
    /// Endpoint backend de validation Apple : reçoit un `AppStoreTransactionProof`
    /// (JWS `signedTransaction` + identifiants), vérifie le JWS, met à jour le
    /// droit `apple_appstore` et répond avec la charge de droits (contrat v1 §3,
    /// ancienne forme `tier` + `purchases[]` gardée en parallèle), décodée par
    /// `BillingSubscriptionResponse`. L'idempotence est portée par `transactionId` :
    /// rejouer une transaction ne doit jamais octroyer un droit en double.
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
                // Un refus de cette route ne déconnecte jamais (C2, contrat v1 §5) :
                // l'ancien serveur répondait 401 à une preuve refusée, que le client
                // lisait comme une session expirée. Sans rafraîchissement automatique,
                // un 401 remonte tel quel et la transaction reste ouverte, rejouée
                // plus tard par StoreKit et par le renvoi au lancement.
                skipsAutoRefresh: true,
                // Idempotence forte : le backend déduplique sur la transaction Apple,
                // et un rejeu automatique (backoff 429/503) réutilise la même clé.
                idempotencyKey: proof.transactionId
            ),
            as: BillingSubscriptionResponse.self
        )
        return EntitlementSnapshot(response: response)
    }
}
