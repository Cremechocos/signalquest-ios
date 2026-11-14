import StoreKit
import SwiftUI

enum PaywallEntryPoint: Equatable, Sendable {
    case profile
    case premiumFeature(String)

    var introduction: String {
        switch self {
        case .profile:
            return String(localized: "Premium ajoute du confort et des bonus. Toutes les fonctions Telecom restent gratuites.")
        case .premiumFeature(let name):
            return String(localized: "« \(name) » fait partie de Premium. Découvre l’offre sans perdre ce que tu étais en train de faire.")
        }
    }
}

/// Le montant facturé vient directement de StoreKit. L'équivalent mensuel est
/// une simple comparaison, jamais le prix que l'App Store débitera.
enum SubscriptionPriceCopy {
    static func priceLine(product: Product?) -> String {
        guard let product, let period = periodDescription(product) else {
            return String(localized: "Offre indisponible")
        }
        return String(format: String(localized: "%1$@ pour %2$@"), product.displayPrice, period)
    }

    static func monthlyEquivalent(product: Product) -> String? {
        guard let subscriptionPeriod = product.subscription?.subscriptionPeriod,
              let period = periodDescription(product),
              let amount = monthlyAmount(
                price: product.price,
                unit: subscriptionPeriod.unit,
                value: subscriptionPeriod.value
              ) else { return nil }
        let formatted = amount.formatted(product.priceFormatStyle)
        return String(format: String(localized: "Environ %1$@ par mois, facturé %2$@ pour %3$@."),
                      formatted, product.displayPrice, period)
    }

    static func monthlyAmount(
        price: Decimal,
        unit: Product.SubscriptionPeriod.Unit,
        value: Int
    ) -> Decimal? {
        guard value > 0 else { return nil }
        let months: Int
        switch unit {
        case .month: months = value
        case .year:
            guard value <= Int.max / 12 else { return nil }
            months = value * 12
        case .day, .week: return nil // un mois civil n'a pas une durée fixe
        @unknown default: return nil
        }
        guard months > 1 else { return nil }
        return price / Decimal(months)
    }

    static func matchesSelection(
        _ unit: Product.SubscriptionPeriod.Unit,
        value: Int,
        selection: SubscriptionBillingPeriod
    ) -> Bool {
        switch selection {
        case .monthly: return unit == .month && value == 1
        case .annual: return unit == .year && value == 1
        }
    }

    /// « 1 semaine d’essai gratuit » : la durée vient de l'offre StoreKit.
    static func trialLine(offer: Product.SubscriptionOffer, product: Product) -> String {
        let period = offer.period.formatted(
            product.subscriptionPeriodFormatStyle.locale(Locale.current),
            referenceDate: Date(timeIntervalSince1970: 0)
        )
        return String(localized: "\(period) d’essai gratuit")
    }

    private static func periodDescription(_ product: Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod, period.value > 0 else { return nil }
        return period.formatted(
            product.subscriptionPeriodFormatStyle.locale(Locale.current),
            referenceDate: Date(timeIntervalSince1970: 0)
        )
    }
}

/// Ce que l'écran dit de l'abonnement, d'après la seule réponse du serveur
/// (contrat v1 §2 et §3) : une ligne par état, sans aucun droit recalculé ici.
struct SubscriptionStatusPresentation: Equatable {
    enum Tone: Equatable { case neutral, positive, warning }

    /// Où se gère l'abonnement (contrat v1 §3, D5).
    enum Management: Equatable {
        case none
        /// Feuille Apple native : modifier, résilier, reprendre. Le
        /// remboursement se demande à Apple (D8).
        case appStore(canResume: Bool, canRequestRefund: Bool)
        /// Texte seul : aucun lien ni appel vers un autre paiement (3.1.1),
        /// aucune autre plateforme nommée (2.3.10).
        case elsewhere(String)
    }

    let title: String
    let tag: String?
    let details: [String]
    let tone: Tone
    let management: Management

    static func make(serverState: ServerEntitlementState) -> SubscriptionStatusPresentation {
        switch serverState {
        case .idle, .loading:
            return SubscriptionStatusPresentation(
                title: String(localized: "Ton abonnement"), tag: nil,
                details: [String(localized: "Vérification de ton abonnement…")],
                tone: .neutral, management: .none
            )
        case .unavailable:
            return SubscriptionStatusPresentation(
                title: String(localized: "Ton abonnement"), tag: nil,
                details: [String(localized: "Le serveur des abonnements ne répond pas. Les nouveaux achats sont bloqués par sécurité.")],
                tone: .warning, management: .none
            )
        case .available(let snapshot):
            var presentation = make(snapshot: snapshot)
            if snapshot.warnings.contains("DUPLICATE_PAID_SUBSCRIPTION") {
                presentation = SubscriptionStatusPresentation(
                    title: presentation.title, tag: presentation.tag,
                    details: presentation.details + [String(localized: "Deux abonnements payés sont en cours sur ton compte : résilies-en un pour ne pas payer deux fois. Chacun se gère là où il a été souscrit.")],
                    tone: .warning, management: presentation.management
                )
            }
            return presentation
        }
    }

    private static func make(snapshot: EntitlementSnapshot) -> SubscriptionStatusPresentation {
        if let subscription = snapshot.subscription ?? snapshot.blockingSubscription {
            return make(subscription: subscription)
        }
        if let grant = snapshot.grant, grant.tier != .free {
            let detail = grant.expiresAt.map {
                String(localized: "Accès offert jusqu’au \(day($0)). Tu peux t’abonner pour continuer ensuite.")
            } ?? String(localized: "Accès offert, sans date de fin.")
            return SubscriptionStatusPresentation(
                title: grant.tier.displayName, tag: String(localized: "Offert"),
                details: [detail], tone: .positive, management: .none
            )
        }
        if snapshot.tier != .free {
            return SubscriptionStatusPresentation(
                title: snapshot.tier.displayName, tag: String(localized: "Actif"),
                details: [], tone: .positive, management: .none
            )
        }
        return SubscriptionStatusPresentation(
            title: SupporterTier.free.displayName, tag: nil,
            details: [String(localized: "Aucun abonnement en cours.")],
            tone: .neutral, management: .none
        )
    }

    private static func make(subscription: EntitlementSubscription) -> SubscriptionStatusPresentation {
        let tag: String?
        var details: [String] = []
        let tone: Tone
        let cancelled = subscription.autoRenew == false

        switch subscription.state {
        case .trialing:
            tag = cancelled ? String(localized: "Essai résilié") : String(localized: "Essai gratuit")
            let end = subscription.trialEndsAt ?? subscription.currentPeriodEnd
            if cancelled {
                details.append(end.map { String(localized: "Premium reste actif jusqu’au \(day($0)), sans aucun paiement.") }
                               ?? String(localized: "L’essai s’arrêtera à son terme, sans aucun paiement."))
            } else if let end, subscription.pendingChange == nil,
                      let price = subscription.price.map(formattedPrice), let period = subscription.period {
                // Chez Apple, `price` est celui du produit suivant : avec un changement
                // d'offre prévu, il ne se lit plus avec la période en cours.
                details.append(period == .annual
                    ? String(localized: "Essai gratuit jusqu’au \(day(end)), puis \(price) par an.")
                    : String(localized: "Essai gratuit jusqu’au \(day(end)), puis \(price) par mois."))
            } else if let end {
                details.append(String(localized: "Essai gratuit jusqu’au \(day(end))."))
            }
            tone = .positive
        case .active:
            if cancelled {
                tag = String(localized: "Résilié")
                details.append(subscription.currentPeriodEnd.map {
                    String(localized: "Premium reste actif jusqu’au \(day($0)), puis s’arrête sans nouveau paiement.")
                } ?? String(localized: "Premium s’arrêtera à la fin de la période en cours, sans nouveau paiement."))
                tone = .neutral
            } else {
                tag = String(localized: "Actif")
                // `autoRenew` à null : le serveur ne sait pas encore si l'abonnement se
                // renouvellera (Apple, `renewalInfo` non lu). On ne promet alors aucun
                // renouvellement, qui serait faux après une résiliation.
                if subscription.autoRenew == true, let end = subscription.currentPeriodEnd,
                   let price = subscription.price.map(formattedPrice) {
                    details.append(String(localized: "Prochain renouvellement le \(day(end)), pour \(price)."))
                } else if subscription.autoRenew == true, let end = subscription.currentPeriodEnd {
                    details.append(String(localized: "Prochain renouvellement le \(day(end))."))
                } else if let end = subscription.currentPeriodEnd {
                    details.append(String(localized: "Période en cours jusqu’au \(day(end))."))
                }
                tone = .positive
            }
        case .grace:
            tag = String(localized: "Paiement à régulariser")
            details.append(subscription.accessEndsAt.map {
                String(localized: "Le dernier paiement n’est pas passé. Premium reste actif jusqu’au \(day($0)) : mets à jour ton moyen de paiement d’ici là.")
            } ?? String(localized: "Le dernier paiement n’est pas passé. Mets à jour ton moyen de paiement pour garder Premium."))
            tone = .warning
        case .onHold:
            tag = String(localized: "Suspendu")
            details.append(String(localized: "Le paiement n’est pas passé : Premium est suspendu. Mets à jour ton moyen de paiement pour le rétablir."))
            tone = .warning
        case .paused:
            tag = String(localized: "En pause")
            details.append(subscription.resumesAt.map { String(localized: "Reprise prévue le \(day($0)).") }
                           ?? String(localized: "Abonnement en pause."))
            tone = .neutral
        case .pending:
            tag = String(localized: "En attente")
            details.append(String(localized: "Le paiement n’est pas encore confirmé."))
            tone = .neutral
        case .expired:
            tag = String(localized: "Terminé")
            details.append(subscription.currentPeriodEnd.map { String(localized: "Abonnement terminé le \(day($0)).") }
                           ?? String(localized: "Abonnement terminé."))
            tone = .neutral
        case .revoked:
            tag = String(localized: "Remboursé")
            details.append(String(localized: "Cet abonnement a été remboursé : Premium n’est plus actif."))
            tone = .neutral
        case .unknown:
            tag = nil
            tone = .neutral
        }
        // Contrat v1.15 : servi en essai et en actif seulement, et sans objet
        // quand rien ne se renouvelle plus.
        if [.trialing, .active].contains(subscription.state), !cancelled,
           let effectiveAt = subscription.pendingChange?.effectiveAt {
            details.append(String(localized: "Changement d’offre prévu le \(day(effectiveAt))."))
        }
        if subscription.isSandbox {
            details.append(String(localized: "Achat de test : aucun paiement réel."))
        }

        let management: Management
        switch subscription.channel {
        case .appStore:
            let running = subscription.state.blocksNewPurchase
            management = running
                ? .appStore(canResume: cancelled && subscription.state.grantsAccess,
                            canRequestRefund: [.active, .grace, .onHold].contains(subscription.state))
                : .none
        case .stripe:
            management = .elsewhere(String(localized: "Abonnement géré sur le web."))
        case .googlePlay, .unknown:
            management = .elsewhere(String(localized: "Abonnement souscrit sur un autre appareil : il se gère là où il a été souscrit."))
        }

        return SubscriptionStatusPresentation(
            title: subscription.tier.displayName, tag: tag, details: details, tone: tone, management: management
        )
    }

    static func day(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }

    /// Prix servi en unité mineure (contrat v1.8), avec les décimales de sa devise.
    static func formattedPrice(_ price: EntitlementSubscription.Price) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = price.currency
        var divisor = Decimal(1)
        for _ in 0..<formatter.maximumFractionDigits { divisor *= 10 }
        let amount = Decimal(price.unitAmount) / divisor
        return formatter.string(from: amount as NSDecimalNumber) ?? amount.formatted(.currency(code: price.currency))
    }
}

/// Suppression de compte avec un abonnement payé en cours (contrat abonnements
/// v1, D4) : l'avertissement se lit dès l'ouverture, par canal ; le 409
/// ACTIVE_PAID_SUBSCRIPTION n'est qu'un filet. Un abonnement App Store se résilie
/// dans la feuille Apple (5.1.1(v)) ; un abonnement pris ailleurs ne nomme
/// aucune plateforme (2.3.10).
struct AccountDeletionSubscriptionNotice: View {
    @ObservedObject var store: EntitlementsStore
    @State private var showsManageSubscriptions = false

    /// Abonnements payés encore en cours, ceux que la suppression concerne.
    static func running(in snapshot: EntitlementSnapshot?) -> [EntitlementSubscription] {
        (snapshot?.subscriptions ?? []).filter { $0.state.blocksNewPurchase }
    }

    /// Les textes du contrat, par canal : le serveur résilie le web et l'autre
    /// magasin, jamais l'App Store.
    static func message(for subscription: EntitlementSubscription) -> String {
        switch subscription.channel {
        case .appStore:
            guard subscription.autoRenew == false else {
                return String(localized: "Supprimer ton compte ne résilie pas ton abonnement App Store : SignalQuest ne peut pas le faire à ta place. Résilie-le d’abord avec le bouton ci-dessous ; un remboursement se demande à Apple.")
            }
            return subscription.accessEndsAt.map {
                String(localized: "Ton abonnement App Store est déjà résilié : il s’arrêtera le \(SubscriptionStatusPresentation.day($0)), sans nouveau paiement. Un remboursement se demande à Apple.")
            } ?? String(localized: "Ton abonnement App Store est déjà résilié : il s’arrêtera sans nouveau paiement. Un remboursement se demande à Apple.")
        case .stripe:
            return String(localized: "Ton abonnement souscrit sur le web sera résilié dès la suppression, sans remboursement, sauf si tu es encore dans ton délai de rétractation de 14 jours et que tu n’y as pas renoncé.")
        case .googlePlay, .unknown:
            return String(localized: "Ton abonnement souscrit sur un autre appareil sera résilié dès la suppression : aucun nouveau prélèvement. La période en cours n’est pas remboursée par SignalQuest ; un remboursement se demande là où il a été souscrit.")
        }
    }

    var body: some View {
        let running = Self.running(in: store.serverState.snapshot)
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                ForEach(Array(running.enumerated()), id: \.offset) { _, subscription in
                    SQNotice(message: Self.message(for: subscription), title: String(localized: "Abonnement en cours"),
                             systemImage: "creditcard", tone: .warning)
                }
                if running.contains(where: { $0.channel == .appStore && $0.autoRenew != false }) {
                    GradientButton("Gérer ou résilier mon abonnement", systemImage: "creditcard", style: .secondary) {
                        showsManageSubscriptions = true
                    }
                }
            }
            .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
            .onChangeCompat(of: showsManageSubscriptions) { _, shown in
                if !shown { Task { await store.refreshAfterManagingSubscriptions() } }
            }
        }
    }
}

struct PaywallView: View {
    @ObservedObject private var store: EntitlementsStore
    private let entryPoint: PaywallEntryPoint
    @State private var selectedPeriod = SubscriptionBillingPeriod.monthly
    @State private var showsManageSubscriptions = false
    @State private var refundTransactionID: StoreKit.Transaction.ID?
    @State private var showsRefundRequest = false
    @State private var refundMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(store: EntitlementsStore, entryPoint: PaywallEntryPoint = .profile) {
        _store = ObservedObject(wrappedValue: store)
        self.entryPoint = entryPoint
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header
                subscriptionCard
                if showsOffer {
                    periodPicker
                    premiumCard
                }
                restorationSection
                legalFooter
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.huge)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .navigationTitle("Abonnements")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { await store.prepare() }
        .refreshable { await store.prepare() }
        // Résilier, reprendre ou modifier : la feuille d'Apple, sans quitter l'app (D5).
        .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
        .onChangeCompat(of: showsManageSubscriptions) { _, shown in
            if !shown { Task { await store.refreshAfterManagingSubscriptions() } }
        }
        .background { refundSheetHost }
        .alert("Abonnement", isPresented: operationAlertBinding) {
            Button("OK") { store.clearOperationMessage() }
        } message: {
            Text(operationMessage ?? "")
        }
        .alert("Remboursement", isPresented: refundAlertBinding) {
            Button("OK") { refundMessage = nil }
        } message: {
            Text(refundMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            // Poussée depuis le Profil, la page se quitte par un retour ; ouverte
            // en feuille depuis une fonction Premium, elle se ferme.
            if entryPoint == .profile {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "paywall.back") { dismiss() }
            } else {
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "paywall.close") { dismiss() }
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("SignalQuest Premium")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.title")
                Text(entryPoint.introduction)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Mon abonnement

    private var presentation: SubscriptionStatusPresentation {
        SubscriptionStatusPresentation.make(serverState: store.serverState)
    }

    /// Une offre en cours se gère, elle ne se rachète pas : la carte d'achat
    /// disparaît tant qu'un abonnement court (contrat v1 §6, double abonnement).
    private var showsOffer: Bool {
        switch store.eligibility {
        case .managedByAppStore, .managedElsewhere: return false
        default: return true
        }
    }

    private var subscriptionCard: some View {
        let presentation = presentation
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: statusIcon(presentation.tone))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor(presentation.tone))
                    .frame(width: 40, height: 40)
                    .background(statusSoftColor(presentation.tone), in: Circle())
                    .accessibilityHidden(true)
                Text(verbatim: presentation.title)
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                Spacer(minLength: 0)
                if let tag = presentation.tag {
                    SQEditorialTag(text: tag, color: statusColor(presentation.tone))
                }
            }
            ForEach(presentation.details, id: \.self) { detail in
                Text(verbatim: detail)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            management(presentation.management)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.subscription")
    }

    @ViewBuilder
    private func management(_ management: SubscriptionStatusPresentation.Management) -> some View {
        switch management {
        case .none:
            EmptyView()
        case .elsewhere(let text):
            Label(text, systemImage: "info.circle")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .appStore(let canResume, let canRequestRefund):
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                GradientButton(
                    canResume ? String(localized: "Reprendre mon abonnement") : String(localized: "Gérer ou résilier mon abonnement"),
                    systemImage: canResume ? "arrow.uturn.backward.circle" : "creditcard",
                    style: canResume ? .primary : .secondary
                ) {
                    showsManageSubscriptions = true
                }
                .accessibilityIdentifier("paywall.manage")
                if canRequestRefund {
                    Button {
                        Task { await openRefundRequest() }
                    } label: {
                        Text("Demander un remboursement")
                            .font(SQType.button)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityIdentifier("paywall.refund")
                }
            }
        }
    }

    // MARK: Offre

    // Segments « Crème » : chips capsules partagées (actif brique / inactif surface).
    private var periodPicker: some View {
        SQSegmentedFilter(
            selection: $selectedPeriod,
            options: SubscriptionBillingPeriod.allCases.map { (value: $0, label: $0.displayName, icon: String?.none) }
        )
        .padding(.horizontal, -SQSpace.lg)
        .accessibilityHint("Choisis une facturation mensuelle ou annuelle")
    }

    /// L'unique carte d'offre, la seule grande surface brique de l'écran.
    private var premiumCard: some View {
        let identifier = SignalQuestSubscriptionProduct.product(tier: .premium, period: selectedPeriod)
        let product = store.product(for: .premium, period: selectedPeriod)
        let periodMatchesOffer = product.flatMap { product in
            product.subscription?.subscriptionPeriod
        }.map { SubscriptionPriceCopy.matchesSelection($0.unit, value: $0.value, selection: selectedPeriod) } ?? false
        let trial = identifier.flatMap { store.freeTrialOffer(for: $0) }
        // Encre pleine partout (TRX-13) : `onAccent` à 80 % sur brique tombait
        // vers 3,7:1. La hiérarchie tient à la taille des textes.
        let ink = SQColor.onAccent

        return VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(SupporterTier.premium.displayName)
                    .font(SQType.title)
                    .sqHeader()
                    .foregroundStyle(ink)
                if let trial, let product {
                    Text(verbatim: SubscriptionPriceCopy.trialLine(offer: trial, product: product))
                        .font(SQFont.display(18, .bold))
                        .foregroundStyle(ink)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                }
                Text(SubscriptionPriceCopy.priceLine(product: product))
                    .font(trial == nil ? SQFont.display(18, .bold) : SQType.callout)
                    .foregroundStyle(ink)
                    // Plafonné à AX3 : en AX5, « indisponible » se coupait en fin de mot (DEV-01).
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            }

            VStack(alignment: .leading, spacing: SQSpace.sm) {
                ForEach(premiumBenefits, id: \.self) { benefit in
                    Label(benefit, systemImage: "checkmark.circle.fill")
                        .font(SQType.callout)
                        .foregroundStyle(ink)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            // Le gratuit garde tout le Telecom : Premium n'en retire rien.
            Text("Restent gratuits pour tous : la carte, le speedtest, les relevés radio, l’identification des sites, les signalements et le partage.")
                .font(SQType.caption)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)

            if let product, let equivalent = SubscriptionPriceCopy.monthlyEquivalent(product: product) {
                Text(equivalent)
                    .font(SQType.caption)
                    .foregroundStyle(ink)
            }
            if product != nil && !periodMatchesOffer {
                Text("Période de l’App Store différente de l’offre choisie. Achat indisponible.")
                    .font(SQType.caption)
                    .foregroundStyle(ink)
            }

            GradientButton(
                trial == nil ? String(localized: "S’abonner à Premium") : String(localized: "Commencer l’essai gratuit"),
                systemImage: "sparkles",
                isBusy: isPurchasing,
                style: .primary
            ) {
                guard let identifier else { return }
                Task { await store.purchase(identifier) }
            }
            // Pas d'opacité en plus : le bouton désactivé est déjà grisé (TRX-13).
            .disabled(identifier == nil || !store.eligibility.canPurchase || !periodMatchesOffer)
            .accessibilityIdentifier("paywall.purchase")
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowAccent()
        .accessibilityElement(children: .contain)
    }

    private var restorationSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if showsOffer, let productLoadMessage = store.productLoadMessage {
                Label(productLoadMessage, systemImage: "info.circle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            // Les messages d'un abonnement en cours sont déjà dans sa carte.
            if showsOffer, store.eligibility != .allowed {
                Label(store.eligibility.userMessage, systemImage: "shield.checkered")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GradientButton(
                "Restaurer mes achats",
                systemImage: "arrow.clockwise",
                isBusy: store.operation == .restoring,
                style: .ghost
            ) {
                Task { await store.restorePurchases() }
            }
            .disabled(store.operation.isBusy)

            // Achat Apple présent sur l'appareil mais inconnu du serveur : il se
            // gère quand même dans la feuille d'Apple.
            if case .existingLocalAppStoreEntitlement = store.eligibility {
                Button {
                    showsManageSubscriptions = true
                } label: {
                    Label("Gérer dans l’App Store", systemImage: "creditcard")
                        .font(SQType.button)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SQColor.brandRed)
            }
        }
    }

    /// Mentions de la règle App Review 3.1.2 : titre, durée, prix par période,
    /// renouvellement automatique et sa résiliation, essai, liens vers les
    /// conditions et la confidentialité.
    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Premium est un abonnement mensuel ou annuel à renouvellement automatique, payé avec ton identifiant Apple à la confirmation de l’achat. Il se renouvelle au même prix, sauf résiliation au moins 24 heures avant la fin de la période en cours, depuis les réglages de ton compte Apple. Pas de partage familial. Le prix affiché par Apple au moment de l’achat fait foi.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsOffer, SignalQuestSubscriptionProduct.allCases.contains(where: { store.freeTrialOffer(for: $0) != nil }) {
                Text("Pendant l’essai gratuit, rien n’est prélevé. Sans résiliation au moins 24 heures avant sa fin, l’abonnement démarre et le premier paiement est prélevé.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SQSpace.lg) {
                Link("Conditions", destination: AppConfig.current.termsURL)
                Link("Confidentialité", destination: AppConfig.current.privacyURL)
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.brandRed)
            .frame(minHeight: 44)
        }
    }

    // MARK: Remboursement (D8)

    @ViewBuilder
    private var refundSheetHost: some View {
        if let refundTransactionID {
            Color.clear.refundRequestSheet(for: refundTransactionID, isPresented: $showsRefundRequest) { result in
                switch result {
                case .success(let status):
                    if status == .success {
                        refundMessage = String(localized: "Ta demande est transmise à Apple, qui te répondra par e-mail. Si elle est acceptée, Premium s’arrête à la date du remboursement.")
                    }
                case .failure:
                    refundMessage = String(localized: "La demande de remboursement n’a pas pu s’ouvrir. Réessaie plus tard.")
                }
            }
        }
    }

    private func openRefundRequest() async {
        guard let transactionID = await store.latestAppStoreTransactionID() else {
            refundMessage = String(localized: "Aucun achat App Store n’a été trouvé sur cet appareil pour cet abonnement. Connecte-toi à l’App Store avec l’identifiant Apple qui l’a souscrit.")
            return
        }
        refundTransactionID = transactionID
        showsRefundRequest = true
    }

    private var refundAlertBinding: Binding<Bool> {
        Binding(
            get: { refundMessage != nil },
            set: { presented in if !presented { refundMessage = nil } }
        )
    }

    // MARK: Statut

    private func statusIcon(_ tone: SubscriptionStatusPresentation.Tone) -> String {
        switch tone {
        case .neutral: return store.serverState.snapshot == nil ? "hourglass" : "person.crop.circle"
        case .positive: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ tone: SubscriptionStatusPresentation.Tone) -> Color {
        switch tone {
        case .neutral: return SQColor.labelSecondary
        case .positive: return SQColor.brandRed
        case .warning: return SQColor.warning
        }
    }

    /// Teinte douce de la pastille d'icône du statut (icône posée sur soft).
    private func statusSoftColor(_ tone: SubscriptionStatusPresentation.Tone) -> Color {
        switch tone {
        case .neutral: return SQColor.surfaceMuted
        case .positive: return SQColor.accentSoft
        case .warning: return SQColor.warningSoft
        }
    }

    private var operationAlertBinding: Binding<Bool> {
        Binding(
            get: { operationMessage != nil },
            set: { presented in if !presented { store.clearOperationMessage() } }
        )
    }

    private var operationMessage: String? {
        switch store.operation {
        case .pending:
            return String(localized: "L’achat attend une approbation, par exemple celle d’un parent. Premium s’activera dès qu’il sera accepté.")
        case .succeeded(let message), .failed(let message):
            return message
        case .idle, .purchasing, .restoring:
            return nil
        }
    }

    private var isPurchasing: Bool {
        if case .purchasing = store.operation { return true }
        return false
    }

    /// Avantages annoncés.
    ///
    /// RÈGLE : une ligne ici doit correspondre à un avantage EN LIGNE. Avec le
    /// contrat v1, le serveur sert la liste (`benefits.premium`, B9, D20) et
    /// l'app n'en affiche que les clés qu'elle connaît : `radio_log.unlimited`
    /// est ignoré (un iPhone ne fait que lire le journal, Q7), `reports.logo`
    /// aussi (Android seul, D15), `recap.monthly` et `profile.spotlight`
    /// attendent leur maquette (D13). Sans la liste (ancienne route), seul
    /// l'existant s'affiche. App Review souscrit pour vérifier : un avantage
    /// non livrable tombe sous la Guideline 2.3.1.
    ///
    /// NE PAS chiffrer un quota ici : il se règle au serveur sans redéployer.
    private var premiumBenefits: [String] {
        let known: [(key: String, text: String)] = [
            ("sentinelle.full", String(localized: "Sentinelle complète : plus de connexions surveillées, mesurées plus souvent")),
            ("stories.duration", String(localized: "Durée de vie des stories personnalisable, de 1 h à 72 h au lieu de 24 h")),
        ]
        let shown: [String]
        if let served = store.serverState.snapshot?.benefits?.premium {
            shown = known.filter { served.contains($0.key) }.map(\.text)
        } else {
            shown = known.map(\.text)
        }
        // Le badge est attribué par le serveur à tout membre Premium.
        return shown + [String(localized: "Badge Premium or sur ton profil et tes publications")]
    }
}
