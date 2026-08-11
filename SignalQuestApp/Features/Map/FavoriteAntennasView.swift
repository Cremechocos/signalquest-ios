import SwiftUI

/// Les antennes suivies.
///
/// Un favori n'est pas un marque-page mais une demande d'être prévenu : l'écran le dit en tête,
/// et met l'interrupteur de notification AVANT la liste. Sans lui, on pourrait suivre dix sites
/// et ne jamais comprendre pourquoi rien n'arrive.
struct FavoriteAntennasView: View {
    @EnvironmentObject private var services: AppServices
    @ObservedObject var favorites: FavoriteAntennasService
    /// Ouvre la fiche du site depuis la liste. `nil` quand l'écran est présenté hors carte.
    var onOpenSite: ((FavoriteAntenna) -> Void)?

    var body: some View {
        List {
            Section {
                Toggle(
                    "Me prévenir en cas de panne",
                    isOn: Binding(
                        get: { favorites.notifyOnIssues },
                        set: { newValue in Task { await favorites.setNotifyOnIssues(newValue) } }
                    )
                )
                .tint(SQColor.brandRed)
            } footer: {
                Text("Les antennes suivies sont les seules pour lesquelles vous êtes prévenu dès le premier signalement, sans attendre que la communauté confirme.")
            }
            .listRowBackground(SQColor.surface)

            if favorites.favorites.isEmpty {
                Section {
                    emptyState
                }
                .listRowBackground(SQColor.surface)
            } else {
                Section("Antennes suivies") {
                    ForEach(favorites.favorites) { favorite in
                        row(favorite)
                    }
                    .onDelete { offsets in
                        // `PUT` remplace la liste entière : on retire puis on renvoie tout.
                        let removed = offsets.map { favorites.favorites[$0] }
                        Task { for item in removed { await favorites.toggle(item) } }
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
        .overlay {
            if favorites.isLoading && favorites.favorites.isEmpty {
                ProgressView()
            }
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

    private func row(_ favorite: FavoriteAntenna) -> some View {
        Button {
            onOpenSite?(favorite)
        } label: {
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
                if onOpenSite != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(onOpenSite == nil)
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

    private var isOn: Bool { favorites.isFavorite(siteId: siteId, market: market) }

    var body: some View {
        Button {
            Task {
                await favorites.toggle(
                    FavoriteAntenna(
                        siteId: siteId,
                        market: market,
                        operator: operatorName,
                        name: name,
                        address: address,
                        latitude: latitude,
                        longitude: longitude
                    )
                )
            }
        } label: {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? SQColor.warning : SQColor.labelSecondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Ne plus suivre cette antenne" : "Suivre cette antenne")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
