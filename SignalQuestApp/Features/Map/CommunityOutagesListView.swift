import SwiftUI

/// Les deux onglets de la page : ce que fait la communauté, et ce que j'y ai mis.
enum OutageFeedScope: String, CaseIterable, Identifiable {
    case all
    case mine

    var id: String { rawValue }
    var label: String { self == .all ? "Toutes" : "Les miennes" }
}

@MainActor
final class CommunityOutagesListViewModel: ObservableObject {
    @Published var scope: OutageFeedScope = .all { didSet { Task { await reload() } } }
    @Published private(set) var outages: [CommunityOutage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published var errorMessage: String?

    private let service: CommunityOutageServicing
    private let pageSize = 30

    init(service: CommunityOutageServicing) { self.service = service }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await fetch(offset: 0, replacing: true)
    }

    func loadMoreIfNeeded(after outage: CommunityOutage) async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        // On déclenche sur l'avant-dernière ligne : attendre la dernière ferait apparaître le
        // chargement APRÈS que le doigt a atteint le bas, ce qui se lit comme une saccade.
        guard outages.suffix(2).contains(where: { $0.id == outage.id }) else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetch(offset: outages.count, replacing: false)
    }

    /// Confirme ou dément depuis la liste.
    ///
    /// Recharge plutôt que de retoucher la ligne : un vote peut faire basculer l'état de la panne
    /// — et donc les boutons de la ligne d'à côté —, et seul le serveur sait quand.
    func vote(outageId: String, kind: String) async {
        do {
            _ = try await service.vote(
                outageId: outageId,
                kind: kind,
                latitude: nil,
                longitude: nil,
                accuracyMeters: nil
            )
            await reload()
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fetch(offset: Int, replacing: Bool) async {
        do {
            let page = try await service.feed(scope: scope, offset: offset, limit: pageSize)
            outages = replacing ? page.outages : outages + page.outages
            hasMore = page.hasMore
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
            if replacing { outages = [] }
        }
    }
}

/// « Pannes signalées » — la page d'arbitrage.
///
/// Sa raison d'être est de pouvoir CONFIRMER ou DÉMENTIR sans avoir à retrouver chaque antenne
/// sur la carte. C'est ce qui permet à une panne rurale d'atteindre son seuil, là où il faudrait
/// sinon que trois personnes ouvrent spontanément la même fiche.
struct CommunityOutagesListView: View {
    @StateObject private var model: CommunityOutagesListViewModel

    init(service: CommunityOutageServicing) {
        _model = StateObject(wrappedValue: CommunityOutagesListViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                Picker("Portée", selection: $model.scope) {
                    ForEach(OutageFeedScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: SQSpace.lg, bottom: SQSpace.sm, trailing: SQSpace.lg))
            }

            if let error = model.errorMessage, model.outages.isEmpty {
                Section {
                    ErrorStateView(title: "Pannes indisponibles", message: error) {
                        Task { await model.reload() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if !model.isLoading, model.outages.isEmpty {
                Section {
                    EmptyStateView(
                        title: model.scope == .mine ? "Rien signalé pour l'instant" : "Aucune panne signalée",
                        message: model.scope == .mine
                            ? "Ouvrez la fiche d'une antenne sur la carte pour signaler une panne, ou confirmez celle de quelqu'un d'autre."
                            : "Personne n'a signalé de panne en ce moment. Bonne nouvelle.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(model.outages) { outage in
                        row(outage)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: SQSpace.lg, bottom: 5, trailing: SQSpace.lg))
                            .task { await model.loadMoreIfNeeded(after: outage) }
                    }
                    if model.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Pannes signalées")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.outages.isEmpty { await model.reload() } }
        .refreshable { await model.reload() }
        .overlay {
            if model.isLoading && model.outages.isEmpty { ProgressView() }
        }
    }

    /// Une panne dans la liste.
    ///
    /// Le site et l'opérateur EN TÊTE, avant l'état : on parcourt cette page en cherchant « est-ce
    /// que je connais cet endroit ? », pas « combien de gens ont voté ».
    private func row(_ outage: CommunityOutage) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .center, spacing: SQSpace.sm) {
                Circle()
                    .fill(accent(outage))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outage.siteName?.isEmpty == false ? outage.siteName! : outage.targetId)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text(subtitle(outage))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
            }

            if !outage.affectedServicesLabel.isEmpty {
                Text("Touché : \(outage.affectedServicesLabel)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            if outage.state.isVisible {
                // Même bloc que la fiche antenne : confirmer depuis la liste et confirmer depuis
                // la carte doivent être le même geste, avec les mêmes mots.
                CommunityOutageCard(
                    outages: [outage],
                    onReport: nil,
                    onVote: { id, kind in Task { await model.vote(outageId: id, kind: kind) } }
                )
            } else {
                // Panne close — « Les miennes » les garde en mémoire. Le bloc d'arbitrage ne
                // connaît que les pannes ouvertes et n'aurait rien affiché ici.
                Text(closedReason(outage))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .sqShadowCard()
    }

    /// La pastille suit ce qu'est DEVENUE la panne, pas ce qu'elle a été : garder le rouge de
    /// sévérité sur une panne rétablie ferait lire un incident en cours dans « Les miennes ».
    private func accent(_ outage: CommunityOutage) -> Color {
        switch outage.state {
        case .resolved: return OutageTint.resolved
        case .rejected, .dormant: return SQColor.labelTertiary
        default: return OutageTint.of(outage.severity)
        }
    }

    private func subtitle(_ outage: CommunityOutage) -> String {
        var parts = [outage.operatorKey, stateLabel(outage)]
        if outage.state == .reported, outage.confirmationsRemaining > 0 {
            parts.append("encore \(outage.confirmationsRemaining)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Distinct du libellé de la fiche antenne : celui-ci ne voit que des pannes ouvertes et
    /// retombe sur « Panne signalée » pour tout le reste, ce qui ferait passer une panne rétablie
    /// pour une panne en cours.
    private func stateLabel(_ outage: CommunityOutage) -> String {
        switch outage.state {
        case .resolved: return "Rétablie"
        case .rejected: return "Écartée"
        case .dormant: return "En veille"
        case .confirmed: return outage.operatorConfirmed ? "Confirmée par l'opérateur" : "Panne confirmée"
        case .reported: return "Panne signalée"
        }
    }

    private func closedReason(_ outage: CommunityOutage) -> String {
        switch outage.state {
        case .rejected: return "La communauté n'a pas retrouvé cette panne."
        case .dormant: return "Sans nouvelle depuis un moment. Elle se refermera seule."
        default: return "Le réseau est revenu. Merci de l'avoir signalée."
        }
    }
}
