import XCTest
@testable import SignalQuest

final class EntitlementsTests: XCTestCase {
    func testProductCatalogContainsTheFourPlannedOffers() {
        XCTAssertEqual(
            Set(SignalQuestSubscriptionProduct.allCases.map(\.rawValue)),
            Set([
                "fr.signalquest.ios.basic.monthly",
                "fr.signalquest.ios.basic.annual",
                "fr.signalquest.ios.premium.monthly",
                "fr.signalquest.ios.premium.annual",
            ])
        )
        XCTAssertEqual(
            SignalQuestSubscriptionProduct.product(tier: .basic, period: .monthly),
            .basicMonthly
        )
        XCTAssertEqual(
            SignalQuestSubscriptionProduct.product(tier: .premium, period: .annual),
            .premiumAnnual
        )
        XCTAssertEqual(SignalQuestSubscriptionProduct.basicMonthly.plannedDisplayPrice, "2,99 € / mois")
        XCTAssertEqual(SignalQuestSubscriptionProduct.basicAnnual.plannedDisplayPrice, "29,99 € / an")
        XCTAssertEqual(SignalQuestSubscriptionProduct.premiumMonthly.plannedDisplayPrice, "7,99 € / mois")
        XCTAssertEqual(SignalQuestSubscriptionProduct.premiumAnnual.plannedDisplayPrice, "79,99 € / an")
    }

    func testBackendSnapshotKeepsStripeAsCanonicalSource() throws {
        let response = try decodeResponse("""
        {
          "tier": "premium",
          "purchases": [{
            "id": "purchase-1",
            "provider": "stripe",
            "tier": "premium",
            "status": "active",
            "cancelAtPeriodEnd": false,
            "currentPeriodEnd": "2026-08-10T10:00:00.000Z",
            "expiresAt": null,
            "startsAt": "2026-07-10T10:00:00.000Z"
          }]
        }
        """)

        let snapshot = EntitlementSnapshot(response: response)
        XCTAssertEqual(snapshot.tier, .premium)
        XCTAssertEqual(snapshot.source, .stripe)
        XCTAssertEqual(snapshot.status, .active)
        XCTAssertNil(snapshot.period, "L'API ne renvoie pas l'intervalle : il ne doit pas être deviné")
        XCTAssertNotNil(snapshot.expiresAt)
    }

    func testPastDuePurchaseBlocksNewPurchaseEvenAfterTierRemoval() throws {
        let response = try decodeResponse("""
        {
          "tier": "free",
          "purchases": [{
            "id": "purchase-2",
            "provider": "google_play",
            "tier": "premium",
            "status": "past_due",
            "cancelAtPeriodEnd": false,
            "currentPeriodEnd": null,
            "expiresAt": null,
            "startsAt": null
          }]
        }
        """)

        let snapshot = EntitlementSnapshot(response: response)
        XCTAssertEqual(snapshot.tier, .free)
        XCTAssertEqual(snapshot.source, .googlePlay)
        XCTAssertEqual(snapshot.status, .paymentFailed)
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .available(snapshot),
                localTier: .free,
                purchasesEnabled: true,
                serverVerificationReady: true
            ),
            .existingBackendEntitlement(snapshot)
        )
    }

    func testManualEntitlementWithoutPurchaseIsPreserved() throws {
        let response = try decodeResponse("""
        { "tier": "basic", "purchases": [] }
        """)
        let snapshot = EntitlementSnapshot(response: response)
        XCTAssertEqual(snapshot.tier, .basic)
        XCTAssertEqual(snapshot.source, .manual)
        XCTAssertEqual(snapshot.status, .active)
    }

    func testEligibilityRequiresKnownFreeServerStateAndAppleDelivery() {
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .available(.free),
                localTier: .free,
                purchasesEnabled: true,
                serverVerificationReady: true
            ),
            .allowed
        )
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .available(.free),
                localTier: .free,
                purchasesEnabled: true,
                serverVerificationReady: false
            ),
            .serverVerificationUnavailable
        )
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .unavailable("offline"),
                localTier: .free,
                purchasesEnabled: true,
                serverVerificationReady: true
            ),
            .backendUnavailable
        )
    }

    func testLocalAppStoreEntitlementPreventsDuplicatePurchase() {
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .available(.free),
                localTier: .premium,
                purchasesEnabled: true,
                serverVerificationReady: true
            ),
            .existingLocalAppStoreEntitlement(.premium)
        )
    }

    func testActiveBackendPurchaseStillBlocksIfResolvedTierIsTemporarilyInconsistent() {
        let inconsistentSnapshot = EntitlementSnapshot(
            tier: .free,
            source: .stripe,
            period: nil,
            status: .active,
            expiresAt: nil
        )
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .available(inconsistentSnapshot),
                localTier: .free,
                purchasesEnabled: true,
                serverVerificationReady: true
            ),
            .existingBackendEntitlement(inconsistentSnapshot)
        )
    }

    func testBillingEndpointIsCanonicalAPIPath() {
        XCTAssertEqual(EntitlementsStore.subscriptionEndpoint, "/api/billing/subscription")
    }

    private func decodeResponse(_ json: String) throws -> BillingSubscriptionResponse {
        try JSONDecoder.signalQuest.decode(BillingSubscriptionResponse.self, from: Data(json.utf8))
    }

    // MARK: - Interpolations

    /// Régression : trois messages destinés à l'utilisateur avaient perdu leur
    /// antislash d'interpolation et affichaient littéralement
    /// « (snapshot.tier.displayName) ». Celui du chemin de succès d'achat
    /// (`purchase()`) serait parti cassé en production le jour de l'ouverture
    /// des achats — aucun test n'assertait sur le contenu de ces chaînes.
    func testEligibilityMessagesInterpolateSnapshotValues() {
        let snapshot = EntitlementSnapshot(
            tier: .premium,
            source: .googlePlay,
            period: nil,
            status: .active,
            expiresAt: nil
        )
        let message = PurchaseEligibility.existingBackendEntitlement(snapshot).userMessage
        XCTAssertTrue(message.contains(snapshot.tier.displayName), message)
        XCTAssertTrue(message.contains(snapshot.source.displayName), message)
        XCTAssertFalse(message.contains("snapshot."), "Interpolation non résolue : \(message)")

        let failing = EntitlementSnapshot(
            tier: .premium,
            source: .googlePlay,
            period: nil,
            status: .paymentFailed,
            expiresAt: nil
        )
        let failingMessage = PurchaseEligibility.existingBackendEntitlement(failing).userMessage
        XCTAssertTrue(failingMessage.contains(failing.source.displayName), failingMessage)
        XCTAssertFalse(failingMessage.contains("snapshot."), "Interpolation non résolue : \(failingMessage)")
    }

    /// Aucun message d'éligibilité ne doit contenir un nom de propriété Swift.
    func testNoEligibilityMessageLeaksAPropertyPath() {
        let snapshot = EntitlementSnapshot(
            tier: .basic, source: .appStore, period: nil, status: .active, expiresAt: nil
        )
        let all: [PurchaseEligibility] = [
            .allowed, .checkingServer, .backendUnavailable,
            .existingBackendEntitlement(snapshot),
            .existingLocalAppStoreEntitlement(.premium), .serverVerificationUnavailable
        ]
        for case let eligibility in all {
            XCTAssertFalse(eligibility.userMessage.contains("snapshot."), "\(eligibility)")
        }
    }
}
