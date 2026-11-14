import Foundation
import StoreKit
import os

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
        case .free: return String(localized: "Gratuit")
        case .basic: return "Basic"
        case .premium: return "Premium"
        }
    }

    static func highest(_ lhs: SupporterTier, _ rhs: SupporterTier) -> SupporterTier {
        lhs.rank >= rhs.rank ? lhs : rhs
    }

    /// Lecture tolérante d'un palier servi à l'intérieur d'un abonnement : une
    /// valeur inconnue vaut `free`, jamais un droit deviné.
    init(serverValue: String?) {
        switch serverValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "premium": self = .premium
        case "basic": self = .basic
        default: self = .free
        }
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

    /// `period` du contrat v1 (`month`, `year`) ; l'ancien vocabulaire passe aussi.
    init?(serverValue: String?) {
        switch serverValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "month", "monthly": self = .monthly
        case "year", "annual", "yearly": self = .annual
        default: return nil
        }
    }
}

/// Offres vendues sur iOS, à l'identique d'App Store Connect : Premium seul
/// depuis le 14/11 (décision D2). Les identifiants Basic y ont été supprimés et
/// ne peuvent plus servir ; `SupporterTier.basic` reste lisible pour un droit
/// Basic servi par le serveur (offert, ou souscrit avant la décision).
enum SignalQuestSubscriptionProduct: String, CaseIterable, Identifiable, Sendable {
    case premiumMonthly = "fr.signalquest.ios.premium.monthly"
    case premiumAnnual = "fr.signalquest.ios.premium.annual"

    var id: String { rawValue }

    var tier: SupporterTier { .premium }

    var period: SubscriptionBillingPeriod {
        switch self {
        case .premiumMonthly: return .monthly
        case .premiumAnnual: return .annual
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

    /// Nom montré à l'écran. L'app iOS ne nomme aucune autre plateforme mobile
    /// (règle App Review 2.3.10) : un abonnement pris hors de l'App Store est
    /// « souscrit sur un autre appareil » (contrat v1 §3, D5).
    var displayName: String {
        switch self {
        case .appStore: return "App Store"
        case .googlePlay, .unknown: return String(localized: "un autre appareil")
        case .stripe: return String(localized: "le web")
        case .manual, .backend: return "SignalQuest"
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

/// Abonnement décrit par le serveur (contrat v1 §3). Tout y est facultatif sauf
/// le canal et l'état, qui ont une valeur de repli : une build publiée doit
/// survivre à un champ ajouté, retiré ou mal formé sans perdre le reste.
struct EntitlementSubscription: Decodable, Equatable, Sendable {
    enum Channel: String, Sendable {
        case appStore = "app_store"
        case googlePlay = "google_play"
        case stripe
        case unknown

        init(serverValue: String?) {
            switch EntitlementSource(provider: serverValue) {
            case .appStore: self = .appStore
            case .googlePlay: self = .googlePlay
            case .stripe: self = .stripe
            case .manual, .backend, .unknown: self = .unknown
            }
        }

        var source: EntitlementSource {
            switch self {
            case .appStore: return .appStore
            case .googlePlay: return .googlePlay
            case .stripe: return .stripe
            case .unknown: return .unknown
            }
        }
    }

    /// États du contrat v1 §2.
    enum State: String, Sendable {
        case pending
        case trialing
        case active
        case grace
        case onHold = "on_hold"
        case paused
        case expired
        case revoked
        /// État absent ou inconnu de cette build.
        case unknown

        /// Droit ouvert : essai, payé (même résilié) ou délai de grâce.
        var grantsAccess: Bool {
            switch self {
            case .trialing, .active, .grace: return true
            default: return false
            }
        }

        /// Un nouvel achat ferait doublon tant que l'abonnement n'est pas fini.
        /// Un état inconnu compte comme en cours : mieux vaut renvoyer vers sa
        /// gestion que risquer un double paiement.
        var blocksNewPurchase: Bool {
            switch self {
            case .expired, .revoked: return false
            default: return true
            }
        }
    }

    struct Manage: Equatable, Sendable {
        let url: URL?
        let canCancel: Bool
        let canResume: Bool
    }

    struct PendingChange: Equatable, Sendable {
        let productKey: String?
        let effectiveAt: Date?
    }

    /// Prix par période en vigueur, en unité mineure (contrat v1.8).
    struct Price: Equatable, Sendable {
        let unitAmount: Int
        let currency: String
    }

    let channel: Channel
    let state: State
    let tier: SupporterTier
    let period: SubscriptionBillingPeriod?
    let productKey: String?
    let entitled: Bool
    let autoRenew: Bool?
    let currentPeriodEnd: Date?
    let graceEndsAt: Date?
    let resumesAt: Date?
    let trialEndsAt: Date?
    let pendingChange: PendingChange?
    let price: Price?
    let isSandbox: Bool
    let manage: Manage?

    init(
        channel: Channel,
        state: State,
        tier: SupporterTier,
        period: SubscriptionBillingPeriod? = nil,
        productKey: String? = nil,
        entitled: Bool? = nil,
        autoRenew: Bool? = nil,
        currentPeriodEnd: Date? = nil,
        graceEndsAt: Date? = nil,
        resumesAt: Date? = nil,
        trialEndsAt: Date? = nil,
        pendingChange: PendingChange? = nil,
        price: Price? = nil,
        isSandbox: Bool = false,
        manage: Manage? = nil
    ) {
        self.channel = channel
        self.state = state
        self.tier = tier
        self.period = period
        self.productKey = productKey
        self.entitled = entitled ?? state.grantsAccess
        self.autoRenew = autoRenew
        self.currentPeriodEnd = currentPeriodEnd
        self.graceEndsAt = graceEndsAt
        self.resumesAt = resumesAt
        self.trialEndsAt = trialEndsAt
        self.pendingChange = pendingChange
        self.price = price
        self.isSandbox = isSandbox
        self.manage = manage
    }

    private enum CodingKeys: String, CodingKey {
        case channel, state, tier, period, productKey, entitled, autoRenew, currentPeriodEnd
        case graceEndsAt, resumesAt, trialEndsAt, pendingChange, price, environment, manage
    }

    private enum ManageKeys: String, CodingKey { case url, canCancel, canResume }
    private enum PendingChangeKeys: String, CodingKey { case productKey, effectiveAt }
    private enum PriceKeys: String, CodingKey { case unitAmount, currency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let state = (try? c.decodeIfPresent(String.self, forKey: .state))
            .flatMap { State(rawValue: $0.lowercased()) } ?? .unknown

        var manage: Manage?
        if let m = try? c.nestedContainer(keyedBy: ManageKeys.self, forKey: .manage) {
            manage = Manage(
                url: (try? m.decodeIfPresent(String.self, forKey: .url)).flatMap { URL(string: $0) },
                canCancel: (try? m.decodeIfPresent(Bool.self, forKey: .canCancel)) ?? false,
                canResume: (try? m.decodeIfPresent(Bool.self, forKey: .canResume)) ?? false
            )
        }
        var pendingChange: PendingChange?
        if let p = try? c.nestedContainer(keyedBy: PendingChangeKeys.self, forKey: .pendingChange) {
            pendingChange = PendingChange(
                productKey: try? p.decodeIfPresent(String.self, forKey: .productKey),
                effectiveAt: try? p.decodeIfPresent(Date.self, forKey: .effectiveAt)
            )
        }
        var price: Price?
        if let p = try? c.nestedContainer(keyedBy: PriceKeys.self, forKey: .price),
           let amount = try? p.decodeIfPresent(Int.self, forKey: .unitAmount),
           let currency = try? p.decodeIfPresent(String.self, forKey: .currency), !currency.isEmpty {
            price = Price(unitAmount: amount, currency: currency.uppercased())
        }

        self.init(
            channel: Channel(serverValue: try? c.decodeIfPresent(String.self, forKey: .channel)),
            state: state,
            tier: SupporterTier(serverValue: try? c.decodeIfPresent(String.self, forKey: .tier)),
            period: SubscriptionBillingPeriod(serverValue: try? c.decodeIfPresent(String.self, forKey: .period)),
            productKey: try? c.decodeIfPresent(String.self, forKey: .productKey),
            entitled: try? c.decodeIfPresent(Bool.self, forKey: .entitled),
            autoRenew: try? c.decodeIfPresent(Bool.self, forKey: .autoRenew),
            currentPeriodEnd: try? c.decodeIfPresent(Date.self, forKey: .currentPeriodEnd),
            graceEndsAt: try? c.decodeIfPresent(Date.self, forKey: .graceEndsAt),
            resumesAt: try? c.decodeIfPresent(Date.self, forKey: .resumesAt),
            trialEndsAt: try? c.decodeIfPresent(Date.self, forKey: .trialEndsAt),
            pendingChange: pendingChange,
            price: price,
            isSandbox: (try? c.decodeIfPresent(String.self, forKey: .environment))?.lowercased() == "sandbox",
            manage: manage
        )
    }

    /// Achat de l'ancienne route (`purchases[]`, statuts `active` et `past_due`
    /// seulement), ramené à la forme du §3 pour une seule politique d'achat.
    init(legacyPurchase purchase: BillingPurchase, resolvedTier: SupporterTier) {
        let state: State
        switch EntitlementPaymentStatus(backendValue: purchase.status) {
        case .active:
            state = purchase.status.lowercased() == "trialing" ? .trialing : .active
        case .paymentFailed:
            // Le palier résolu par le serveur dit si le droit court encore.
            state = resolvedTier == .free ? .onHold : .grace
        case .canceled, .expired:
            state = .expired
        case .inactive, .unknown:
            state = .unknown
        }
        self.init(
            channel: Channel(serverValue: purchase.provider),
            state: state,
            tier: purchase.tier,
            autoRenew: purchase.cancelAtPeriodEnd.map { !$0 },
            currentPeriodEnd: purchase.currentPeriodEnd ?? purchase.expiresAt
        )
    }

    /// Fin du droit en cours : fin de la grâce pendant un délai de grâce, sinon
    /// fin de la période payée.
    var accessEndsAt: Date? {
        state == .grace ? (graceEndsAt ?? currentPeriodEnd) : currentPeriodEnd
    }
}

/// Accès offert (code promo, geste d'un administrateur).
struct EntitlementGrant: Equatable, Sendable {
    let tier: SupporterTier
    let expiresAt: Date?
}

/// Essai gratuit, commun aux trois canaux (contrat v1 §6, D3).
struct EntitlementTrial: Equatable, Sendable {
    let eligible: Bool
    let days: Int?
}

/// Avantages réellement en ligne, par palier (contrat v1 §3, B9). L'app n'en
/// affiche que les clés qu'elle connaît.
struct EntitlementBenefits: Equatable, Sendable {
    let free: [String]
    let premium: [String]
}

struct EntitlementSnapshot: Equatable, Sendable {
    let tier: SupporterTier
    let source: EntitlementSource
    let period: SubscriptionBillingPeriod?
    let status: EntitlementPaymentStatus
    let expiresAt: Date?
    /// Abonnement qui donne le palier ; avec l'ancienne route, l'achat le plus fort.
    let subscription: EntitlementSubscription?
    /// Autres abonnements payés en cours.
    let otherSubscriptions: [EntitlementSubscription]
    /// `DUPLICATE_PAID_SUBSCRIPTION`, `PAYMENT_ISSUE`…
    let warnings: [String]
    let grant: EntitlementGrant?
    let trial: EntitlementTrial?
    /// Jeton du compte passé en `appAccountToken` à chaque achat (contrat v1 §4).
    let purchaseAccountToken: UUID?
    let benefits: EntitlementBenefits?

    init(
        tier: SupporterTier,
        source: EntitlementSource,
        period: SubscriptionBillingPeriod?,
        status: EntitlementPaymentStatus,
        expiresAt: Date?,
        subscription: EntitlementSubscription? = nil,
        otherSubscriptions: [EntitlementSubscription] = [],
        warnings: [String] = [],
        grant: EntitlementGrant? = nil,
        trial: EntitlementTrial? = nil,
        purchaseAccountToken: UUID? = nil,
        benefits: EntitlementBenefits? = nil
    ) {
        self.tier = tier
        self.source = source
        self.period = period
        self.status = status
        self.expiresAt = expiresAt
        self.subscription = subscription
        self.otherSubscriptions = otherSubscriptions
        self.warnings = warnings
        self.grant = grant
        self.trial = trial
        self.purchaseAccountToken = purchaseAccountToken
        self.benefits = benefits
    }

    static let free = EntitlementSnapshot(
        tier: .free,
        source: .backend,
        period: nil,
        status: .inactive,
        expiresAt: nil
    )

    /// Abonnements connus, celui qui donne le palier en premier.
    var subscriptions: [EntitlementSubscription] {
        (subscription.map { [$0] } ?? []) + otherSubscriptions
    }

    /// Premier abonnement en cours, qui rendrait un nouvel achat redondant.
    var blockingSubscription: EntitlementSubscription? {
        subscriptions.first { $0.state.blocksNewPurchase }
    }

    /// Vrai si le serveur sert déjà l'abonnement App Store qui se termine à cette
    /// date (contrat v1 §5 : pas de renvoi dans ce cas). Une seconde d'écart est
    /// tolérée : Apple date à la milliseconde, le serveur peut arrondir.
    ///
    /// Avec le renouvellement lu dans StoreKit, le serveur doit aussi servir le
    /// même `autoRenew` (contrat v1.14 §5) : une résiliation faite dans la
    /// feuille d'Apple, ou un `autoRenew` encore inconnu (null), appelle le renvoi.
    func knowsAppStoreSubscription(expiringAt date: Date?, willAutoRenew: Bool? = nil) -> Bool {
        guard let date else { return false }
        return subscriptions.contains { subscription in
            guard subscription.channel == .appStore, let end = subscription.currentPeriodEnd,
                  abs(end.timeIntervalSince(date)) < 1 else { return false }
            return willAutoRenew.map { subscription.autoRenew == $0 } ?? true
        }
    }
}

/// Réponse de droits. Deux formes coexistent le temps du déploiement :
/// - le contrat v1 §3 (`GET /api/me/entitlements`, puis `/verify`), reconnu à
///   son champ `version` ;
/// - l'ancienne forme `tier` + `purchases[]` (`/api/billing/subscription`),
///   que le serveur garde à l'identique pour les builds 184 et 185.
/// Seul `tier` est obligatoire : le reste se lit sans faire échouer l'ensemble.
struct BillingSubscriptionResponse: Decodable, Sendable {
    let tier: SupporterTier
    let purchases: [BillingPurchase]
    let contractVersion: Int?
    let subscription: EntitlementSubscription?
    let otherSubscriptions: [EntitlementSubscription]
    let warnings: [String]
    let grant: EntitlementGrant?
    let trial: EntitlementTrial?
    let purchaseAccountToken: UUID?
    let benefits: EntitlementBenefits?

    private enum CodingKeys: String, CodingKey {
        case tier, purchases, version, subscription, otherSubscriptions, warnings
        case grant, trial, purchaseAccountToken, benefits
    }

    private enum GrantKeys: String, CodingKey { case tier, expiresAt }
    private enum TrialKeys: String, CodingKey { case eligible, days }
    private enum BenefitsKeys: String, CodingKey { case free, premium }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decode(SupporterTier.self, forKey: .tier)
        purchases = c.decodeLossyArray([BillingPurchase].self, forKey: .purchases)
        contractVersion = try? c.decodeIfPresent(Int.self, forKey: .version)
        subscription = try? c.decodeIfPresent(EntitlementSubscription.self, forKey: .subscription)
        otherSubscriptions = c.decodeLossyArray([EntitlementSubscription].self, forKey: .otherSubscriptions)
        warnings = c.decodeLossyArray([String].self, forKey: .warnings)

        if let g = try? c.nestedContainer(keyedBy: GrantKeys.self, forKey: .grant) {
            grant = EntitlementGrant(
                tier: SupporterTier(serverValue: try? g.decodeIfPresent(String.self, forKey: .tier)),
                expiresAt: try? g.decodeIfPresent(Date.self, forKey: .expiresAt)
            )
        } else {
            grant = nil
        }
        if let t = try? c.nestedContainer(keyedBy: TrialKeys.self, forKey: .trial) {
            trial = EntitlementTrial(
                eligible: (try? t.decodeIfPresent(Bool.self, forKey: .eligible)) ?? false,
                days: try? t.decodeIfPresent(Int.self, forKey: .days)
            )
        } else {
            trial = nil
        }
        purchaseAccountToken = (try? c.decodeIfPresent(String.self, forKey: .purchaseAccountToken))
            .flatMap { UUID(uuidString: $0) }
        if let b = try? c.nestedContainer(keyedBy: BenefitsKeys.self, forKey: .benefits) {
            benefits = EntitlementBenefits(
                free: b.decodeLossyArray([String].self, forKey: .free),
                premium: b.decodeLossyArray([String].self, forKey: .premium)
            )
        } else {
            benefits = nil
        }
    }
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
        if response.contractVersion != nil {
            self.init(contractResponse: response)
        } else {
            self.init(legacyResponse: response)
        }
    }

    /// Contrat v1 §3 : le palier servi est déjà le droit (essai, grâce et accès
    /// offert compris) ; l'app n'en recalcule rien.
    private init(contractResponse response: BillingSubscriptionResponse) {
        let subscription = response.subscription
        let source: EntitlementSource
        if let subscription {
            source = subscription.channel.source
        } else if response.tier != .free || response.grant != nil {
            source = .manual
        } else {
            source = .backend
        }

        let status: EntitlementPaymentStatus
        if response.tier != .free {
            status = .active
        } else {
            switch subscription?.state {
            case .grace?, .onHold?: status = .paymentFailed
            case .expired?: status = .expired
            case .revoked?: status = .canceled
            default: status = .inactive
            }
        }

        self.init(
            tier: response.tier,
            source: source,
            period: subscription?.period,
            status: status,
            expiresAt: subscription?.accessEndsAt ?? response.grant?.expiresAt,
            subscription: subscription,
            otherSubscriptions: response.otherSubscriptions,
            warnings: response.warnings,
            grant: response.grant,
            trial: response.trial,
            purchaseAccountToken: response.purchaseAccountToken,
            benefits: response.benefits
        )
    }

    private init(legacyResponse response: BillingSubscriptionResponse) {
        let rankedPurchases = response.purchases.sorted { lhs, rhs in
            if lhs.tier.rank != rhs.tier.rank { return lhs.tier.rank > rhs.tier.rank }
            let lhsActive = EntitlementPaymentStatus(backendValue: lhs.status).grantsAccess
            let rhsActive = EntitlementPaymentStatus(backendValue: rhs.status).grantsAccess
            if lhsActive != rhsActive { return lhsActive }
            return (lhs.expiresAt ?? lhs.currentPeriodEnd ?? .distantPast)
                > (rhs.expiresAt ?? rhs.currentPeriodEnd ?? .distantPast)
        }
        let subscriptions = rankedPurchases.map {
            EntitlementSubscription(legacyPurchase: $0, resolvedTier: response.tier)
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
            expiresAt: purchase.expiresAt ?? purchase.currentPeriodEnd,
            subscription: subscriptions.first,
            otherSubscriptions: Array(subscriptions.dropFirst())
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
    /// Abonnement App Store en cours sur ce compte : il se gère, se résilie ou
    /// se rétablit dans la feuille Apple, sans nouvel achat.
    case managedByAppStore(EntitlementSubscription)
    /// Abonnement souscrit ailleurs : texte seul, sans lien vers un autre
    /// paiement (règles 3.1.1 et 2.3.10, contrat v1 §3 D5).
    case managedElsewhere(EntitlementSubscription)
    /// Abonnement App Store présent sur cet identifiant Apple, mais pas encore
    /// rattaché à ce compte SignalQuest.
    case existingLocalAppStoreEntitlement(SupporterTier)
    case serverVerificationUnavailable

    var canPurchase: Bool { self == .allowed }

    var userMessage: String {
        switch self {
        case .allowed:
            return String(localized: "Achat disponible.")
        case .checkingServer:
            return String(localized: "Vérification de tes droits en cours…")
        case .backendUnavailable:
            return String(localized: "Impossible de vérifier tes abonnements existants. Aucun achat n'est proposé pour éviter une double facturation.")
        case .managedByAppStore(let subscription):
            switch subscription.state {
            case .grace:
                return String(localized: "Le dernier paiement n’est pas passé. Mets à jour ton moyen de paiement dans tes abonnements Apple pour garder Premium.")
            case .onHold:
                return String(localized: "Premium est suspendu : le paiement n’est pas passé. Mets à jour ton moyen de paiement dans tes abonnements Apple pour le rétablir.")
            default:
                return String(localized: "Ton abonnement est géré par Apple : tu peux le modifier ou le résilier dans tes abonnements Apple.")
            }
        case .managedElsewhere(let subscription):
            if subscription.channel == .stripe {
                return String(localized: "Abonnement géré sur le web. Aucun achat n’est proposé ici, pour éviter un double paiement.")
            }
            return String(localized: "Abonnement souscrit sur un autre appareil : il se gère là où il a été souscrit. Aucun achat n’est proposé ici, pour éviter un double paiement.")
        case .existingLocalAppStoreEntitlement:
            return String(localized: "Un abonnement App Store est actif sur cet identifiant Apple, mais pas encore sur ce compte. Touche « Restaurer mes achats » pour le rattacher.")
        case .serverVerificationUnavailable:
            return String(localized: "Les achats ne sont pas disponibles dans cette version de l’app.")
        }
    }
}

struct PurchaseEligibilityPolicy {
    /// Décision lue dans la réponse du serveur, seule source des droits :
    /// - un abonnement en cours (même résilié, en grâce, suspendu ou en pause)
    ///   renvoie vers sa gestion, selon son canal ;
    /// - un accès offert ou un abonnement terminé n'empêchent pas d'acheter ;
    /// - un abonnement App Store local que le serveur ne connaît pas encore
    ///   bloque l'achat : Apple le refuserait, il faut le rattacher.
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
            if let blocking = snapshot.blockingSubscription {
                return blocking.channel == .appStore ? .managedByAppStore(blocking) : .managedElsewhere(blocking)
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

/// Essai gratuit (contrat v1 §6, D3) : affiché seulement si le serveur ET
/// l'App Store le permettent. Le serveur garde un essai par compte SignalQuest,
/// Apple un essai par identifiant Apple ; sans la réponse du serveur (ancienne
/// route), l'app n'annonce rien plutôt que de promettre un essai refusé.
enum FreeTrialRule {
    static func shows(serverTrial: EntitlementTrial?, storeKitEligible: Bool, offerIsFreeTrial: Bool) -> Bool {
        serverTrial?.eligible == true && storeKitEligible && offerIsFreeTrial
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
    /// `renewalInfo` signé d'Apple pour cet abonnement (contrat v1.14 §5) : le
    /// serveur y lit le renouvellement automatique, l'essai, le délai de grâce
    /// et le prix suivant. Absent (omis du JSON) si StoreKit ne l'a pas donné ;
    /// le serveur l'ignore aussi s'il le refuse, sans jamais refuser l'achat.
    var signedRenewalInfo: String? = nil
}

protocol AppStoreTransactionSyncing: Sendable {
    func synchronize(_ proof: AppStoreTransactionProof) async throws -> EntitlementSnapshot
}

/// Suite donnée à une transaction dont la livraison au serveur a échoué
/// (contrat v1 §3, codes des routes d'achat).
enum AppStoreDeliveryFailure: Equatable, Sendable {
    /// L'achat ne sera jamais livré à CE compte (rattaché à un autre compte) :
    /// la transaction est terminée pour ne pas la rejouer sans fin.
    case finish
    /// Session absente, preuve refusée, configuration manquante, magasin
    /// injoignable, panne : la transaction reste ouverte et StoreKit la rejoue.
    case keepForRetry

    static let finishingCodes: Set<String> = ["PURCHASE_ALREADY_LINKED", "SUBSCRIPTION_ALREADY_ACTIVE"]

    /// Codes dont le libellé local rassure sur l'activation à venir.
    static let retryCodes: Set<String> = [
        "BILLING_UNCONFIGURED", "APPLE_BILLING_UNCONFIGURED", "STORE_UNAVAILABLE",
        "PURCHASE_PROOF_INVALID", "APPLE_VERIFY_FAILED", "UNKNOWN_PRODUCT", "BILLING_TESTERS_ONLY",
    ]

    init(_ error: Error) {
        if case APIError.http(409, let code?, _, _, _) = error, Self.finishingCodes.contains(code.uppercased()) {
            self = .finish
        } else {
            self = .keepForRetry
        }
    }

    /// Message d'un achat payé dont l'activation n'a pas encore abouti.
    static func activationMessage(for error: Error) -> String {
        if case APIError.http(_, let code?, _, _, _) = error,
           finishingCodes.union(retryCodes).contains(code.uppercased()) {
            return error.localizedDescription
        }
        return String(localized: "Ton paiement est bien enregistré par Apple, mais son activation n’a pas encore abouti. Elle sera retentée automatiquement, sans nouveau paiement.")
    }
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
            return String(localized: "La transaction App Store n'a pas pu être authentifiée.")
        case .productUnavailable:
            return String(localized: "Cette offre n'est pas disponible dans l'App Store.")
        case .unexpectedProduct:
            return String(localized: "La transaction reçue ne correspond pas à l'offre choisie.")
        case .transactionDeliveryUnavailable:
            return String(localized: "La validation serveur App Store n'est pas encore disponible.")
        }
    }
}

@MainActor
final class EntitlementsStore: ObservableObject {
    /// Réponse de droits unique (contrat v1 §3).
    nonisolated static let entitlementsEndpoint = "/api/me/entitlements"
    /// Ancienne route, lue tant que le serveur ne sert pas encore le §3.
    nonisolated static let subscriptionEndpoint = "/api/billing/subscription"

    @Published private(set) var products: [SignalQuestSubscriptionProduct: Product] = [:]
    @Published private(set) var productLoadMessage: String?
    /// Offres pour lesquelles l'identifiant Apple a encore droit à l'essai.
    @Published private(set) var introOfferEligibleProducts: Set<SignalQuestSubscriptionProduct> = []
    @Published private var storedServerState: ServerEntitlementState = .idle
    @Published private(set) var localEntitlementTier: SupporterTier = .free
    @Published private var storedOperation: StoreKitOperationState = .idle
    private var serverStateSession: LocalAccountSession?
    private var operationSession: LocalAccountSession?
    /// 404 reçu sur le §3 pendant ce lancement : l'ancienne route suffit
    /// jusqu'au prochain lancement, sans un appel perdu à chaque lecture.
    private var contractRouteMissing = false
    /// Transactions d'origine déjà envoyées ou reconnues pendant ce lancement,
    /// par session et par état de renouvellement (contrat v1 §5 : un seul envoi
    /// par lancement ; v1.14 : un de plus si le renouvellement change).
    private var reconciledThisLaunch: Set<String> = []
    private var isReconciling = false

    /// Un snapshot du compte A ne doit jamais être présenté comme le droit de B
    /// après une déconnexion, même si le store survit au changement de session.
    var serverState: ServerEntitlementState {
        guard let session = LocalAccountScope.sessionSnapshot(),
              session == serverStateSession else { return .idle }
        return storedServerState
    }

    var operation: StoreKitOperationState {
        guard let session = LocalAccountScope.sessionSnapshot(),
              session == operationSession else { return .idle }
        return storedOperation
    }

    private let api: APIClientProtocol
    private let purchasesEnabled: Bool
    private let serverVerificationEnabled: Bool
    private let synchronizer: AppStoreTransactionSyncing?
    private var updatesTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "Entitlements")

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

    /// Offre d'essai gratuit à annoncer pour ce produit, sinon `nil`.
    func freeTrialOffer(for identifier: SignalQuestSubscriptionProduct) -> Product.SubscriptionOffer? {
        guard let offer = products[identifier]?.subscription?.introductoryOffer,
              FreeTrialRule.shows(
                serverTrial: serverState.snapshot?.trial,
                storeKitEligible: introOfferEligibleProducts.contains(identifier),
                offerIsFreeTrial: offer.paymentMode == .freeTrial
              ) else { return nil }
        return offer
    }

    /// Dernière transaction de l'abonnement App Store en cours sur cet appareil,
    /// pour la feuille de remboursement d'Apple (D8). C'est Apple qui décide ;
    /// le serveur applique la notification REFUND qu'il reçoit ensuite.
    func latestAppStoreTransactionID() async -> Transaction.ID? {
        var latest: Transaction?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.verified(result),
                  SignalQuestSubscriptionProduct(rawValue: transaction.productID) != nil,
                  transaction.revocationDate == nil else { continue }
            if latest.map({ transaction.purchaseDate > $0.purchaseDate }) ?? true { latest = transaction }
        }
        return latest?.id
    }

    func prepare() async {
        await refreshBackendSnapshot()
        await refreshStoreKitState()
    }

    func refreshBackendSnapshot() async {
        guard let session = LocalAccountScope.sessionSnapshot() else {
            serverStateSession = nil
            storedServerState = .idle
            return
        }
        publishServerState(.loading, for: session)
        do {
            let response = try await fetchEntitlements()
            publishServerState(.available(EntitlementSnapshot(response: response)), for: session)
        } catch {
            publishServerState(.unavailable(error.localizedDescription), for: session)
        }
    }

    /// Lit le §3, puis l'ancienne route si le serveur ne le sert pas encore (404).
    private func fetchEntitlements() async throws -> BillingSubscriptionResponse {
        if !contractRouteMissing {
            do {
                return try await api.request(
                    APIEndpoint(path: Self.entitlementsEndpoint),
                    as: BillingSubscriptionResponse.self
                )
            } catch APIError.http(404, _, _, _, _) {
                contractRouteMissing = true
            }
        }
        return try await api.request(
            APIEndpoint(path: Self.subscriptionEndpoint),
            as: BillingSubscriptionResponse.self
        )
    }

    private func publishServerState(_ state: ServerEntitlementState, for session: LocalAccountSession) {
        guard LocalAccountScope.sessionSnapshot() == session else { return }
        serverStateSession = session
        storedServerState = state
    }

    private func publishOperation(_ state: StoreKitOperationState, for session: LocalAccountSession) {
        guard LocalAccountScope.sessionSnapshot() == session else { return }
        operationSession = session
        storedOperation = state
    }

    func refreshStoreKitState() async {
        await loadProducts()
        await refreshLocalEntitlements()
    }

    func purchase(_ identifier: SignalQuestSubscriptionProduct) async {
        // Un achat Apple ne doit jamais démarrer sans compte SignalQuest actif.
        guard let accountSession = LocalAccountScope.sessionSnapshot() else { return }
        let currentEligibility = eligibility
        guard currentEligibility.canPurchase else {
            publishOperation(.failed(currentEligibility.userMessage), for: accountSession)
            return
        }
        guard let product = products[identifier] else {
            publishOperation(.failed(EntitlementsError.productUnavailable.localizedDescription), for: accountSession)
            return
        }
        guard synchronizer != nil else {
            publishOperation(.failed(EntitlementsError.transactionDeliveryUnavailable.localizedDescription), for: accountSession)
            return
        }

        // Le jeton du compte voyage dans la transaction signée : le serveur
        // rattache ainsi au bon compte un achat livré par une notification
        // (contrat v1 §4). Sans jeton servi, l'achat part sans, comme avant.
        var options: Set<Product.PurchaseOption> = []
        if SQFeatures.storeKitAppAccountTokenEnabled, let token = serverState.snapshot?.purchaseAccountToken {
            options.insert(.appAccountToken(token))
        }

        publishOperation(.purchasing(identifier), for: accountSession)
        do {
            let result = try await product.purchase(options: options)
            guard LocalAccountScope.sessionSnapshot() == accountSession else { return }
            switch result {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                // Un changement d'offre peut rendre l'autre durée : seule une
                // transaction hors catalogue est refusée.
                guard SignalQuestSubscriptionProduct(rawValue: transaction.productID) != nil else {
                    throw EntitlementsError.unexpectedProduct
                }
                let outcome = await deliver(verification, transaction: transaction, session: accountSession)
                await refreshLocalEntitlements()
                publishOperation(Self.operationState(after: outcome), for: accountSession)
            case .pending:
                publishOperation(.pending, for: accountSession)
            case .userCancelled:
                publishOperation(.idle, for: accountSession)
            @unknown default:
                publishOperation(.failed(String(localized: "Réponse App Store inconnue. Réessaie plus tard.")), for: accountSession)
            }
        } catch {
            publishOperation(.failed(error.localizedDescription), for: accountSession)
        }
    }

    /// Restaure les transactions Apple puis les livre au serveur. Une
    /// restauration demandée passe outre la limite d'un envoi par lancement.
    func restorePurchases() async {
        guard let accountSession = LocalAccountScope.sessionSnapshot() else { return }
        publishOperation(.restoring, for: accountSession)
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            publishOperation(.idle, for: accountSession)
            return
        } catch {
            logger.error("Restauration App Store échouée : \(error.localizedDescription, privacy: .public)")
            publishOperation(.failed(String(localized: "Impossible de contacter l’App Store pour le moment. Réessaie un peu plus tard.")), for: accountSession)
            return
        }
        guard LocalAccountScope.sessionSnapshot() == accountSession else { return }
        await refreshLocalEntitlements()
        let candidates = await currentAppStoreTransactions()
        guard LocalAccountScope.sessionSnapshot() == accountSession else { return }

        guard !candidates.isEmpty else {
            await refreshBackendSnapshot()
            publishOperation(.succeeded(String(localized: "Aucun abonnement App Store en cours n’a été trouvé pour cet identifiant Apple.")), for: accountSession)
            return
        }
        guard serverVerificationReady else {
            publishOperation(.failed(PurchaseEligibility.existingLocalAppStoreEntitlement(localEntitlementTier).userMessage), for: accountSession)
            return
        }

        var outcomes: [DeliveryOutcome] = []
        for candidate in candidates {
            outcomes.append(await deliver(candidate.latest.result, transaction: candidate.latest.transaction,
                                          alsoFinishing: candidate.unfinished, session: accountSession))
        }
        await refreshBackendSnapshot()
        await refreshLocalEntitlements()
        guard LocalAccountScope.sessionSnapshot() == accountSession else { return }

        // Un achat rattaché à un autre compte prime : c'est l'information utile.
        if let finished = outcomes.first(where: { if case .finishedWithoutDelivery = $0 { true } else { false } }) {
            publishOperation(Self.operationState(after: finished), for: accountSession)
        } else if outcomes.contains(where: { if case .delivered = $0 { true } else { false } }) {
            publishOperation(.succeeded(String(localized: "Achats restaurés et droits vérifiés.")), for: accountSession)
        } else if let failure = outcomes.first {
            publishOperation(Self.operationState(after: failure), for: accountSession)
        }
    }

    /// Renvoie au serveur les transactions App Store en cours (contrat v1 §5),
    /// au lancement et au retour au premier plan : avec une session ouverte, une
    /// seule fois par lancement, par transaction d'origine et par état de
    /// renouvellement, et jamais quand le serveur sert déjà cet abonnement avec
    /// la même échéance et le même renouvellement (v1.14). Rattrape l'achat
    /// simplifié, l'achat fait sur un autre appareil, un achat payé pendant une
    /// panne du serveur et une résiliation faite dans la feuille d'Apple.
    /// Silencieux : un échec reste dans les journaux, ne déconnecte jamais et
    /// sera retenté au prochain lancement. Vrai si les droits ont été relus.
    @discardableResult
    func reconcileAppStoreTransactions() async -> Bool {
        guard serverVerificationReady, !isReconciling,
              let session = LocalAccountScope.sessionSnapshot() else { return false }
        isReconciling = true
        defer { isReconciling = false }

        let current = await currentAppStoreTransactions()
        let renewals = await Self.appStoreRenewals(for: current.map(\.latest.transaction))
        let candidates = current.filter {
            let transaction = $0.latest.transaction
            return !reconciledThisLaunch.contains(
                Self.reconciliationKey(session, transaction, renewals[transaction.originalID]))
        }
        guard !candidates.isEmpty, LocalAccountScope.sessionSnapshot() == session else { return false }

        await refreshBackendSnapshot()
        guard LocalAccountScope.sessionSnapshot() == session else { return true }
        let snapshot = serverState.snapshot
        for candidate in candidates {
            let transaction = candidate.latest.transaction
            let renewal = renewals[transaction.originalID]
            reconciledThisLaunch.insert(Self.reconciliationKey(session, transaction, renewal))
            if snapshot?.knowsAppStoreSubscription(expiringAt: transaction.expirationDate,
                                                   willAutoRenew: renewal?.willAutoRenew) == true {
                // Déjà livré (notification Apple ou lancement précédent) : seules
                // les transactions restées ouvertes sont à terminer.
                for pending in candidate.unfinished { await pending.finish() }
                continue
            }
            let outcome = await deliver(candidate.latest.result, transaction: transaction,
                                        alsoFinishing: candidate.unfinished, session: session)
            if case .retryLater(let error) = outcome {
                logger.notice("Renvoi App Store reporté : \(String(describing: error), privacy: .public)")
            }
        }
        await refreshLocalEntitlements()
        return true
    }

    /// À la fermeture de la feuille de gestion d'Apple : renvoie l'abonnement
    /// dont le renouvellement vient de changer (contrat v1.14 §5), sinon relit
    /// simplement les droits servis.
    func refreshAfterManagingSubscriptions() async {
        let reread = await reconcileAppStoreTransactions()
        if !reread { await refreshBackendSnapshot() }
        await refreshStoreKitState()
    }

    func clearOperationMessage() {
        guard !operation.isBusy else { return }
        guard let accountSession = LocalAccountScope.sessionSnapshot() else { return }
        publishOperation(.idle, for: accountSession)
    }

    private func loadProducts() async {
        do {
            let loaded = try await Product.products(for: SignalQuestSubscriptionProduct.allCases.map(\.rawValue))
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in
                guard let identifier = SignalQuestSubscriptionProduct(rawValue: product.id) else { return nil }
                return (identifier, product)
            })
            var eligible: Set<SignalQuestSubscriptionProduct> = []
            for (identifier, product) in products {
                if let subscription = product.subscription, await subscription.isEligibleForIntroOffer {
                    eligible.insert(identifier)
                }
            }
            introOfferEligibleProducts = eligible
            if products.isEmpty {
                // Un catalogue vide a plusieurs causes indiscernables d'ici :
                // offres pas encore approuvées par Apple, territoire hors de la
                // disponibilité retenue dans App Store Connect, ou simplement
                // aucun compte App Store sur l'appareil. On n'en désigne aucune
                // plutôt que d'en inventer une — et surtout on ne renvoie pas
                // l'utilisateur à un défaut de configuration qui n'est pas le
                // sien : « Catalogue App Store non configuré pour cette version »
                // était une phrase d'ingénieur affichée à un client.
                logger.warning("Catalogue App Store vide pour les identifiants d'abonnement.")
                productLoadMessage = String(localized: "Les abonnements ne sont pas disponibles depuis cet appareil pour le moment.")
            } else {
                productLoadMessage = nil
            }
        } catch {
            products = [:]
            introOfferEligibleProducts = []
            // Le détail technique part dans les logs et non à l'écran : le
            // `localizedDescription` de StoreKit est rédigé pour un développeur.
            logger.error("Chargement du catalogue App Store échoué : \(error.localizedDescription, privacy: .public)")
            productLoadMessage = String(localized: "Impossible de contacter l’App Store pour le moment. Réessaie un peu plus tard.")
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

    /// Transactions Apple livrées hors d'un achat dans l'app : renouvellement,
    /// achat approuvé par un parent, achat simplifié ou fait sur un autre
    /// appareil, transaction restée ouverte au lancement. Sans session, rien
    /// n'est envoyé : le renvoi suivant la connexion s'en charge.
    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? Self.verified(result),
              SignalQuestSubscriptionProduct(rawValue: transaction.productID) != nil,
              let accountSession = LocalAccountScope.sessionSnapshot()
        else { return }

        await refreshLocalEntitlements()
        guard LocalAccountScope.sessionSnapshot() == accountSession else { return }
        // Seul un achat en attente d'approbation attend une réponse à l'écran.
        let awaitingApproval = operation == .pending
        let outcome = await deliver(result, transaction: transaction, session: accountSession)
        if case .retryLater(let error) = outcome {
            logger.notice("Livraison App Store reportée : \(String(describing: error), privacy: .public)")
        }
        if awaitingApproval {
            publishOperation(Self.operationState(after: outcome), for: accountSession)
        }
    }

    // MARK: Delivery

    private enum DeliveryOutcome {
        case delivered(EntitlementSnapshot)
        /// Terminée sans droit pour ce compte (achat rattaché à un autre compte).
        case finishedWithoutDelivery(String)
        /// Gardée ouverte : StoreKit la rejouera, le renvoi au lancement aussi.
        case retryLater(Error)
    }

    /// Livre une transaction au serveur et la termine seulement s'il l'a
    /// enregistrée, ou s'il dit qu'elle ne sera jamais livrée à ce compte.
    private func deliver(
        _ result: VerificationResult<Transaction>,
        transaction: Transaction,
        alsoFinishing unfinished: [Transaction] = [],
        session: LocalAccountSession
    ) async -> DeliveryOutcome {
        guard let synchronizer, serverVerificationEnabled else {
            return .retryLater(EntitlementsError.transactionDeliveryUnavailable)
        }
        let renewal = await Self.appStoreRenewals(for: [transaction])[transaction.originalID]
        reconciledThisLaunch.insert(Self.reconciliationKey(session, transaction, renewal))
        do {
            let snapshot = try await synchronizer.synchronize(
                Self.proof(for: result, transaction: transaction, renewal: renewal))
            // Le serveur a enregistré l'achat : il est terminé même si la session
            // a changé entre-temps ; seul l'affichage suit la session.
            publishServerState(.available(snapshot), for: session)
            await Self.finish(transaction, unfinished)
            return .delivered(snapshot)
        } catch {
            guard AppStoreDeliveryFailure(error) == .finish else { return .retryLater(error) }
            await Self.finish(transaction, unfinished)
            await refreshBackendSnapshot()
            return .finishedWithoutDelivery(AppStoreDeliveryFailure.activationMessage(for: error))
        }
    }

    private static func finish(_ transaction: Transaction, _ others: [Transaction]) async {
        var finished: Set<UInt64> = []
        for item in [transaction] + others where finished.insert(item.id).inserted {
            await item.finish()
        }
    }

    private static func operationState(after outcome: DeliveryOutcome) -> StoreKitOperationState {
        switch outcome {
        case .delivered(let snapshot):
            guard snapshot.tier != .free else {
                return .failed(String(localized: "Ton paiement est bien enregistré par Apple, mais son activation n’a pas encore abouti. Elle sera retentée automatiquement, sans nouveau paiement."))
            }
            return .succeeded(String(localized: "Abonnement \(snapshot.tier.displayName) activé sur ton compte."))
        case .finishedWithoutDelivery(let message):
            return .failed(message)
        case .retryLater(let error):
            return .failed(AppStoreDeliveryFailure.activationMessage(for: error))
        }
    }

    private struct AppStoreCandidate {
        /// Transaction la plus récente de l'abonnement, celle qu'on envoie.
        var latest: (result: VerificationResult<Transaction>, transaction: Transaction)
        /// Transactions restées ouvertes, terminées une fois l'abonnement livré.
        var unfinished: [Transaction]
    }

    /// Abonnements App Store en cours ou restés ouverts, un par transaction
    /// d'origine.
    private func currentAppStoreTransactions() async -> [AppStoreCandidate] {
        var byOriginal: [UInt64: AppStoreCandidate] = [:]
        func add(_ result: VerificationResult<Transaction>, unfinished: Bool) {
            guard let transaction = try? Self.verified(result),
                  SignalQuestSubscriptionProduct(rawValue: transaction.productID) != nil else { return }
            var candidate = byOriginal[transaction.originalID]
                ?? AppStoreCandidate(latest: (result, transaction), unfinished: [])
            if transaction.purchaseDate > candidate.latest.transaction.purchaseDate {
                candidate.latest = (result, transaction)
            }
            if unfinished { candidate.unfinished.append(transaction) }
            byOriginal[transaction.originalID] = candidate
        }
        for await result in Transaction.unfinished { add(result, unfinished: true) }
        for await result in Transaction.currentEntitlements { add(result, unfinished: false) }
        return Array(byOriginal.values)
    }

    /// Renouvellement Apple d'un abonnement, tel que StoreKit l'a vérifié.
    private struct AppStoreRenewal {
        let signedRenewalInfo: String
        let willAutoRenew: Bool
    }

    /// Renouvellement de chaque abonnement, par transaction d'origine (contrat
    /// v1.14 §5). Seul un `renewalInfo` vérifié par StoreKit est gardé ; une
    /// erreur StoreKit laisse l'abonnement sans renouvellement connu.
    private static func appStoreRenewals(for transactions: [Transaction]) async -> [UInt64: AppStoreRenewal] {
        var renewals: [UInt64: AppStoreRenewal] = [:]
        for group in Set(transactions.compactMap(\.subscriptionGroupID)) {
            guard let statuses = try? await Product.SubscriptionInfo.status(for: group) else { continue }
            for status in statuses {
                guard case .verified(let info) = status.renewalInfo else { continue }
                renewals[info.originalTransactionID] = AppStoreRenewal(
                    signedRenewalInfo: status.renewalInfo.jwsRepresentation, willAutoRenew: info.willAutoRenew)
            }
        }
        return renewals
    }

    nonisolated private static func reconciliationKey(
        _ session: LocalAccountSession,
        _ transaction: Transaction,
        _ renewal: AppStoreRenewal?
    ) -> String {
        let renewalState = renewal.map { $0.willAutoRenew ? "renews" : "stops" } ?? "unknown"
        return "\(session.ownerScopeId)|\(session.sessionId)|\(transaction.originalID)|\(renewalState)"
    }

    nonisolated private static func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw EntitlementsError.failedVerification
        }
    }

    nonisolated private static func proof(
        for result: VerificationResult<Transaction>,
        transaction: Transaction,
        renewal: AppStoreRenewal?
    ) -> AppStoreTransactionProof {
        AppStoreTransactionProof(
            signedTransaction: result.jwsRepresentation,
            productId: transaction.productID,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            signedRenewalInfo: renewal?.signedRenewalInfo
        )
    }
}
