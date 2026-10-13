import SwiftUI
import CoreLocation

/// Les antennes suivies.
///
/// Un favori n'est pas un marque-page mais une demande d'être prévenu : l'écran le dit en tête,
/// et met l'interrupteur de notification AVANT la liste. Sans lui, on pourrait suivre dix sites
/// et ne jamais comprendre pourquoi rien n'arrive.
struct FavoriteAntennasView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var networkPath: NetworkPathMonitor
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var favorites: FavoriteAntennasService
    /// Registre des marchés, pour écrire « Orange » et « France » au lieu de « ORANGE » et « FR ».
    @State private var registry: MarketRegistryPayload?
    /// Ouvre la fiche du site depuis la liste. `nil` quand l'écran est présenté hors carte.
    var onOpenSite: ((FavoriteAntenna) -> Void)?

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.md, trailing: 0))
                    .listRowBackground(Color.clear)
                notifyCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)

            if favorites.pendingCount > 0 || favorites.errorMessage != nil {
                Section {
                    pendingNotice
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if favorites.favorites.isEmpty {
                Section {
                    Group {
                        if favorites.hasLoaded { emptyState }
                        else if favorites.isLoading {
                            ProgressView("Chargement des antennes suivies…").frame(maxWidth: .infinity)
                        } else {
                            // L'état hors ligne commun, qui se recharge seul au retour du réseau.
                            ErrorStateView(
                                title: "Antennes suivies indisponibles",
                                message: favorites.errorMessage ?? String(localized: "La liste n’a pas pu être chargée. Vérifie ta connexion.")
                            ) {
                                Task { await favorites.load() }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(favorites.favorites) { favorite in
                        row(favorite)
                            .listRowBackground(SQColor.surface)
                            .listRowSeparatorTint(SQColor.separator)
                    }
                    .onDelete { offsets in
                        let current = favorites.favorites
                        let removed = offsets.compactMap { current.indices.contains($0) ? current[$0] : nil }
                        guard let scope = favorites.captureActionScope() else { return }
                        Task { for item in removed { await favorites.remove(item, matching: scope) } }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(favorites.favorites.count) antennes").sqKicker()
                        Spacer(minLength: SQSpace.sm)
                        Text("Glisser pour retirer")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .textCase(nil)
                } footer: {
                    Text("Touche l’étoile d’une fiche antenne pour en suivre une autre.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, SQSpace.xs)
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle("Antennes suivies")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .task { await favorites.load() }
        .task { registry = await services.markets.registry() }
        .refreshable { await favorites.load() }
        .onChangeCompat(of: networkPath.isOnline) { _, online in
            if online { Task { await favorites.load() } }
        }
    }

    /// Grand titre et explication en tête : un favori n'est pas un marque-page,
    /// c'est une demande d'alerte.
    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "favorites.back") { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Antennes suivies")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                Text("Les antennes suivies sont les seules pour lesquelles tu reçois une alerte dès le premier signalement, sans attendre que la communauté confirme.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// L'interrupteur et son état. Tant que la liste n'est pas chargée, il est
    /// grisé et dit pourquoi, au lieu d'un « Indisponible » sans motif.
    private var notifyCard: some View {
        HStack(spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: "exclamationmark.triangle", size: 38, tint: SQColor.accentInk, fill: SQColor.accentSoft,
                           font: SQFont.body(17, .semibold, relativeTo: .body))
            Toggle(isOn: Binding(
                get: { favorites.notifyOnIssues },
                set: { newValue in
                    guard let scope = favorites.captureActionScope() else { return }
                    Task { await favorites.setNotifyOnIssues(newValue, matching: scope) }
                    // Une alerte sans notifications n'arrive jamais (TRX-01).
                    if newValue {
                        Task { await services.notificationPriming.considerPriming(after: .antennaAlert) }
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Me prévenir en cas de panne")
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                    Text(notifyState)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(SQColor.brandRed)
            .disabled(!favorites.hasLoaded)
        }
        .padding(SQSpace.md)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private var notifyState: String {
        if !favorites.hasLoaded {
            return favorites.isLoading
                ? String(localized: "Chargement…")
                : String(localized: "Indisponible hors connexion")
        }
        return favorites.notifyOnIssues
            ? String(localized: "Notifications activées")
            : String(localized: "Notifications désactivées")
    }

    /// Modifications en attente : une notice ambre, avec de quoi réessayer.
    private var pendingNotice: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            SQNotice(
                message: favorites.errorMessage
                    ?? String(localized: "Les changements en attente restent sur cet appareil. Ils ne sont confirmés sur le compte qu’après synchronisation."),
                title: favorites.pendingCount == 0 ? nil
                    : favorites.pendingCount == 1
                        ? String(localized: "Une modification en attente de synchronisation")
                        : String(localized: "\(favorites.pendingCount) modifications en attente de synchronisation"),
                systemImage: "arrow.triangle.2.circlepath",
                tone: .warning
            )
            GradientButton("Réessayer", systemImage: "arrow.clockwise", style: .secondary) {
                Task { await favorites.load() }
            }
            .disabled(favorites.isSynchronizing || favorites.isLoading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: SQSpace.md) {
            EmptyStateView(
                title: "Aucune antenne suivie",
                message: "Ouvre la fiche d'une antenne sur la carte et touche l'étoile. Tu recevras une alerte dès qu'un problème y est signalé.",
                systemImage: "star"
            )
            GradientButton("Ouvrir la carte", systemImage: "map", style: .secondary) {
                router.selectedTab = .map
            }
            .fixedSize()
        }
        .padding(.vertical, SQSpace.lg)
    }

    @ViewBuilder
    private func row(_ favorite: FavoriteAntenna) -> some View {
        if let onOpenSite {
            Button { onOpenSite(favorite) } label: { rowContent(favorite) }.buttonStyle(.plain)
        } else {
            rowContent(favorite)
        }
    }

    /// Nom du pays dans la langue de l'app ; le code brut tant que le registre n'a pas répondu.
    private func marketName(_ market: String) -> String {
        let entry = registry?.market(forCode: market)
        let code = (entry?.countryCode ?? market).trimmingCharacters(in: .whitespaces).uppercased()
        return Locale.current.localizedString(forRegionCode: code) ?? entry?.label ?? market
    }

    /// La couleur de l'opérateur, le nom, puis l'opérateur, le pays et la
    /// distance : la liste sert de tableau de bord, pas seulement de noms.
    private func rowContent(_ favorite: FavoriteAntenna) -> some View {
        let operatorName = favorite.operator.flatMap { $0.isEmpty ? nil : $0 }
            .map { MarketRegistryEntry.operatorLabel($0, in: registry?.market(forCode: favorite.market)) }
        return HStack(spacing: SQSpace.sm) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SQBrand.operatorColor(operatorName))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.displayName)
                    .font(SQType.callout(.bold))
                    .foregroundStyle(SQColor.label)
                Text(([operatorName, marketName(favorite.market), distanceLabel(favorite)].compactMap { $0 })
                    .joined(separator: " · "))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if favorites.isPending(siteId: favorite.siteId, market: favorite.market) {
                Image(systemName: "clock").accessibilityLabel("Synchronisation en attente")
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if onOpenSite != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func distanceLabel(_ favorite: FavoriteAntenna) -> String? {
        guard let latitude = favorite.latitude, let longitude = favorite.longitude,
              let here = services.location.cachedLocation() else { return nil }
        return SQUnits.distance(meters: here.distance(from: CLLocation(latitude: latitude, longitude: longitude)))
    }
}

/// Marges d'une liste groupée sous un en-tête maison : sans elles, la liste
/// laisse une cinquantaine de points vides sous la barre d'état. Disponible à
/// partir d'iOS 17 ; iOS 16 garde les marges du système.
struct CompactListMargins: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentMargins(.top, SQSpace.sm, for: .scrollContent)
                .listSectionSpacing(SQSpace.lg)
        } else {
            content
        }
    }
}

/// L'étoile de suivi, posée dans la fiche antenne.
///
/// Optimiste : l'état bascule au doigt, le service remet l'état d'avant si le serveur refuse.
/// Attendre l'aller-retour ferait douter d'un simple appui.
struct FavoriteAntennaButton: View {
    @ObservedObject var favorites: FavoriteAntennasService
    let siteId: String
    let market: String
    let operatorName: String?
    let name: String?
    let address: String?
    let latitude: Double?
    let longitude: Double?
    @State private var showsSyncError = false
    @EnvironmentObject private var session: AuthSessionViewModel

    private var isOn: Bool { favorites.isFavorite(siteId: siteId, market: market) }

    /// Sans compte, aucun suivi possible : l'étoile restait sans effet (AF-CARTE-13).
    @ViewBuilder
    var body: some View {
        if case .authenticated = session.state {
            star
        }
    }

    private var star: some View {
        Button {
            guard let scope = favorites.captureActionScope() else { return }
            Task {
                // Si l'état est inconnu, ce premier geste le charge. Il ne doit
                // pas retirer un favori que l'ancienne étoile vide ne montrait pas.
                guard favorites.hasLoaded else {
                    await favorites.load()
                    if favorites.isCurrent(scope) { showsSyncError = favorites.errorMessage != nil }
                    return
                }
                await favorites.toggle(
                    FavoriteAntenna(
                        siteId: siteId,
                        market: market,
                        operator: operatorName,
                        name: name,
                        address: address,
                        latitude: latitude,
                        longitude: longitude
                    ), matching: scope
                )
                if favorites.isCurrent(scope) { showsSyncError = favorites.errorMessage != nil }
            }
        } label: {
            Image(systemName: favorites.hasLoaded ? (isOn ? "star.fill" : "star") : "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? SQColor.warning : SQColor.labelSecondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(favorites.isLoading && !favorites.hasLoaded)
        .accessibilityLabel(favorites.hasLoaded
            ? (isOn ? Text("Ne plus suivre cette antenne") : Text("Suivre cette antenne")) : Text("Charger les antennes suivies"))
        .accessibilityHint(favorites.isPending(siteId: siteId, market: market)
            ? Text("Synchronisation en attente") : Text(""))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .alert("Synchronisation des favoris", isPresented: $showsSyncError) {
            Button("Réessayer") { Task { await favorites.load() } }
            Button("Fermer", role: .cancel) {}
        } message: {
            Text(favorites.errorMessage ?? String(localized: "Les changements restent en attente sur cet appareil."))
        }
    }
}
