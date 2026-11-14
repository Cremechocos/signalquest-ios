import XCTest
import StoreKit
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
