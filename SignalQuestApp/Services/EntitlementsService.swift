import Foundation
import StoreKit

// MARK: - Product catalog

enum SupporterTier: String, Codable, CaseIterable, Sendable {
    case free
    case basic
    case premium

    var rank: Int {
        switch self {
        case .free: return 0
        case .basic: return 1
        case .premium: return 2
        }
    }

    var displayName: String {
        switch self {
        case .free: return "Gratuit"
        case .basic: return "Basic"
        case .premium: return "Premium"
        }
    }

    static func highest(_ lhs: SupporterTier, _ rhs: SupporterTier) -> SupporterTier {
        lhs.rank >= rhs.rank ? lhs : rhs
    }
}

enum SubscriptionBillingPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case monthly
    case annual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monthly: return "Mensuel"
        case .annual: return "Annuel"
        }
    }
}

/// Identifiants qui devront être créés à l'identique dans App Store Connect.
/// Ils sont centralisés et testés pour éviter toute dérive entre le paywall et
/// la vérification serveur future.
enum SignalQuestSubscriptionProduct: String, CaseIterable, Identifiable, Sendable {
    case basicMonthly = "fr.signalquest.ios.basic.monthly"
    case basicAnnual = "fr.signalquest.ios.basic.annual"
    case premiumMonthly = "fr.signalquest.ios.premium.monthly"
    case premiumAnnual = "fr.signalquest.ios.premium.annual"

    var id: String { rawValue }

    var tier: SupporterTier {
        switch self {
        case .basicMonthly, .basicAnnual: return .basic
        case .premiumMonthly, .premiumAnnual: return .premium
        }
    }

    var period: SubscriptionBillingPeriod {
        switch self {
        case .basicMonthly, .premiumMonthly: return .monthly
        case .basicAnnual, .premiumAnnual: return .annual
        }
    }

    /// Prix produit retenu. StoreKit reste la source d'affichage dès qu'un
    /// produit App Store Connect est chargé ; cette valeur sert seulement à
    /// présenter honnêtement l'offre planifiée avant activation du catalogue.
    var plannedDisplayPrice: String {
        switch self {
        case .basicMonthly: return "2,99 € / mois"
        case .basicAnnual: return "29,99 € / an"
        case .premiumMonthly: return "7,99 € / mois"
        case .premiumAnnual: return "79,99 € / an"
        }
    }

    static func product(tier: SupporterTier, period: SubscriptionBillingPeriod) -> Self? {
        allCases.first { $0.tier == tier && $0.period == period }
    }
}

// MARK: - Canonical entitlement snapshot

enum EntitlementSource: String, Codable, Sendable {
    case appStore = "apple_appstore"
    case googlePlay = "google_play"
    case stripe
    case manual
    case backend
    case unknown

    init(provider: String?) {
        switch provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple_appstore", "app_store", "appstore", "apple": self = .appStore
        case "google_play", "play_store", "google": self = .googlePlay
        case "stripe": self = .stripe
        case "manual", "admin": self = .manual
        case nil, "": self = .backend
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .appStore: return "App Store"
        case .googlePlay: return "Google Play"
        case .stripe: return "SignalQuest Web"
        case .manual: return "SignalQuest"
        case .backend: return "SignalQuest"
        case .unknown: return "une autre plateforme"
        }
    }
}

enum EntitlementPaymentStatus: String, Codable, Sendable {
    case active
    case paymentFailed = "past_due"
    case canceled
    case expired
    case inactive
    case unknown

    init(backendValue: String?) {
        switch backendValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "trialing": self = .active
        case "past_due", "unpaid", "payment_failed": self = .paymentFailed
        case "canceled", "cancelled": self = .canceled
        case "expired": self = .expired
        case nil, "": self = .inactive
        default: self = .unknown
        }
    }

    var grantsAccess: Bool { self == .active }
}

struct EntitlementSnapshot: Equatable, Sendable {
    let tier: SupporterTier
    let source: EntitlementSource
    let period: SubscriptionBillingPeriod?
    let status: EntitlementPaymentStatus
    let expiresAt: Date?

    static let free = EntitlementSnapshot(
        tier: .free,
        source: .backend,
        period: nil,
        status: .inactive,
        expiresAt: nil
    )
}

struct BillingSubscriptionResponse: Decodable, Sendable {
    let tier: SupporterTier
    let purchases: [BillingPurchase]
}

struct BillingPurchase: Decodable, Equatable, Sendable {
    let id: String
    let provider: String
    let tier: SupporterTier
    let status: String
    let cancelAtPeriodEnd: Bool?
    let currentPeriodEnd: Date?
    let expiresAt: Date?
    let startsAt: Date?
}

extension EntitlementSnapshot {
    init(response: BillingSubscriptionResponse) {
        let rankedPurchases = response.purchases.sorted { lhs, rhs in
            if lhs.tier.rank != rhs.tier.rank { return lhs.tier.rank > rhs.tier.rank }
            let lhsActive = EntitlementPaymentStatus(backendValue: lhs.status).grantsAccess
            let rhsActive = EntitlementPaymentStatus(backendValue: rhs.status).grantsAccess
            if lhsActive != rhsActive { return lhsActive }
            return (lhs.expiresAt ?? lhs.currentPeriodEnd ?? .distantPast)
                > (rhs.expiresAt ?? rhs.currentPeriodEnd ?? .distantPast)
        }

        guard let purchase = rankedPurchases.first else {
            self.init(
                tier: response.tier,
                source: response.tier == .free ? .backend : .manual,
                period: nil,
                status: response.tier == .free ? .inactive : .active,
                expiresAt: nil
            )
            return
        }

        let paymentStatus = EntitlementPaymentStatus(backendValue: purchase.status)
        self.init(
            // Le tier résolu par le backend reste canonique. En cas de paiement
            // échoué il doit déjà être `free`, conformément à la règle produit.
            tier: response.tier,
            source: EntitlementSource(provider: purchase.provider),
            // L'API actuelle ne renvoie ni intervalle ni productId : ne pas
            // l'inférer à partir des dates, qui peuvent inclure prorata/grâce.
            period: nil,
            status: paymentStatus,
            expiresAt: purchase.expiresAt ?? purchase.currentPeriodEnd
        )
    }
}

enum ServerEntitlementState: Equatable, Sendable {
    case idle
    case loading
    case available(EntitlementSnapshot)
    case unavailable(String)

    var snapshot: EntitlementSnapshot? {
        guard case .available(let snapshot) = self else { return nil }
        return snapshot
    }
}

// MARK: - Duplicate-subscription policy

enum PurchaseEligibility: Equatable, Sendable {
    case allowed
    case checkingServer
    case backendUnavailable
    case existingBackendEntitlement(EntitlementSnapshot)
    case existingLocalAppStoreEntitlement(SupporterTier)
    case serverVerificationUnavailable

    var canPurchase: Bool { self == .allowed }

    var userMessage: String {
        switch self {
        case .allowed:
            return "Achat disponible."
        case .checkingServer:
            return "Vérification de tes droits en cours…"
        case .backendUnavailable:
            return "Impossible de vérifier tes abonnements existants. Aucun achat n'est proposé pour éviter une double facturation."
        case .existingBackendEntitlement(let snapshot):
            if snapshot.status == .paymentFailed {
                return "Un abonnement (snapshot.source.displayName) nécessite une action de paiement. Résous-le sur la plateforme d'origine avant de souscrire ailleurs."
            }
            return "Ton abonnement (snapshot.tier.displayName) est déjà géré par (snapshot.source.displayName). Gère-le sur cette plateforme pour éviter un doublon."
        case .existingLocalAppStoreEntitlement:
            return "Un achat App Store est détecté sur cet appareil, mais son activation serveur n'est pas encore confirmée."
        case .serverVerificationUnavailable:
            return "Les achats App Store seront ouverts après validation serveur en staging. Aucun débit ne peut être lancé pour le moment."
        }
    }
}

struct PurchaseEligibilityPolicy {
    static func evaluate(
        serverState: ServerEntitlementState,
        localTier: SupporterTier,
        purchasesEnabled: Bool,
        serverVerificationReady: Bool
    ) -> PurchaseEligibility {
        switch serverState {
        case .idle, .loading:
            return .checkingServer
        case .unavailable:
            return .backendUnavailable
        case .available(let snapshot):
            if snapshot.tier != .free
                || snapshot.status == .paymentFailed
                || (snapshot.status == .active && snapshot.source != .backend) {
                return .existingBackendEntitlement(snapshot)
            }
        }

        if localTier != .free {
            return .existingLocalAppStoreEntitlement(localTier)
        }
        guard purchasesEnabled, serverVerificationReady else {
            return .serverVerificationUnavailable
        }
        return .allowed
    }
}

// MARK: - StoreKit delivery boundary

/// Preuve minimale attendue par le futur endpoint de validation Apple. Le JWS
/// complet est indispensable : le backend ne devra jamais faire confiance aux
/// seuls identifiants fournis par le client.
struct AppStoreTransactionProof: Encodable, Sendable {
    let signedTransaction: String
    let productId: String
    let transactionId: String
    let originalTransactionId: String
}

protocol AppStoreTransactionSyncing: Sendable {
    func synchronize(_ proof: AppStoreTransactionProof) async throws -> EntitlementSnapshot
}

enum StoreKitOperationState: Equatable, Sendable {
    case idle
    case purchasing(SignalQuestSubscriptionProduct)
    case restoring
    case pending
    case succeeded(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .purchasing, .restoring: return true
        default: return false
        }
    }
}

enum EntitlementsError: LocalizedError {
    case failedVerification
    case productUnavailable
    case unexpectedProduct
    case transactionDeliveryUnavailable

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "La transaction App Store n'a pas pu être authentifiée."
        case .productUnavailable:
            return "Cette offre n'est pas disponible dans l'App Store."
        case .unexpectedProduct:
            return "La transaction reçue ne correspond pas à l'offre choisie."
        case .transactionDeliveryUnavailable:
            return "La validation serveur App Store n'est pas encore disponible."
        }
    }
}

@MainActor
final class EntitlementsStore: ObservableObject {
    nonisolated static let subscriptionEndpoint = "/api/billing/subscription"

    @Published private(set) var products: [SignalQuestSubscriptionProduct: Product] = [:]
    @Published private(set) var productLoadMessage: String?
    @Published private(set) var serverState: ServerEntitlementState = .idle
    @Published private(set) var localEntitlementTier: SupporterTier = .free
    @Published private(set) var operation: StoreKitOperationState = .idle

    private let api: APIClientProtocol
    private let purchasesEnabled: Bool
    private let serverVerificationEnabled: Bool
    private let synchronizer: AppStoreTransactionSyncing?
    private var updatesTask: Task<Void, Never>?

    init(
        api: APIClientProtocol,
        purchasesEnabled: Bool = SQFeatures.storeKitPurchasesEnabled,
        serverVerificationEnabled: Bool = SQFeatures.storeKitServerVerificationEnabled,
        synchronizer: AppStoreTransactionSyncing? = nil,
        observesTransactions: Bool = true
    ) {
        self.api = api
        self.purchasesEnabled = purchasesEnabled
        self.serverVerificationEnabled = serverVerificationEnabled
        self.synchronizer = synchronizer

        if observesTransactions {
            updatesTask = Task { @MainActor [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { return }
                    await self?.handleTransactionUpdate(result)
                }
            }
        }
    }

    deinit { updatesTask?.cancel() }

    var serverVerificationReady: Bool {
        serverVerificationEnabled && synchronizer != nil
    }

    var eligibility: PurchaseEligibility {
        PurchaseEligibilityPolicy.evaluate(
            serverState: serverState,
            localTier: localEntitlementTier,
            purchasesEnabled: purchasesEnabled,
            serverVerificationReady: serverVerificationReady
        )
    }

    var activeTier: SupporterTier {
        SupporterTier.highest(serverState.snapshot?.tier ?? .free, localEntitlementTier)
    }

    /// Seul le snapshot serveur peut autoriser une fonctionnalité payante : un
    /// achat local non livré ne doit jamais contourner le contrôle backend.
    var confirmedServerTier: SupporterTier {
        guard let snapshot = serverState.snapshot, snapshot.status.grantsAccess else { return .free }
        return snapshot.tier
    }

    func product(for tier: SupporterTier, period: SubscriptionBillingPeriod) -> Product? {
        guard let identifier = SignalQuestSubscriptionProduct.product(tier: tier, period: period) else { return nil }
        return products[identifier]
    }

    func prepare() async {
        await refreshBackendSnapshot()
        await refreshStoreKitState()
    }

    func refreshBackendSnapshot() async {
        serverState = .loading
        do {
            let response = try await api.request(
                APIEndpoint(path: Self.subscriptionEndpoint),
                as: BillingSubscriptionResponse.self
            )
            serverState = .available(EntitlementSnapshot(response: response))
        } catch {
            serverState = .unavailable(error.localizedDescription)
        }
    }

    func refreshStoreKitState() async {
        await loadProducts()
        await refreshLocalEntitlements()
    }

    func purchase(_ identifier: SignalQuestSubscriptionProduct) async {
        let currentEligibility = eligibility
        guard currentEligibility.canPurchase else {
            operation = .failed(currentEligibility.userMessage)
            return
        }
        guard let product = products[identifier] else {
            operation = .failed(EntitlementsError.productUnavailable.localizedDescription)
            return
        }
        guard let synchronizer else {
            operation = .failed(EntitlementsError.transactionDeliveryUnavailable.localizedDescription)
            return
        }

        operation = .purchasing(identifier)
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                guard transaction.productID == identifier.rawValue else {
                    throw EntitlementsError.unexpectedProduct
                }
                let snapshot = try await synchronizer.synchronize(Self.proof(for: verification, transaction: transaction))
                serverState = .available(snapshot)
                await transaction.finish()
                await refreshLocalEntitlements()
                operation = .succeeded("Abonnement (snapshot.tier.displayName) activé sur ton compte.")
            case .pending:
                operation = .pending
            case .userCancelled:
                operation = .idle
            @unknown default:
                operation = .failed("Réponse App Store inconnue. Réessaie plus tard.")
            }
        } catch {
            operation = .failed(error.localizedDescription)
        }
    }

    /// Restaure les transactions Apple puis tente leur livraison au backend.
    /// Sans synchroniseur serveur, la restauration locale reste visible mais
    /// aucun droit multiplateforme n'est prétendu comme actif.
    func restorePurchases() async {
        operation = .restoring
        do {
            try await AppStore.sync()
            await refreshLocalEntitlements()
            if serverVerificationReady {
                try await synchronizeCurrentEntitlements()
            }
            await refreshBackendSnapshot()
            if localEntitlementTier != .free, !serverVerificationReady {
                operation = .failed(PurchaseEligibility.existingLocalAppStoreEntitlement(localEntitlementTier).userMessage)
            } else {
                operation = .succeeded("Achats restaurés et droits vérifiés.")
            }
        } catch {
            operation = .failed(error.localizedDescription)
        }
    }

    func clearOperationMessage() {
        guard !operation.isBusy else { return }
        operation = .idle
    }

    private func loadProducts() async {
        do {
            let loaded = try await Product.products(for: SignalQuestSubscriptionProduct.allCases.map(\.rawValue))
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in
                guard let identifier = SignalQuestSubscriptionProduct(rawValue: product.id) else { return nil }
                return (identifier, product)
            })
            productLoadMessage = products.isEmpty
                ? "Catalogue App Store non configuré pour cette version."
                : nil
        } catch {
            products = [:]
            productLoadMessage = "Catalogue App Store indisponible : \(error.localizedDescription)"
        }
    }

    private func refreshLocalEntitlements() async {
        var highestTier = SupporterTier.free
        let now = Date()
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.verified(result),
                  let identifier = SignalQuestSubscriptionProduct(rawValue: transaction.productID),
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded,
                  transaction.expirationDate.map({ $0 > now }) ?? true
            else { continue }
            highestTier = SupporterTier.highest(highestTier, identifier.tier)
        }
        localEntitlementTier = highestTier
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? Self.verified(result),
              SignalQuestSubscriptionProduct(rawValue: transaction.productID) != nil
        else { return }

        await refreshLocalEntitlements()
        guard let synchronizer, serverVerificationEnabled else {
            operation = .failed(PurchaseEligibility.existingLocalAppStoreEntitlement(localEntitlementTier).userMessage)
            return
        }
        do {
            let snapshot = try await synchronizer.synchronize(Self.proof(for: result, transaction: transaction))
            serverState = .available(snapshot)
            await transaction.finish()
        } catch {
            // Ne pas terminer la transaction : StoreKit la rejouera quand la
            // livraison backend sera de nouveau disponible.
            operation = .failed(error.localizedDescription)
        }
    }

    private func synchronizeCurrentEntitlements() async throws {
        guard let synchronizer, serverVerificationEnabled else {
            throw EntitlementsError.transactionDeliveryUnavailable
        }
        for await result in Transaction.currentEntitlements {
            let transaction = try Self.verified(result)
            guard SignalQuestSubscriptionProduct(rawValue: transaction.productID) != nil else { continue }
            let snapshot = try await synchronizer.synchronize(Self.proof(for: result, transaction: transaction))
            serverState = .available(snapshot)
            await transaction.finish()
        }
    }

    nonisolated private static func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw EntitlementsError.failedVerification
        }
    }

    nonisolated private static func proof(
        for result: VerificationResult<Transaction>,
        transaction: Transaction
    ) -> AppStoreTransactionProof {
        AppStoreTransactionProof(
            signedTransaction: result.jwsRepresentation,
            productId: transaction.productID,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID)
        )
    }
}
