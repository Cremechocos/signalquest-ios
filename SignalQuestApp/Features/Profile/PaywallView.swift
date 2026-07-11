import StoreKit
import SwiftUI

enum PaywallEntryPoint: Equatable, Sendable {
    case profile
    case premiumFeature(String)

    var kicker: String {
        switch self {
        case .profile: return "Abonnements"
        case .premiumFeature: return "Fonction Premium"
        }
    }

    var introduction: String {
        switch self {
        case .profile:
            return "Soutiens SignalQuest et débloque des outils avancés. Les mesures réseau essentielles restent gratuites."
        case .premiumFeature(let name):
            return "« \(name) » fait partie de Premium. Compare les offres sans perdre ce que tu étais en train de faire."
        }
    }
}

struct PaywallView: View {
    @ObservedObject private var store: EntitlementsStore
    private let entryPoint: PaywallEntryPoint
    @State private var selectedPeriod = SubscriptionBillingPeriod.monthly

    init(store: EntitlementsStore, entryPoint: PaywallEntryPoint = .profile) {
        _store = ObservedObject(wrappedValue: store)
        self.entryPoint = entryPoint
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header
                entitlementStatusCard
                periodPicker
                planCard(tier: .basic)
                planCard(tier: .premium)
                restorationSection
                legalFooter
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge)
        }
        .signalQuestBackground()
        .navigationTitle("Abonnements")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.prepare() }
        .refreshable { await store.prepare() }
        .alert("Abonnement", isPresented: operationAlertBinding) {
            Button("OK") { store.clearOperationMessage() }
        } message: {
            Text(operationMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(entryPoint.kicker).sqKicker()
            Text("Choisis ton niveau d’exploration")
                .font(SQType.display)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(entryPoint.introduction)
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var entitlementStatusCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: entitlementStatusIcon)
                    .font(.body.weight(.bold))
                    .foregroundStyle(entitlementStatusColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text("Ton offre : \(store.activeTier.displayName)")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text(entitlementStatusMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if store.activeTier != .free {
                    SQEditorialTag(
                        text: store.activeTier.displayName,
                        color: store.activeTier == .premium ? SQColor.brandRed : SQColor.labelSecondary
                    )
                }
            }

            if let expiration = store.serverState.snapshot?.expiresAt {
                Text("Échéance : \(expiration.formatted(date: .abbreviated, time: .omitted))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(entitlementStatusColor.opacity(0.55), lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var periodPicker: some View {
        Picker("Période de facturation", selection: $selectedPeriod) {
            ForEach(SubscriptionBillingPeriod.allCases) { period in
                Text(period.displayName).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Choisis une facturation mensuelle ou annuelle")
    }

    private func planCard(tier: SupporterTier) -> some View {
        let identifier = SignalQuestSubscriptionProduct.product(tier: tier, period: selectedPeriod)
        let product = store.product(for: tier, period: selectedPeriod)
        let isCurrentOrLower = store.activeTier.rank >= tier.rank

        return VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(tier.displayName)
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                    Text(priceText(product: product, identifier: identifier))
                        .font(SQFont.archivo(18, .bold, relativeTo: .headline))
                        .foregroundStyle(tier == .premium ? SQColor.brandRed : SQColor.label)
                }
                Spacer()
                SQEditorialTag(
                    text: tier == .premium ? "Le plus complet" : "L’essentiel +",
                    color: tier == .premium ? SQColor.brandRed : SQColor.labelSecondary
                )
            }

            VStack(alignment: .leading, spacing: SQSpace.sm) {
                ForEach(benefits(for: tier), id: \.self) { benefit in
                    Label(benefit, systemImage: "checkmark.circle.fill")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.label)
                        .symbolRenderingMode(.hierarchical)
                }
            }

            if tier == .premium, selectedPeriod == .annual {
                Text("Environ 6,67 € / mois, facturé annuellement.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else if tier == .basic, selectedPeriod == .annual {
                Text("Environ 2,50 € / mois, facturé annuellement.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            GradientButton(
                purchaseButtonTitle(tier: tier, isCurrentOrLower: isCurrentOrLower),
                systemImage: isCurrentOrLower ? "checkmark.seal.fill" : "sparkles",
                isBusy: isPurchasing(tier),
                style: tier == .premium ? .primary : .secondary
            ) {
                guard let identifier else { return }
                Task { await store.purchase(identifier) }
            }
            .disabled(isCurrentOrLower || identifier == nil || !store.eligibility.canPurchase || product == nil)
            .opacity(isCurrentOrLower || !store.eligibility.canPurchase || product == nil ? 0.62 : 1)
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(tier == .premium ? SQColor.brandRed : SQColor.separator, lineWidth: tier == .premium ? 2 : 1.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var restorationSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if let productLoadMessage = store.productLoadMessage {
                Label(productLoadMessage, systemImage: "info.circle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            Label(store.eligibility.userMessage, systemImage: "shield.checkered")
                .font(SQType.caption)
                .foregroundStyle(store.eligibility.canPurchase ? SQColor.success : SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            GradientButton(
                "Restaurer mes achats",
                systemImage: "arrow.clockwise",
                isBusy: store.operation == .restoring,
                style: .ghost
            ) {
                Task { await store.restorePurchases() }
            }
            .disabled(store.operation.isBusy)

            if shouldShowManageSubscription,
               let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                Link(destination: url) {
                    Label("Gérer dans l’App Store", systemImage: "arrow.up.right.square")
                        .font(SQType.button)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SQColor.brandRed)
                .frame(minHeight: 44)
            }
        }
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Aucun essai gratuit et aucun partage familial. L’abonnement se renouvelle automatiquement et peut être résilié depuis les réglages App Store. Le prix affiché par Apple au moment de l’achat fait foi.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SQSpace.lg) {
                Link("Conditions", destination: AppConfig.current.termsURL)
                Link("Confidentialité", destination: AppConfig.current.privacyURL)
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.brandRed)
            .frame(minHeight: 44)
        }
    }

    private var entitlementStatusMessage: String {
        switch store.serverState {
        case .idle, .loading:
            return "Vérification des droits multiplateformes…"
        case .unavailable:
            return "Le serveur de droits est indisponible. Les nouveaux achats sont bloqués par sécurité."
        case .available(let snapshot):
            if snapshot.status == .paymentFailed {
                return "Paiement à régulariser auprès de \(snapshot.source.displayName)."
            }
            if snapshot.tier != .free {
                return "Géré par \(snapshot.source.displayName)."
            }
            if store.localEntitlementTier != .free {
                return "Achat Apple détecté localement, confirmation serveur en attente."
            }
            return "Aucun abonnement actif."
        }
    }

    private var entitlementStatusIcon: String {
        switch store.serverState {
        case .unavailable: return "exclamationmark.triangle.fill"
        case .idle, .loading: return "hourglass"
        case .available: return store.activeTier == .free ? "person.crop.circle" : "checkmark.seal.fill"
        }
    }

    private var entitlementStatusColor: Color {
        switch store.serverState {
        case .unavailable: return SQColor.warning
        case .idle, .loading: return SQColor.labelSecondary
        case .available(let snapshot):
            if snapshot.status == .paymentFailed { return SQColor.warning }
            return store.activeTier == .premium ? SQColor.brandRed : SQColor.success
        }
    }

    private var shouldShowManageSubscription: Bool {
        store.serverState.snapshot?.source == .appStore || store.localEntitlementTier != .free
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
            return "L’achat est en attente de validation par l’App Store."
        case .succeeded(let message), .failed(let message):
            return message
        case .idle, .purchasing, .restoring:
            return nil
        }
    }

    private func isPurchasing(_ tier: SupporterTier) -> Bool {
        guard case .purchasing(let product) = store.operation else { return false }
        return product.tier == tier
    }

    private func priceText(product: Product?, identifier: SignalQuestSubscriptionProduct?) -> String {
        if let product {
            return "\(product.displayPrice) / \(selectedPeriod == .monthly ? "mois" : "an")"
        }
        return identifier?.plannedDisplayPrice ?? "Offre indisponible"
    }

    private func purchaseButtonTitle(tier: SupporterTier, isCurrentOrLower: Bool) -> String {
        if isCurrentOrLower { return "Déjà inclus dans ton offre" }
        if case .existingBackendEntitlement = store.eligibility { return "Déjà abonné ailleurs" }
        if !store.eligibility.canPurchase { return "Bientôt disponible sur iOS" }
        return "Choisir \(tier.displayName)"
    }

    private func benefits(for tier: SupporterTier) -> [String] {
        switch tier {
        case .free:
            return []
        case .basic:
            return [
                "Badge Basic argenté, masquable",
                "Journal synchronisé entre tes appareils",
                "Accès anticipé à certains outils communautaires",
            ]
        case .premium:
            return [
                "Analyses détaillées du comparateur",
                "Tendances et alertes avancées du journal",
                "Stories personnalisées de 1 à 72 heures",
                "Badge Premium or et rouge, masquable",
            ]
        }
    }
}
