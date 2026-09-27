import SwiftUI

/// Les antennes suivies.
///
/// Un favori n'est pas un marque-page mais une demande d'être prévenu : l'écran le dit en tête,
/// et met l'interrupteur de notification AVANT la liste. Sans lui, on pourrait suivre dix sites
/// et ne jamais comprendre pourquoi rien n'arrive.
struct FavoriteAntennasView: View {
    @EnvironmentObject private var networkPath: NetworkPathMonitor
    @ObservedObject var favorites: FavoriteAntennasService
    /// Ouvre la fiche du site depuis la liste. `nil` quand l'écran est présenté hors carte.
    var onOpenSite: ((FavoriteAntenna) -> Void)?

    var body: some View {
        List {
            Section {
                if favorites.hasLoaded {
                Toggle(
                    "Me prévenir en cas de panne",
                    isOn: Binding(
                        get: { favorites.notifyOnIssues },
                        set: { newValue in
                            guard let scope = favorites.captureActionScope() else { return }
                            Task { await favorites.setNotifyOnIssues(newValue, matching: scope) }
                        }
                    )
                )
                .tint(SQColor.brandRed)
                } else {
                    HStack {
                        Text("Me prévenir en cas de panne")
                        Spacer()
                        if favorites.isLoading { ProgressView() }
                        else { Text("Indisponible").foregroundStyle(SQColor.labelSecondary) }
                    }
                }
            } footer: {
                Text("Les antennes suivies sont les seules pour lesquelles vous êtes prévenu dès le premier signalement, sans attendre que la communauté confirme.")
            }
            .listRowBackground(SQColor.surface)

            if favorites.pendingCount > 0 || favorites.errorMessage != nil {
                Section {
                    if favorites.pendingCount > 0 {
                        Label {
                            if favorites.pendingCount == 1 { Text("Une modification en attente de synchronisation") }
                            else { Text("\(favorites.pendingCount) modifications en attente de synchronisation") }
                        } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                    }
                    if let error = favorites.errorMessage {
                        Text(error).font(SQType.caption).foregroundStyle(SQColor.dangerInk)
                    }
                    Button("Réessayer la synchronisation") { Task { await favorites.load() } }
                        .disabled(favorites.isSynchronizing || favorites.isLoading)
                } footer: {
                    Text("Les changements en attente restent sur cet appareil. Ils ne sont confirmés sur le compte qu’après synchronisation.")
                }
                .listRowBackground(SQColor.surface)
            }

            if favorites.favorites.isEmpty {
                Section {
                    if favorites.hasLoaded { emptyState }
                    else if favorites.isLoading { ProgressView("Chargement des favoris…") }
                    else { Text("La liste des favoris n’a pas pu être chargée.").foregroundStyle(SQColor.labelSecondary) }
                }
                .listRowBackground(SQColor.surface)
            } else {
                Section("Antennes suivies") {
                    ForEach(favorites.favorites) { favorite in
                        row(favorite)
                    }
                    .onDelete { offsets in
                        let current = favorites.favorites
                        let removed = offsets.compactMap { current.indices.contains($0) ? current[$0] : nil }
                        guard let scope = favorites.captureActionScope() else { return }
                        Task { for item in removed { await favorites.remove(item, matching: scope) } }
                    }
                }
                .listRowBackground(SQColor.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SQColor.bg)
        .navigationTitle("Antennes suivies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await favorites.load() }
        .refreshable { await favorites.load() }
        .onChangeCompat(of: networkPath.isOnline) { _, online in
            if online { Task { await favorites.load() } }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Aucune antenne suivie")
                .font(SQFont.body(15, .semibold))
                .foregroundStyle(SQColor.label)
            Text("Ouvrez la fiche d'une antenne sur la carte et touchez l'étoile. Vous serez prévenu dès qu'un problème y est signalé.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.vertical, SQSpace.xs)
    }

    @ViewBuilder
    private func row(_ favorite: FavoriteAntenna) -> some View {
        if let onOpenSite {
            Button { onOpenSite(favorite) } label: { rowContent(favorite) }.buttonStyle(.plain)
        } else {
            rowContent(favorite)
        }
    }

    private func rowContent(_ favorite: FavoriteAntenna) -> some View {
        HStack(spacing: SQSpace.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(favorite.displayName)
                        .font(SQFont.body(14.5, .semibold))
                        .foregroundStyle(SQColor.label)
                    HStack(spacing: SQSpace.xs) {
                        if let op = favorite.operator, !op.isEmpty {
                            Text(op)
                        }
                        Text(favorite.market)
                    }
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
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
            .frame(minHeight: 44)
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

    private var isOn: Bool { favorites.isFavorite(siteId: siteId, market: market) }

    var body: some View {
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
            ? (isOn ? Text("Ne plus suivre cette antenne") : Text("Suivre cette antenne")) : Text("Charger les favoris"))
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
