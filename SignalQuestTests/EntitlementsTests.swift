import XCTest
import StoreKit
import SwiftUI
import UIKit
@testable import SignalQuest

final class SubscriptionPriceCopyTests: XCTestCase {
    func testEquivalentUsesActualRenewalPeriodAndStorefrontCurrency() throws {
        let price = try XCTUnwrap(Decimal(string: "79.99"))
        let monthly = try XCTUnwrap(SubscriptionPriceCopy.monthlyAmount(price: price, unit: .year, value: 1))
        let euros = monthly.formatted(Decimal.FormatStyle.Currency(code: "EUR", locale: Locale(identifier: "fr_FR")))
        let dollars = monthly.formatted(Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US")))
        XCTAssertTrue(euros.contains("6,67") && euros.contains("€"), euros)
        XCTAssertTrue(dollars.contains("6.67") && dollars.contains("$"), dollars)

        let yen = try XCTUnwrap(SubscriptionPriceCopy.monthlyAmount(price: 12000, unit: .year, value: 1))
            .formatted(Decimal.FormatStyle.Currency(code: "JPY", locale: Locale(identifier: "ja_JP")))
        XCTAssertTrue(yen.contains("1,000") && !yen.contains(".00"), yen)
    }

    func testNoInventedMonthlyEquivalentOrWrongBillingPeriod() {
        XCTAssertNil(SubscriptionPriceCopy.monthlyAmount(price: 3, unit: .month, value: 1))
        XCTAssertNil(SubscriptionPriceCopy.monthlyAmount(price: 10, unit: .week, value: 1))
        XCTAssertNil(SubscriptionPriceCopy.monthlyAmount(price: 10, unit: .year, value: 0))
        XCTAssertEqual(SubscriptionPriceCopy.monthlyAmount(price: 30, unit: .month, value: 3), 10)
        XCTAssertEqual(SubscriptionPriceCopy.monthlyAmount(price: 240, unit: .year, value: 2), 10)
        XCTAssertTrue(SubscriptionPriceCopy.matchesSelection(.month, value: 1, selection: .monthly))
        XCTAssertTrue(SubscriptionPriceCopy.matchesSelection(.year, value: 1, selection: .annual))
        XCTAssertFalse(SubscriptionPriceCopy.matchesSelection(.year, value: 1, selection: .monthly))
        XCTAssertFalse(SubscriptionPriceCopy.matchesSelection(.month, value: 3, selection: .annual))
    }
}

final class EntitlementsTests: XCTestCase {
    func testProductCatalogSellsPremiumOnly() {
        XCTAssertEqual(
            Set(SignalQuestSubscriptionProduct.allCases.map(\.rawValue)),
            Set([
                "fr.signalquest.ios.premium.monthly",
                "fr.signalquest.ios.premium.annual",
            ])
        )
        XCTAssertNil(
            SignalQuestSubscriptionProduct.product(tier: .basic, period: .monthly),
            "Basic est supprimé dans App Store Connect (D2) : aucun achat Basic ne doit partir"
        )
        XCTAssertEqual(
            SignalQuestSubscriptionProduct.product(tier: .premium, period: .annual),
            .premiumAnnual
        )
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
        XCTAssertEqual(snapshot.subscription?.channel, .stripe)
        XCTAssertEqual(snapshot.subscription?.autoRenew, true)
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
        let subscription = try XCTUnwrap(snapshot.subscription)
        XCTAssertEqual(subscription.state, .onHold)
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .available(snapshot),
                localTier: .free,
                purchasesEnabled: true,
                serverVerificationReady: true
            ),
            .managedElsewhere(subscription)
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
        XCTAssertNil(snapshot.subscription)
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

    func testActiveBackendPurchaseStillBlocksIfResolvedTierIsTemporarilyInconsistent() throws {
        let snapshot = EntitlementSnapshot(response: try decodeResponse("""
        {
          "tier": "free",
          "purchases": [{
            "id": "purchase-3", "provider": "stripe", "tier": "premium", "status": "active",
            "cancelAtPeriodEnd": false, "currentPeriodEnd": null, "expiresAt": null, "startsAt": null
          }]
        }
        """))
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(
                serverState: .available(snapshot),
                localTier: .free,
                purchasesEnabled: true,
                serverVerificationReady: true
            ),
            .managedElsewhere(try XCTUnwrap(snapshot.subscription))
        )
    }

    func testBillingEndpointsAreCanonicalAPIPaths() {
        XCTAssertEqual(EntitlementsStore.entitlementsEndpoint, "/api/me/entitlements")
        XCTAssertEqual(EntitlementsStore.subscriptionEndpoint, "/api/billing/subscription")
    }

    // MARK: - Contrat v1 §3

    /// L'exemple du contrat v1 §3, servi par `GET /api/me/entitlements`.
    func testContractPayloadDecodesEveryField() throws {
        let snapshot = EntitlementSnapshot(response: try decodeResponse(Self.contractPayload))
        XCTAssertEqual(snapshot.tier, .premium)
        XCTAssertEqual(snapshot.source, .appStore)
        XCTAssertEqual(snapshot.status, .active)
        XCTAssertEqual(snapshot.period, .monthly)
        XCTAssertNotNil(snapshot.expiresAt)
        let subscription = try XCTUnwrap(snapshot.subscription)
        XCTAssertEqual(subscription.channel, .appStore)
        XCTAssertEqual(subscription.state, .active)
        XCTAssertEqual(subscription.autoRenew, false)
        XCTAssertTrue(subscription.entitled)
        XCTAssertEqual(subscription.productKey, "premium_monthly")
        XCTAssertEqual(subscription.price, EntitlementSubscription.Price(unitAmount: 799, currency: "EUR"))
        XCTAssertFalse(subscription.isSandbox)
        XCTAssertEqual(subscription.manage?.url?.absoluteString, "https://apps.apple.com/account/subscriptions")
        XCTAssertEqual(subscription.manage?.canCancel, false)
        XCTAssertEqual(subscription.manage?.canResume, true)
        XCTAssertEqual(snapshot.trial, EntitlementTrial(eligible: false, days: 7))
        XCTAssertEqual(snapshot.purchaseAccountToken, UUID(uuidString: "6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B"))
        XCTAssertEqual(snapshot.benefits?.premium.first, "sentinelle.full")
        XCTAssertEqual(snapshot.benefits?.free.count, 4)
        XCTAssertEqual(snapshot.warnings, [])
        XCTAssertNil(snapshot.grant)
    }

    /// Une build publiée doit survivre à un champ mal formé : seul `tier` est
    /// obligatoire, le reste se lit au mieux.
    func testContractPayloadSurvivesMalformedFields() throws {
        let response = try decodeResponse("""
        {
          "version": 1,
          "tier": "premium",
          "subscription": {
            "channel": "app_store", "state": "frozen", "tier": "premium", "period": 12,
            "autoRenew": "yes", "currentPeriodEnd": "pas une date", "manage": 3, "price": { "unitAmount": "7,99" }
          },
          "otherSubscriptions": [42, { "channel": "stripe", "state": "active", "tier": "premium" }],
          "warnings": ["PAYMENT_ISSUE", 7],
          "grant": "oui",
          "trial": { "eligible": "true" },
          "purchaseAccountToken": "pas-un-uuid",
          "benefits": { "premium": ["sentinelle.full", null] }
        }
        """)
        let snapshot = EntitlementSnapshot(response: response)
        XCTAssertEqual(snapshot.tier, .premium)
        let subscription = try XCTUnwrap(snapshot.subscription)
        XCTAssertEqual(subscription.state, .unknown)
        XCTAssertNil(subscription.period)
        XCTAssertNil(subscription.autoRenew)
        XCTAssertNil(subscription.currentPeriodEnd)
        XCTAssertNil(subscription.manage)
        XCTAssertNil(subscription.price)
        XCTAssertEqual(snapshot.otherSubscriptions.map(\.channel), [.stripe])
        XCTAssertEqual(snapshot.warnings, ["PAYMENT_ISSUE"])
        XCTAssertNil(snapshot.grant)
        XCTAssertEqual(snapshot.trial?.eligible, false)
        XCTAssertNil(snapshot.purchaseAccountToken)
        XCTAssertEqual(snapshot.benefits?.premium, ["sentinelle.full"])
        XCTAssertEqual(snapshot.benefits?.free, [])
        // Un état inconnu de cette build compte comme un abonnement en cours.
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(serverState: .available(snapshot), localTier: .free,
                                               purchasesEnabled: true, serverVerificationReady: true),
            .managedByAppStore(subscription)
        )
    }

    func testMissingTierStillFailsTheWholeResponse() {
        XCTAssertThrowsError(try decodeResponse(#"{ "version": 1, "subscription": null }"#))
    }

    /// M1 : une offre en cours renvoie vers sa gestion, un abonnement terminé ou
    /// un accès offert laissent acheter.
    func testEligibilityFollowsSubscriptionStateAndChannel() throws {
        func eligibility(_ channel: String, _ state: String, tier: String = "premium") throws -> PurchaseEligibility {
            let snapshot = EntitlementSnapshot(response: try decodeResponse("""
            { "version": 1, "tier": "\(tier)",
              "subscription": { "channel": "\(channel)", "state": "\(state)", "tier": "premium" } }
            """))
            return PurchaseEligibilityPolicy.evaluate(serverState: .available(snapshot), localTier: .free,
                                                      purchasesEnabled: true, serverVerificationReady: true)
        }
        for state in ["trialing", "active", "grace", "on_hold", "paused", "pending"] {
            if case .managedByAppStore = try eligibility("app_store", state) {} else { XCTFail("App Store \(state)") }
            if case .managedElsewhere = try eligibility("google_play", state) {} else { XCTFail("Play \(state)") }
            if case .managedElsewhere = try eligibility("stripe", state) {} else { XCTFail("Stripe \(state)") }
        }
        for state in ["expired", "revoked"] {
            XCTAssertEqual(try eligibility("app_store", state, tier: "free"), .allowed, state)
            XCTAssertEqual(try eligibility("stripe", state, tier: "free"), .allowed, state)
        }

        let granted = EntitlementSnapshot(response: try decodeResponse("""
        { "version": 1, "tier": "premium", "subscription": null,
          "grant": { "source": "promo", "tier": "premium", "expiresAt": "2026-12-01T00:00:00Z" } }
        """))
        XCTAssertEqual(granted.source, .manual)
        XCTAssertEqual(granted.grant?.tier, .premium)
        XCTAssertNotNil(granted.expiresAt)
        XCTAssertEqual(
            PurchaseEligibilityPolicy.evaluate(serverState: .available(granted), localTier: .free,
                                               purchasesEnabled: true, serverVerificationReady: true),
            .allowed,
            "Un accès offert n'empêche pas de s'abonner pour la suite"
        )
    }

    func testOtherPaidSubscriptionAlsoBlocks() throws {
        let snapshot = EntitlementSnapshot(response: try decodeResponse("""
        { "version": 1, "tier": "free", "subscription": null,
          "otherSubscriptions": [{ "channel": "google_play", "state": "active", "tier": "premium" }] }
        """))
        if case .managedElsewhere = PurchaseEligibilityPolicy.evaluate(
            serverState: .available(snapshot), localTier: .free, purchasesEnabled: true, serverVerificationReady: true
        ) {} else { XCTFail("Un abonnement payé ailleurs doit bloquer l'achat") }
    }

    /// Règles 2.3.10 et 3.1.1 : aucun message ne nomme une autre plateforme ni
    /// un autre moyen de paiement.
    func testEligibilityMessagesNeverNameAnotherPlatform() {
        var messages: [String] = []
        for channel in [EntitlementSubscription.Channel.appStore, .googlePlay, .stripe, .unknown] {
            for state in [EntitlementSubscription.State.trialing, .active, .grace, .onHold, .paused, .pending, .unknown] {
                let subscription = EntitlementSubscription(channel: channel, state: state, tier: .premium)
                messages.append(PurchaseEligibility.managedByAppStore(subscription).userMessage)
                messages.append(PurchaseEligibility.managedElsewhere(subscription).userMessage)
            }
        }
        messages += [
            PurchaseEligibility.allowed, .checkingServer, .backendUnavailable,
            .existingLocalAppStoreEntitlement(.premium), .serverVerificationUnavailable,
        ].map(\.userMessage)
        messages += [EntitlementSource.googlePlay, .stripe, .unknown].map(\.displayName)
        for message in messages {
            for forbidden in ["Google", "Android", "Play", "Stripe", "snapshot.", "subscription."] {
                XCTAssertFalse(message.contains(forbidden), "« \(forbidden) » dans : \(message)")
            }
        }
    }

    func testKnowsAppStoreSubscriptionWithinOneSecond() throws {
        let snapshot = EntitlementSnapshot(response: try decodeResponse("""
        { "version": 1, "tier": "premium",
          "subscription": { "channel": "app_store", "state": "active", "tier": "premium",
                            "currentPeriodEnd": "2026-12-14T01:05:00Z" },
          "otherSubscriptions": [{ "channel": "stripe", "state": "active", "tier": "premium",
                                   "currentPeriodEnd": "2027-01-01T00:00:00Z" }] }
        """))
        let end = try XCTUnwrap(SQDateParsing.parse("2026-12-14T01:05:00Z"))
        XCTAssertTrue(snapshot.knowsAppStoreSubscription(expiringAt: end.addingTimeInterval(0.4)))
        XCTAssertFalse(snapshot.knowsAppStoreSubscription(expiringAt: end.addingTimeInterval(30 * 86_400)),
                       "Un renouvellement inconnu du serveur doit être renvoyé")
        XCTAssertFalse(snapshot.knowsAppStoreSubscription(expiringAt: SQDateParsing.parse("2027-01-01T00:00:00Z")),
                       "Un abonnement d'un autre canal ne vaut pas livraison App Store")
        XCTAssertFalse(snapshot.knowsAppStoreSubscription(expiringAt: nil))
    }

    /// Contrat v1.14 §5 : même échéance, mais un renouvellement StoreKit différent
    /// de celui servi (résiliation dans la feuille d'Apple, ou `autoRenew` encore
    /// inconnu du serveur) appelle un renvoi.
    func testKnowsAppStoreSubscriptionComparesTheServedRenewal() throws {
        func snapshot(autoRenew: String) throws -> EntitlementSnapshot {
            EntitlementSnapshot(response: try decodeResponse("""
            { "version": 1, "tier": "premium",
              "subscription": { "channel": "app_store", "state": "active", "tier": "premium",
                                "autoRenew": \(autoRenew), "currentPeriodEnd": "2026-12-14T01:05:00Z" } }
            """))
        }
        let end = try XCTUnwrap(SQDateParsing.parse("2026-12-14T01:05:00Z"))
        let renewing = try snapshot(autoRenew: "true")
        XCTAssertTrue(renewing.knowsAppStoreSubscription(expiringAt: end, willAutoRenew: true))
        XCTAssertFalse(renewing.knowsAppStoreSubscription(expiringAt: end, willAutoRenew: false),
                       "Une résiliation faite chez Apple doit être renvoyée")
        XCTAssertTrue(try snapshot(autoRenew: "false").knowsAppStoreSubscription(expiringAt: end, willAutoRenew: false))

        let unknown = try snapshot(autoRenew: "null")
        XCTAssertFalse(unknown.knowsAppStoreSubscription(expiringAt: end, willAutoRenew: true),
                       "Un renouvellement inconnu du serveur doit lui être envoyé")
        XCTAssertTrue(unknown.knowsAppStoreSubscription(expiringAt: end),
                      "Sans renouvellement lu dans StoreKit, l'échéance suffit, comme avant")
    }

    // MARK: - Livraison des transactions (codes des routes d'achat)

    func testOnlyALinkToAnotherAccountFinishesAFailedDelivery() {
        func http(_ status: Int, _ code: String?) -> APIError {
            .http(status: status, code: code, message: "", requestId: nil, retryAfter: nil)
        }
        XCTAssertEqual(AppStoreDeliveryFailure(http(409, "PURCHASE_ALREADY_LINKED")), .finish)
        XCTAssertEqual(AppStoreDeliveryFailure(http(409, "SUBSCRIPTION_ALREADY_ACTIVE")), .finish)
        for error in [
            http(401, nil), http(401, "APPLE_VERIFY_FAILED"), http(403, "BILLING_TESTERS_ONLY"),
            http(409, nil), http(422, "PURCHASE_PROOF_INVALID"), http(422, "UNKNOWN_PRODUCT"),
            http(503, "BILLING_UNCONFIGURED"), http(503, "APPLE_BILLING_UNCONFIGURED"),
            http(503, "STORE_UNAVAILABLE"), http(500, nil),
        ] {
            XCTAssertEqual(AppStoreDeliveryFailure(error), .keepForRetry, "\(error)")
        }
        XCTAssertEqual(AppStoreDeliveryFailure(APIError.transport("offline: x")), .keepForRetry)
        XCTAssertEqual(AppStoreDeliveryFailure(URLError(.timedOut)), .keepForRetry)
    }

    /// R10 : un 5xx n'affiche jamais le texte du serveur ; seul un libellé local
    /// par code dit à l'acheteur que son paiement n'est pas perdu.
    func testBillingCodesShowALocalMessageEvenOnServerErrors() {
        let generic = APIError.statusFallback(503)
        for (status, code) in [(503, "BILLING_UNCONFIGURED"), (503, "APPLE_BILLING_UNCONFIGURED"),
                               (503, "STORE_UNAVAILABLE"), (422, "PURCHASE_PROOF_INVALID"),
                               (401, "APPLE_VERIFY_FAILED"), (422, "UNKNOWN_PRODUCT"),
                               (403, "BILLING_TESTERS_ONLY"), (409, "PURCHASE_ALREADY_LINKED")] {
            let error = APIError.http(status: status, code: code, message: "Trace interne", requestId: nil, retryAfter: nil)
            let message = AppStoreDeliveryFailure.activationMessage(for: error)
            XCTAssertNotEqual(message, generic, code)
            XCTAssertNotEqual(message, APIError.statusFallback(status), code)
            XCTAssertFalse(message.contains("Trace interne"), code)
        }
        let unmapped = AppStoreDeliveryFailure.activationMessage(for: URLError(.notConnectedToInternet))
        XCTAssertFalse(unmapped.isEmpty)
        XCTAssertNotEqual(unmapped, generic)
    }

    // MARK: - Lecture des droits

    @MainActor
    func testRefreshFallsBackToLegacyRouteOn404AndRemembersIt() async {
        let previousUserID = LocalAccountScope.currentUserId
        defer {
            LocalAccountScope.deactivate()
            if let previousUserID { LocalAccountScope.activate(userId: previousUserID) }
        }
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: "entitlement-fallback-\(UUID().uuidString)")

        let api = RecordingEntitlementsAPIStub(contractRouteServed: false)
        let store = EntitlementsStore(api: api, observesTransactions: false)
        await store.refreshBackendSnapshot()
        XCTAssertEqual(store.confirmedServerTier, .premium)
        await store.refreshBackendSnapshot()
        XCTAssertEqual(api.paths, [
            EntitlementsStore.entitlementsEndpoint,
            EntitlementsStore.subscriptionEndpoint,
            EntitlementsStore.subscriptionEndpoint,
        ], "Après un 404, l'ancienne route seule jusqu'au prochain lancement")
    }

    @MainActor
    func testRefreshReadsTheContractRouteWhenServed() async throws {
        let previousUserID = LocalAccountScope.currentUserId
        defer {
            LocalAccountScope.deactivate()
            if let previousUserID { LocalAccountScope.activate(userId: previousUserID) }
        }
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: "entitlement-contract-\(UUID().uuidString)")

        let api = RecordingEntitlementsAPIStub(contractRouteServed: true)
        let store = EntitlementsStore(api: api, observesTransactions: false)
        await store.refreshBackendSnapshot()
        XCTAssertEqual(api.paths, [EntitlementsStore.entitlementsEndpoint])
        let snapshot = try XCTUnwrap(store.serverState.snapshot)
        XCTAssertEqual(snapshot.subscription?.channel, .appStore)
        XCTAssertEqual(store.confirmedServerTier, .premium)
        if case .managedByAppStore = store.eligibility {} else { XCTFail("\(store.eligibility)") }
    }

    @MainActor
    func testPremiumSnapshotAndOperationDoNotFollowAccountAfterLogout() async {
        let previousUserID = LocalAccountScope.currentUserId
        defer {
            LocalAccountScope.deactivate()
            if let previousUserID { LocalAccountScope.activate(userId: previousUserID) }
        }

        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: "entitlement-A-\(UUID().uuidString)")
        let store = EntitlementsStore(api: AccountScopedSubscriptionAPIStub(), observesTransactions: false)
        await store.refreshBackendSnapshot()
        XCTAssertEqual(store.confirmedServerTier, .premium)
        await store.purchase(.premiumMonthly)
        guard case .managedByAppStore = store.eligibility else {
            return XCTFail("L'abonnement App Store en cours doit renvoyer vers sa gestion : \(store.eligibility)")
        }
        XCTAssertEqual(store.operation, .failed(store.eligibility.userMessage),
                       "Le droit déjà actif doit bloquer un second achat")

        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: "entitlement-B-\(UUID().uuidString)")
        XCTAssertEqual(store.serverState, .idle)
        XCTAssertEqual(store.confirmedServerTier, .free)
        XCTAssertEqual(store.operation, .idle)
        await store.refreshBackendSnapshot()
        XCTAssertEqual(store.confirmedServerTier, .free)
    }

    @MainActor
    func testPurchaseWithoutAccountDoesNotStartStoreKitOperation() async {
        let previousUserID = LocalAccountScope.currentUserId
        defer {
            LocalAccountScope.deactivate()
            if let previousUserID { LocalAccountScope.activate(userId: previousUserID) }
        }

        LocalAccountScope.deactivate()
        let store = EntitlementsStore(api: AccountScopedSubscriptionAPIStub(), observesTransactions: false)
        await store.purchase(.premiumMonthly)
        XCTAssertEqual(store.operation, .idle)
    }

    private func decodeResponse(_ json: String) throws -> BillingSubscriptionResponse {
        try JSONDecoder.signalQuest.decode(BillingSubscriptionResponse.self, from: Data(json.utf8))
    }

    static let contractPayload = """
    {
      "version": 1,
      "serverTime": "2026-11-14T01:05:00Z",
      "tier": "premium",
      "tierSource": "subscription",
      "subscription": {
        "id": "c1",
        "channel": "app_store",
        "productKey": "premium_monthly",
        "tier": "premium",
        "period": "month",
        "state": "active",
        "entitled": true,
        "autoRenew": false,
        "currentPeriodEnd": "2026-12-14T01:05:00Z",
        "graceEndsAt": null,
        "resumesAt": null,
        "trialEndsAt": null,
        "pendingChange": null,
        "price": { "unitAmount": 799, "currency": "eur" },
        "environment": "production",
        "manage": {
          "kind": "app_store",
          "url": "https://apps.apple.com/account/subscriptions",
          "canCancel": false,
          "canResume": true
        }
      },
      "otherSubscriptions": [],
      "warnings": [],
      "grant": null,
      "trial": { "eligible": false, "days": 7 },
      "purchaseAccountToken": "6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b",
      "quotas": { "radioLogCells": { "used": 3211, "max": 10000 } },
      "benefits": {
        "free": ["radio.kpi_history", "exports.nsg_market", "radio_log.sync", "sentinelle.lite"],
        "premium": ["sentinelle.full", "stories.duration", "radio_log.unlimited",
                    "reports.logo", "recap.monthly", "profile.spotlight"]
      },
      "features": { "pro.sentinelle.enabled": true },
      "flagTiers": { "feature.radio.kpi": "free" }
    }
    """

    // MARK: - Interpolations

    /// Aucun message d'éligibilité ne doit contenir un nom de propriété Swift.
    func testNoEligibilityMessageLeaksAPropertyPath() {
        let subscription = EntitlementSubscription(channel: .appStore, state: .grace, tier: .premium)
        let all: [PurchaseEligibility] = [
            .allowed, .checkingServer, .backendUnavailable,
            .managedByAppStore(subscription), .managedElsewhere(subscription),
            .existingLocalAppStoreEntitlement(.premium), .serverVerificationUnavailable
        ]
        for case let eligibility in all {
            XCTAssertFalse(eligibility.userMessage.contains("snapshot."), "\(eligibility)")
            XCTAssertFalse(eligibility.userMessage.contains("\\("), "\(eligibility)")
        }
    }
}


/// Lot B : ce que l'écran Premium affiche de l'abonnement servi (contrat v1 §3).
final class SubscriptionStatusPresentationTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1_798_000_000)

    private func present(_ subscription: EntitlementSubscription, warnings: [String] = []) -> SubscriptionStatusPresentation {
        let snapshot = EntitlementSnapshot(
            tier: subscription.entitled ? subscription.tier : .free,
            source: subscription.channel.source, period: subscription.period,
            status: subscription.entitled ? .active : .inactive, expiresAt: subscription.currentPeriodEnd,
            subscription: subscription, warnings: warnings
        )
        return SubscriptionStatusPresentation.make(serverState: .available(snapshot))
    }

    func testEveryStateHasAStatusLine() {
        let states: [EntitlementSubscription.State] = [.pending, .trialing, .active, .grace, .onHold, .paused, .expired, .revoked]
        for state in states {
            let presentation = present(EntitlementSubscription(
                channel: .appStore, state: state, tier: .premium, autoRenew: true, currentPeriodEnd: end
            ))
            XCTAssertNotNil(presentation.tag, "\(state)")
            XCTAssertFalse(presentation.details.isEmpty, "\(state)")
        }
    }

    /// D5 et D8 : la feuille Apple gère tout abonnement App Store en cours ;
    /// un abonnement terminé ou remboursé n'offre plus rien à gérer.
    func testAppStoreManagementFollowsTheState() {
        func management(_ state: EntitlementSubscription.State, autoRenew: Bool = true) -> SubscriptionStatusPresentation.Management {
            present(EntitlementSubscription(channel: .appStore, state: state, tier: .premium,
                                            autoRenew: autoRenew, currentPeriodEnd: end)).management
        }
        XCTAssertEqual(management(.active), .appStore(canResume: false, canRequestRefund: true))
        XCTAssertEqual(management(.active, autoRenew: false), .appStore(canResume: true, canRequestRefund: true))
        XCTAssertEqual(management(.trialing), .appStore(canResume: false, canRequestRefund: false))
        XCTAssertEqual(management(.trialing, autoRenew: false), .appStore(canResume: true, canRequestRefund: false))
        XCTAssertEqual(management(.grace), .appStore(canResume: false, canRequestRefund: true))
        XCTAssertEqual(management(.onHold), .appStore(canResume: false, canRequestRefund: true))
        XCTAssertEqual(management(.expired), .none)
        XCTAssertEqual(management(.revoked), .none)
    }

    /// 2.3.10 et 3.1.1 : un abonnement pris ailleurs se décrit en texte seul,
    /// sans nommer de plateforme.
    func testOtherChannelsAreTextOnlyAndNameNoPlatform() {
        let forbidden = ["Google", "Android", "Play", "Stripe"]
        for channel in [EntitlementSubscription.Channel.stripe, .googlePlay, .unknown] {
            let presentation = present(EntitlementSubscription(
                channel: channel, state: .active, tier: .premium, autoRenew: true, currentPeriodEnd: end
            ), warnings: ["DUPLICATE_PAID_SUBSCRIPTION"])
            guard case .elsewhere(let line) = presentation.management else {
                return XCTFail("\(channel) doit rester en texte seul")
            }
            for text in [line, presentation.title] + presentation.details + [presentation.tag ?? ""] {
                for word in forbidden {
                    XCTAssertFalse(text.contains(word), "« \(text) » nomme \(word)")
                }
            }
        }
    }

    func testDuplicateSubscriptionWarningTurnsTheCardIntoAWarning() {
        let presentation = present(EntitlementSubscription(
            channel: .appStore, state: .active, tier: .premium, autoRenew: true, currentPeriodEnd: end
        ), warnings: ["DUPLICATE_PAID_SUBSCRIPTION"])
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.details.count, 2)
    }

    func testCancelledSubscriptionSaysItStopsWithoutPayment() {
        let presentation = present(EntitlementSubscription(
            channel: .appStore, state: .active, tier: .premium, autoRenew: false, currentPeriodEnd: end
        ))
        XCTAssertEqual(presentation.tag, String(localized: "Résilié"))
        XCTAssertEqual(presentation.details, [
            String(localized: "Premium reste actif jusqu’au \(SubscriptionStatusPresentation.day(end)), puis s’arrête sans nouveau paiement.")
        ])
    }

    func testTrialLineNamesTheBillingPeriod() {
        let price = EntitlementSubscription.Price(unitAmount: 7_999, currency: "EUR")
        let annual = present(EntitlementSubscription(
            channel: .appStore, state: .trialing, tier: .premium, period: .annual, autoRenew: true,
            currentPeriodEnd: end, trialEndsAt: end, price: price
        ))
        let formatted = SubscriptionStatusPresentation.formattedPrice(price)
        XCTAssertEqual(annual.details, [
            String(localized: "Essai gratuit jusqu’au \(SubscriptionStatusPresentation.day(end)), puis \(formatted) par an.")
        ])
    }

    /// Le serveur sert `autoRenew: null` pour Apple tant qu'il ne lit pas `renewalInfo` :
    /// aucun renouvellement n'est alors promis, puisqu'il serait faux après une résiliation.
    func testUnknownRenewalPromisesNoRenewal() {
        let presentation = present(EntitlementSubscription(
            channel: .appStore, state: .active, tier: .premium, autoRenew: nil, currentPeriodEnd: end
        ))
        XCTAssertEqual(presentation.tag, String(localized: "Actif"))
        XCTAssertEqual(presentation.details, [
            String(localized: "Période en cours jusqu’au \(SubscriptionStatusPresentation.day(end)).")
        ])
    }

    func testSandboxPurchaseIsLabelled() {
        let presentation = present(EntitlementSubscription(
            channel: .appStore, state: .active, tier: .premium, autoRenew: true, currentPeriodEnd: end, isSandbox: true
        ))
        XCTAssertEqual(presentation.details.last, String(localized: "Achat de test : aucun paiement réel."))
    }

    func testGrantAndFreeTierWithoutSubscription() {
        let granted = SubscriptionStatusPresentation.make(serverState: .available(EntitlementSnapshot(
            tier: .premium, source: .manual, period: nil, status: .active, expiresAt: end,
            grant: EntitlementGrant(tier: .premium, expiresAt: end)
        )))
        XCTAssertEqual(granted.tag, String(localized: "Offert"))
        XCTAssertEqual(granted.management, .none)

        let free = SubscriptionStatusPresentation.make(serverState: .available(EntitlementSnapshot(
            tier: .free, source: .backend, period: nil, status: .inactive, expiresAt: nil
        )))
        XCTAssertNil(free.tag)
        XCTAssertEqual(free.management, .none)

        let down = SubscriptionStatusPresentation.make(serverState: .unavailable("x"))
        XCTAssertEqual(down.tone, .warning)
        XCTAssertEqual(down.management, .none)
    }

    /// Unité mineure (contrat v1.8) : 799 centimes d'euro, 1 200 yens sans décimale.
    func testPriceUsesTheCurrencyMinorUnit() {
        let euros = SubscriptionStatusPresentation.formattedPrice(.init(unitAmount: 799, currency: "EUR"))
        XCTAssertTrue(euros.contains("7") && euros.contains("99"), euros)
        let yens = SubscriptionStatusPresentation.formattedPrice(.init(unitAmount: 1_200, currency: "JPY"))
        XCTAssertTrue(yens.filter(\.isNumber) == "1200", yens)
    }

    /// D3 : l'essai ne s'annonce que si le serveur et l'App Store le permettent
    /// tous deux, et que l'offre est bien gratuite.
    func testFreeTrialNeedsServerAndStoreKitAgreement() {
        let eligible = EntitlementTrial(eligible: true, days: 7)
        XCTAssertTrue(FreeTrialRule.shows(serverTrial: eligible, storeKitEligible: true, offerIsFreeTrial: true))
        XCTAssertFalse(FreeTrialRule.shows(serverTrial: nil, storeKitEligible: true, offerIsFreeTrial: true))
        XCTAssertFalse(FreeTrialRule.shows(serverTrial: EntitlementTrial(eligible: false, days: 7),
                                           storeKitEligible: true, offerIsFreeTrial: true))
        XCTAssertFalse(FreeTrialRule.shows(serverTrial: eligible, storeKitEligible: false, offerIsFreeTrial: true))
        XCTAssertFalse(FreeTrialRule.shows(serverTrial: eligible, storeKitEligible: true, offerIsFreeTrial: false))
    }
}


/// Lot D : suppression de compte avec un abonnement payé en cours (contrat
/// abonnements v1, D4).
@MainActor
final class AccountDeletionSubscriptionTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1_798_000_000)

    func testTheAppDeclaresItReadsTheConflict() {
        XCTAssertTrue(ClientProtocolContract.capabilities.contains("billing_subscription_aware_v1"))
    }

    func testOnlyRunningSubscriptionsAreWarnedAbout() {
        let snapshot = EntitlementSnapshot(
            tier: .premium, source: .appStore, period: .monthly, status: .active, expiresAt: end,
            subscription: EntitlementSubscription(channel: .appStore, state: .active, tier: .premium, autoRenew: true),
            otherSubscriptions: [
                EntitlementSubscription(channel: .stripe, state: .expired, tier: .premium),
                EntitlementSubscription(channel: .googlePlay, state: .grace, tier: .premium),
            ]
        )
        XCTAssertEqual(AccountDeletionSubscriptionNotice.running(in: snapshot).map(\.channel), [.appStore, .googlePlay])
        XCTAssertTrue(AccountDeletionSubscriptionNotice.running(in: nil).isEmpty)
    }

    /// Le serveur résilie le web et l'autre magasin, jamais l'App Store ; aucun
    /// texte ne nomme une autre plateforme (2.3.10).
    func testEachChannelSaysWhatHappensAndNamesNoOtherPlatform() {
        let appStore = AccountDeletionSubscriptionNotice.message(for: EntitlementSubscription(
            channel: .appStore, state: .active, tier: .premium, autoRenew: true))
        XCTAssertTrue(appStore.contains("Apple"))
        let cancelled = AccountDeletionSubscriptionNotice.message(for: EntitlementSubscription(
            channel: .appStore, state: .active, tier: .premium, autoRenew: false, currentPeriodEnd: end))
        XCTAssertTrue(cancelled.contains(SubscriptionStatusPresentation.day(end)))
        XCTAssertNotEqual(appStore, cancelled)

        for channel in [EntitlementSubscription.Channel.stripe, .googlePlay, .unknown] {
            let message = AccountDeletionSubscriptionNotice.message(for: EntitlementSubscription(
                channel: channel, state: .active, tier: .premium, autoRenew: true))
            for word in ["Google", "Android", "Play", "Stripe"] {
                XCTAssertFalse(message.contains(word), "\(channel) : « \(message) » nomme \(word)")
            }
        }
    }

    /// Le 409 arrive avant la vérification de la preuve : la confirmation suivante
    /// l'acquitte, avec la même preuve.
    func testAConflictIsAcknowledgedOnTheNextConfirmation() async throws {
        defer { LocalAccountScope.deactivate() }
        LocalAccountScope.activate(userId: "deletion-A")
        let service = DeletionRecordingUserService()
        let model = SettingsViewModel(userService: service, authService: MockAuthService())

        let first = await model.deleteAccount(using: .password("secret"))
        XCTAssertFalse(first)
        XCTAssertTrue(model.deletionSubscriptionConflict)
        XCTAssertEqual(model.deletionError, APIError.http(status: 409, code: "ACTIVE_PAID_SUBSCRIPTION", message: "",
                                                          requestId: nil, retryAfter: nil).userFacingMessage)

        let second = await model.deleteAccount(using: .password("secret"))
        XCTAssertTrue(second)
        XCTAssertEqual(service.acknowledgements, [false, true])
    }

    func testAWarningShownUpFrontIsAcknowledgedAtOnce() async {
        defer { LocalAccountScope.deactivate() }
        LocalAccountScope.activate(userId: "deletion-B")
        let service = DeletionRecordingUserService()
        let model = SettingsViewModel(userService: service, authService: MockAuthService())
        let succeeded = await model.deleteAccount(using: .password("secret"), acknowledgingActiveSubscriptions: true)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(service.acknowledgements, [true])
    }
}

/// Refuse la première suppression non acquittée par un 409, comme le serveur
/// quand un abonnement payé est en cours.
private final class DeletionRecordingUserService: UserServicing, @unchecked Sendable {
    enum Unused: Error { case notImplemented }
    private(set) var acknowledgements: [Bool] = []

    func deleteAccount(using proof: AccountDeletionProof, expectedSession: LocalAccountSession,
                       acknowledgingActiveSubscriptions: Bool) async throws -> AccountDeletionResult {
        acknowledgements.append(acknowledgingActiveSubscriptions)
        guard acknowledgingActiveSubscriptions else {
            throw APIError.http(status: 409, code: "ACTIVE_PAID_SUBSCRIPTION", message: "Abonnement en cours",
                                requestId: nil, retryAfter: nil)
        }
        return try JSONDecoder().decode(AccountDeletionResult.self,
            from: Data(#"{"success":true,"reauthMethod":"password","message":"ok"}"#.utf8))
    }

    func exportPersonalData() async throws -> Data { throw Unused.notImplemented }
    func profile() async throws -> AuthUser { throw Unused.notImplemented }
    func updateProfile(_ patch: UserProfilePatch) async throws -> AuthUser { throw Unused.notImplemented }
    func checkHandleAvailability(_ handle: String) async throws -> HandleAvailability { throw Unused.notImplemented }
    func checkPublicHandleAvailability(_ handle: String) async throws -> HandleAvailability { throw Unused.notImplemented }
    func uploadAvatar(data: Data, filename: String, mimeType: String) async throws -> AuthUser { throw Unused.notImplemented }
    func stats() async throws -> UserStats { throw Unused.notImplemented }
    func notificationPreferences() async throws -> NotificationPreferences { throw Unused.notImplemented }
    func updateNotificationPreferences(_ prefs: NotificationPreferences) async throws -> NotificationPreferences { throw Unused.notImplemented }
    func heartbeat() async throws { throw Unused.notImplemented }
    func accountDeletionPreview() async throws -> AccountDeletionPreview { throw Unused.notImplemented }
    func requestAccountDeletionEmailCode() async throws -> AccountDeletionEmailChallenge { throw Unused.notImplemented }
    func deleteAccount(using proof: AccountDeletionProof) async throws -> AccountDeletionResult { throw Unused.notImplemented }
}

private final class AccountScopedSubscriptionAPIStub: APIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
        if endpoint.path == EntitlementsStore.entitlementsEndpoint {
            throw APIError.http(status: 404, code: nil, message: "", requestId: nil, retryAfter: nil)
        }
        guard endpoint.path == EntitlementsStore.subscriptionEndpoint else {
            throw URLError(.badURL)
        }
        let read = lock.withLock { reads += 1; return reads }
        let json = read == 1
            ? #"{"tier":"premium","purchases":[{"id":"p1","provider":"apple_appstore","tier":"premium","status":"active","cancelAtPeriodEnd":false,"currentPeriodEnd":null,"expiresAt":null,"startsAt":null}]}"#
            : #"{"tier":"free","purchases":[]}"#
        return try JSONDecoder.signalQuest.decode(type, from: Data(json.utf8))
    }

    func request(_ endpoint: APIEndpoint) async throws { throw URLError(.badURL) }

    func uploadMultipart<T: Decodable>(
        path: String, fields: [String: String], fileField: String,
        fileName: String, mimeType: String, data: Data, as type: T.Type
    ) async throws -> T { throw URLError(.badURL) }
}

/// Relève les routes lues ; sert le §3 ou répond 404 comme un serveur d'avant le lot 1b.
private final class RecordingEntitlementsAPIStub: APIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let contractRouteServed: Bool

    init(contractRouteServed: Bool) { self.contractRouteServed = contractRouteServed }

    var paths: [String] { lock.withLock { recorded } }

    func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
        lock.withLock { recorded.append(endpoint.path) }
        switch endpoint.path {
        case EntitlementsStore.entitlementsEndpoint:
            guard contractRouteServed else {
                throw APIError.http(status: 404, code: nil, message: "", requestId: nil, retryAfter: nil)
            }
            return try JSONDecoder.signalQuest.decode(type, from: Data(EntitlementsTests.contractPayload.utf8))
        case EntitlementsStore.subscriptionEndpoint:
            return try JSONDecoder.signalQuest.decode(type, from: Data(#"{"tier":"premium","purchases":[]}"#.utf8))
        default:
            throw URLError(.badURL)
        }
    }

    func request(_ endpoint: APIEndpoint) async throws { throw URLError(.badURL) }

    func uploadMultipart<T: Decodable>(
        path: String, fields: [String: String], fileField: String,
        fileName: String, mimeType: String, data: Data, as type: T.Type
    ) async throws -> T { throw URLError(.badURL) }
}

/// Rendus de l'écran Premium et de l'avertissement de suppression, pour une
/// relecture à l'œil (lot E). Écrits seulement si `SQ_PAYWALL_RENDER_OUT` est
/// donné (`TEST_RUNNER_SQ_PAYWALL_RENDER_OUT` à xcodebuild) ; sinon ignorés.
/// La charge §3 telle que le serveur la sert depuis le 14/11 à 12:54 (lot 1b,
/// `buildEntitlementsV1`) : champs inconnus de l'app (`serverTime`, `tierSource`,
/// `id`, `manage.kind`, `quotas`, `features`, `flagTiers`) et champs encore à
/// null (`autoRenew` Apple, `price`, `trialEndsAt`) compris.
@MainActor
final class ServedEntitlementsPayloadTests: XCTestCase {
    private static let premiumAppStore = #"""
    {"version":1,"serverTime":"2026-11-14T12:00:00.000Z","tier":"premium","tierSource":"subscription",
     "subscription":{"id":"cm1","channel":"app_store","productKey":"premium_monthly","tier":"premium","period":"month",
       "state":"active","entitled":true,"autoRenew":null,"currentPeriodEnd":"2026-12-14T11:00:00.000Z",
       "graceEndsAt":null,"resumesAt":null,"trialEndsAt":null,"pendingChange":null,"price":null,"environment":"sandbox",
       "manage":{"kind":"app_store","url":"https://apps.apple.com/account/subscriptions","canCancel":true,"canResume":false}},
     "otherSubscriptions":[],"warnings":[],"grant":null,"trial":{"eligible":false,"days":7},
     "purchaseAccountToken":"0b6f8f62-5a0e-4c62-9d36-8a4f1f4a7c11",
     "quotas":{"radioLogCells":{"used":120,"max":null},"sentinelle":{"usedTargets":1,"maxTargets":5,"defaultIntervalSec":60,
       "allowedIntervalsSec":[60,30,10],"maxFastTargets":1,"detailDays":14,"rollupDays":400,"incidentFastMode":true,"weeklyReport":true}},
     "benefits":{"free":["radio.kpi_history","exports.nsg_market","radio_log.sync"],
                 "premium":["sentinelle.full","stories.duration","radio_log.unlimited","reports.logo"]},
     "features":{"pro.sentinelle.enabled":true},"flagTiers":{"pro.sentinelle.enabled":"premium"}}
    """#

    private static let free = #"""
    {"version":1,"serverTime":"2026-11-14T12:00:00.000Z","tier":"free","tierSource":"none","subscription":null,
     "otherSubscriptions":[],"warnings":[],"grant":null,"trial":{"eligible":true,"days":7},
     "purchaseAccountToken":"0b6f8f62-5a0e-4c62-9d36-8a4f1f4a7c12",
     "quotas":{"radioLogCells":{"used":0,"max":10000},"sentinelle":{"usedTargets":0,"maxTargets":1,"defaultIntervalSec":300,
       "allowedIntervalsSec":[300],"maxFastTargets":0,"detailDays":7,"rollupDays":90,"incidentFastMode":false,"weeklyReport":false}},
     "benefits":{"free":["radio.kpi_history"],"premium":["sentinelle.full","stories.duration"]},
     "features":{},"flagTiers":{"pro.sentinelle.enabled":"premium"}}
    """#

    private var previousUserID: String?

    override func setUp() async throws {
        previousUserID = LocalAccountScope.currentUserId
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: "served-entitlements-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        LocalAccountScope.deactivate()
        if let previousUserID { LocalAccountScope.activate(userId: previousUserID) }
    }

    private func snapshot(_ payload: String) async throws -> EntitlementSnapshot {
        let store = EntitlementsStore(api: FixedEntitlementsAPIStub(payload: payload), observesTransactions: false)
        await store.refreshBackendSnapshot()
        return try XCTUnwrap(store.serverState.snapshot)
    }

    func testAServedAppStoreSubscriptionIsReadAsIs() async throws {
        let snapshot = try await snapshot(Self.premiumAppStore)
        XCTAssertEqual(snapshot.tier, .premium)
        XCTAssertEqual(snapshot.source, .appStore)
        XCTAssertTrue(snapshot.status.grantsAccess)
        XCTAssertEqual(snapshot.subscription?.state, .active)
        XCTAssertNil(snapshot.subscription?.autoRenew)
        XCTAssertNil(snapshot.subscription?.price)
        XCTAssertEqual(snapshot.subscription?.isSandbox, true)
        XCTAssertNotNil(snapshot.subscription?.currentPeriodEnd)
        XCTAssertNotNil(snapshot.purchaseAccountToken)
        XCTAssertEqual(snapshot.trial?.eligible, false)
        XCTAssertEqual(snapshot.benefits?.premium.contains("sentinelle.full"), true)
        // Un abonnement en cours bloque un second achat (M1), même sans `autoRenew`.
        XCTAssertNotNil(snapshot.blockingSubscription)

        let presentation = SubscriptionStatusPresentation.make(serverState: .available(snapshot))
        let end = try XCTUnwrap(snapshot.subscription?.currentPeriodEnd)
        XCTAssertEqual(presentation.tag, String(localized: "Actif"))
        XCTAssertEqual(presentation.details, [
            String(localized: "Période en cours jusqu’au \(SubscriptionStatusPresentation.day(end))."),
            String(localized: "Achat de test : aucun paiement réel."),
        ])
        XCTAssertFalse(SentinellePremiumOffer.isOffered(snapshot, tier: snapshot.tier))
        // Suppression : l'avertissement App Store et le bouton de gestion restent.
        XCTAssertEqual(AccountDeletionSubscriptionNotice.running(in: snapshot).count, 1)
    }

    func testAServedFreeAccountGetsTheOffers() async throws {
        let snapshot = try await snapshot(Self.free)
        XCTAssertEqual(snapshot.tier, .free)
        XCTAssertNil(snapshot.subscription)
        XCTAssertEqual(snapshot.trial?.eligible, true)
        XCTAssertTrue(SentinellePremiumOffer.isOffered(snapshot, tier: snapshot.tier))
        XCTAssertTrue(AccountDeletionSubscriptionNotice.running(in: snapshot).isEmpty)
    }
}

@MainActor
final class PaywallRenderingHarness: XCTestCase {
    private static let states: [(String, String)] = [
        ("1-gratuit", #"{"version":1,"tier":"free","subscription":null,"trial":{"eligible":true,"days":7},"benefits":{"free":[],"premium":["sentinelle.full","stories.duration"]}}"#),
        ("2-essai-app-store", #"{"version":1,"tier":"premium","subscription":{"channel":"app_store","state":"trialing","tier":"premium","period":"year","autoRenew":true,"currentPeriodEnd":"2026-11-21T10:00:00Z","trialEndsAt":"2026-11-21T10:00:00Z","price":{"unitAmount":7999,"currency":"EUR"},"environment":"sandbox"}}"#),
        ("3-resilie-app-store", #"{"version":1,"tier":"premium","subscription":{"channel":"app_store","state":"active","tier":"premium","period":"month","autoRenew":false,"currentPeriodEnd":"2026-12-14T10:00:00Z","price":{"unitAmount":799,"currency":"EUR"}}}"#),
        ("4-paiement-a-regulariser", #"{"version":1,"tier":"premium","subscription":{"channel":"app_store","state":"grace","tier":"premium","period":"month","autoRenew":true,"currentPeriodEnd":"2026-11-10T10:00:00Z","graceEndsAt":"2026-11-26T10:00:00Z"}}"#),
        ("5-autre-canal-doublon", #"{"version":1,"tier":"premium","subscription":{"channel":"stripe","state":"active","tier":"premium","period":"month","autoRenew":true,"currentPeriodEnd":"2026-12-01T10:00:00Z"},"otherSubscriptions":[{"channel":"google_play","state":"active","tier":"premium","period":"year","autoRenew":true}],"warnings":["DUPLICATE_PAID_SUBSCRIPTION"]}"#),
    ]

    func testRenderPaywallStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SQ_PAYWALL_RENDER_OUT"] else {
            throw XCTSkip("SQ_PAYWALL_RENDER_OUT absent : rendus non demandés")
        }
        let previousUserID = LocalAccountScope.currentUserId
        defer {
            LocalAccountScope.deactivate()
            if let previousUserID { LocalAccountScope.activate(userId: previousUserID) }
        }
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: "paywall-render-\(UUID().uuidString)")

        for (name, payload) in Self.states {
            let store = EntitlementsStore(api: FixedEntitlementsAPIStub(payload: payload), observesTransactions: false)
            await store.refreshBackendSnapshot()
            XCTAssertNotNil(store.serverState.snapshot, name)
            try await write(NavigationStack { PaywallView(store: store) }, to: directory, name: "paywall-\(name)")
            if name == "5-autre-canal-doublon" || name == "3-resilie-app-store" {
                try await write(AccountDeletionSubscriptionNotice(store: store).padding(16).frame(maxHeight: .infinity, alignment: .top),
                                to: directory, name: "suppression-\(name)")
            }
            // Entrées Premium de Sentinelle (maquette R10, D27) : visibles en gratuit,
            // absentes pour un Premium.
            if name == "1-gratuit" || name == "2-essai-app-store" {
                let paused = try JSONDecoder.signalQuest.decode(SentinelleTarget.self, from: Data(
                    #"{"id":"t2","label":"Bureau","status":"up","isActive":false,"intervalSec":60,"pausedReason":"plan"}"#.utf8))
                let offers = VStack(alignment: .leading, spacing: 16) {
                    SentinellePremiumOffer(store: store, style: .card) {}
                    SentinellePremiumOffer(store: store, style: .link(String(localized: "Mesurer chaque minute avec Premium"))) {}
                    SentinelleSuspendedNote(target: paused)
                    SentinellePremiumOffer(store: store, style: .link(String(localized: "Tout surveiller avec Premium"))) {}
                }
                try await write(offers.padding(16).frame(maxHeight: .infinity, alignment: .top),
                                to: directory, name: "sentinelle-\(name)")
            }
        }
    }

    /// Une fenêtre réelle : `ImageRenderer` ne dessine pas le contenu d'une `ScrollView`.
    /// À la taille de l'écran : une fenêtre plus haute décale le contenu d'une `ScrollView`.
    private func write<V: View>(_ view: V, to directory: String, name: String) async throws {
        // Une fenêtre sans scène ne dessine rien : on emprunte celle de l'app hôte.
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Une scène UIKit active est nécessaire pour les rendus")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "fr_FR")))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        // Rend la main : le `.task` de l'écran relit les droits, puis les
        // animations d'apparition se terminent.
        try await Task.sleep(for: .seconds(2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        previousKeyWindow?.makeKey()
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

private final class FixedEntitlementsAPIStub: APIClientProtocol, @unchecked Sendable {
    let payload: String
    init(payload: String) { self.payload = payload }

    func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
        guard endpoint.path == EntitlementsStore.entitlementsEndpoint else { throw URLError(.badURL) }
        return try JSONDecoder.signalQuest.decode(type, from: Data(payload.utf8))
    }

    func request(_ endpoint: APIEndpoint) async throws { throw URLError(.badURL) }

    func uploadMultipart<T: Decodable>(
        path: String, fields: [String: String], fileField: String,
        fileName: String, mimeType: String, data: Data, as type: T.Type
    ) async throws -> T { throw URLError(.badURL) }
}
