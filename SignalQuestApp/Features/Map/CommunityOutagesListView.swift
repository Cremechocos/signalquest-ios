import SwiftUI

/// Les deux onglets de la page : ce que fait la communauté, et ce que j'y ai mis.
enum OutageFeedScope: String, CaseIterable, Identifiable {
    case all
    case mine

    var id: String { rawValue }
    /// `String(localized:)` et non un littéral : `SQSegmentedFilter` rend un `Text(String)`, qui
    /// ne traduit pas — l'onglet serait resté français dans une app anglaise.
    var label: String {
        self == .all ? String(localized: "Toutes") : String(localized: "Les miennes")
    }
}

@MainActor
final class CommunityOutagesListViewModel: ObservableObject {
    @Published var scope: OutageFeedScope = .all { didSet { Task { await reload() } } }
    @Published private(set) var outages: [CommunityOutage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    /// Panne dont la fermeture est en vol : son bouton s'y remplace par un indicateur.
    @Published private(set) var closingId: String?
    @Published var errorMessage: String?

    private let service: CommunityOutageServicing
    private let markets: MarketRegistryServicing
    private let pageSize = 30
    /// Registre des marchés, pour écrire « Orange » là où la panne ne porte que « ORANGE ».
    /// Chaque ligne a son propre `marketCode` : la page mélange les marchés, on ne peut donc pas
    /// se contenter du marché courant de la carte.
    private var registry: MarketRegistryPayload = .empty

    init(service: CommunityOutageServicing, markets: MarketRegistryServicing) {
        self.service = service
        self.markets = markets
    }

    /// Le nom d'opérateur du registre, résolu par le SEUL helper de l'app.
    ///
    /// Retombe sur la clé brute tant que le registre n'a pas répondu — c'est ce que faisait la
    /// page en permanence, et la seule chose de moins faux qu'on ait à cet instant.
    func operatorLabel(_ outage: CommunityOutage) -> String {
        MarketRegistryEntry.operatorLabel(outage.operatorKey, in: registry.market(forCode: outage.marketCode))
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        // Le registre AVANT la page : sinon la première liste s'affiche avec les clés brutes,
        // puis se réécrit sous les yeux. `registry()` ne lève jamais et sert son cache mémoire
        // dès le deuxième appel.
        if registry.markets.isEmpty { registry = await markets.registry() }
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
            errorMessage = OutageWriteError.message(for: error)
        }
    }

    /// L'auteur referme sa panne.
    ///
    /// Recharge intégralement au lieu de remplacer la ligne par la panne renvoyée : la fermeture
    /// est IMMÉDIATE et vaut pour tout le monde, donc l'onglet « Toutes » derrière ne doit plus
    /// la porter non plus. Le refus est écrit par le client sur le CODE reçu — `NOT_AUTHOR` et
    /// `OUTAGE_CLOSED` ne se disent pas pareil, et la phrase du serveur n'existe qu'en français.
    func close(outageId: String) async {
        guard closingId == nil else { return }
        closingId = outageId
        errorMessage = nil
        defer { closingId = nil }
        do {
            _ = try await service.close(outageId: outageId)
            await reload()
        } catch {
            if error.isCancellation { return }
            errorMessage = OutageWriteError.message(for: error)
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
    @EnvironmentObject private var router: AppRouter
    /// Panne dont la fermeture attend confirmation. Le geste est irréversible et collectif : il
    /// ne part jamais du premier appui.
    @State private var pendingClose: CommunityOutage?

    init(service: CommunityOutageServicing, markets: MarketRegistryServicing) {
        _model = StateObject(wrappedValue: CommunityOutagesListViewModel(service: service, markets: markets))
    }

    var body: some View {
        List {
            Section {
                SQSegmentedFilter(
                    selection: $model.scope,
                    options: OutageFeedScope.allCases.map { (value: $0, label: $0.label, icon: String?.none) }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.sm, trailing: 0))
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
                    // Une erreur survenue APRÈS le premier chargement — un vote ou une fermeture
                    // refusés. L'état d'erreur plein écran ne la montrerait pas : il ne s'affiche
                    // que sur une liste vide, et celle-ci ne l'est plus.
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.warning)
                            .padding(SQSpace.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: SQSpace.lg, bottom: 5, trailing: SQSpace.lg))
                    }
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
        // `alert` et non `confirmationDialog`, contrairement au retrait d'une identification :
        // fermer une panne est irréversible ET collectif, donc les deux issues doivent être
        // NOMMÉES et la phrase qui explique la portée doit rester lisible. Or l'affichage d'un
        // `confirmationDialog` dépend du contexte — en popover, la documentation d'Apple ne
        // garantit pas que le titre soit rendu (`titleVisibility` est une préférence). Une
        // `alert` porte toujours son titre, son message et ses deux boutons.
        .alert(
            "Refermer cette panne ?",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            presenting: pendingClose
        ) { outage in
            Button("Refermer", role: .destructive) {
                pendingClose = nil
                Task { await model.close(outageId: outage.id) }
            }
            Button("Annuler", role: .cancel) { pendingClose = nil }
        } message: { _ in
            Text("Elle disparaîtra de la carte pour tout le monde, tout de suite. On ne peut pas revenir en arrière.")
        }
    }

    // MARK: - Ligne

    /// Une panne dans la liste.
    ///
    /// Le lieu EN TÊTE — nom du site, puis ADRESSE — avant l'état : on parcourt cette page en
    /// cherchant « est-ce que je connais cet endroit ? », pas « combien de gens ont voté ». Cette
    /// tête de ligne est aussi la zone de tap qui renvoie à la carte ; l'arbitrage en dessous garde
    /// ses propres boutons, un appui n'y déclenche donc jamais deux choses à la fois.
    private func row(_ outage: CommunityOutage) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Button {
                Haptics.selection()
                router.route(toCommunityOutage: outage)
            } label: {
                placeHeader(outage)
            }
            .buttonStyle(.plain)
            // Portée par un `Text` : la surcharge `StringProtocol` d'`accessibilityLabel` ne
            // traduit rien, et dix « voir sur la carte » identiques ne diraient pas à VoiceOver
            // lequel on survole — d'où le nom du lieu en tête.
            .accessibilityLabel(Text("\(siteLabel(outage)) — voir sur la carte"))
            .accessibilityAddTraits(.isButton)

            if outage.state.isVisible {
                // L'ARBITRAGE seul, jamais la carte de la fiche antenne : celle-ci porte son
                // propre en-tête d'état, qui réécrivait « Panne signalée » et « Touché : … »
                // immédiatement sous la tête de ligne qui venait de les dire. Le geste, lui,
                // reste rigoureusement le même qu'ailleurs.
                OutageArbitrationBlock(
                    outage: outage,
                    onVote: { id, kind in Task { await model.vote(outageId: id, kind: kind) } }
                )
            } else {
                // Panne close — « Les miennes » les garde en mémoire. Le bloc d'arbitrage ne
                // connaît que les pannes ouvertes et n'aurait rien affiché ici.
                Text(closedReason(outage))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            if canClose(outage) {
                closeButton(outage)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    /// Pastille de gravité, lieu, adresse, méta — et le chevron qui annonce la carte.
    private func placeHeader(_ outage: CommunityOutage) -> some View {
        HStack(alignment: .center, spacing: SQSpace.md) {
            Image(systemName: outage.state == .resolved ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ink(outage))
                .frame(width: 40, height: 40)
                .background(
                    accent(outage).opacity(0.13),
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(siteLabel(outage))
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                if let address = secondaryAddress(outage) {
                    Text(address)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                }
                Text(subtitle(outage))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    /// « La panne est terminée » — le composant partagé, pour que le geste soit rigoureusement le
    /// même ici, dans la feuille de panne et dans la fiche antenne.
    private func closeButton(_ outage: CommunityOutage) -> some View {
        OutageCloseButton(closing: model.closingId == outage.id) { pendingClose = outage }
    }

    // MARK: - Présentation

    /// Le bouton de fermeture n'apparaît que sous « Les miennes ».
    ///
    /// `canClose` suffirait techniquement — le serveur ne le met à vrai que pour l'auteur d'une
    /// panne ouverte. Mais « Toutes » est l'onglet de l'arbitrage : y glisser une action réservée
    /// à l'auteur brouillerait la seule chose que cet onglet demande, se prononcer.
    private func canClose(_ outage: CommunityOutage) -> Bool {
        model.scope == .mine && outage.canClose
    }

    /// Le nom du lieu, ou à défaut l'identifiant de cible — jamais une ligne vide.
    private func siteLabel(_ outage: CommunityOutage) -> String {
        if let name = outage.siteName, !name.isEmpty { return name }
        return outage.targetId.isEmpty ? String(localized: "Panne signalée") : outage.targetId
    }

    /// L'adresse, sauf quand elle RÉPÈTE mot pour mot le titre.
    ///
    /// Les deux champs viennent du même référentiel : sur les sites sans nom propre, `siteName`
    /// vaut déjà la voie — « route des Serrières », constaté sur l'API de production. La ligne
    /// afficherait alors deux fois le même texte, l'un sous l'autre. Une adresse seulement PLUS
    /// complète (numéro, code postal, commune) reste affichée : elle ajoute quelque chose.
    private func secondaryAddress(_ outage: CommunityOutage) -> String? {
        guard let address = outage.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty,
              address.localizedCaseInsensitiveCompare(siteLabel(outage)) != .orderedSame
        else { return nil }
        return address
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

    /// La même lecture, en version encre : le pictogramme est posé SUR le conteneur de sa propre
    /// teinte, où la teinte de base ne tient pas les 3:1 de WCAG 1.4.11 en apparence sombre.
    private func ink(_ outage: CommunityOutage) -> Color {
        switch outage.state {
        case .resolved: return OutageTint.resolvedInk
        case .rejected, .dormant: return SQColor.labelSecondary
        default: return OutageTint.inkOf(outage.severity)
        }
    }

    /// « Orange · Panne signalée · il y a 4 heures » — situer sans lire le bloc entier.
    ///
    /// PAS de « encore 2 » ici : la jauge juste en dessous écrit la phrase complète (« Encore 2
    /// personnes et la panne est confirmée »), et la répéter en abrégé au-dessus était l'autre
    /// moitié du grief « tout est dit deux fois ».
    ///
    /// Chaque morceau passe par `String(localized:)` : la ligne est assemblée en Swift puis rendue
    /// par `Text(String)`, qui ne traduit RIEN. Un littéral laissé nu ici resterait français dans
    /// une app anglaise, au milieu d'une phrase par ailleurs traduite.
    private func subtitle(_ outage: CommunityOutage) -> String {
        // Le libellé du registre, jamais la clé : la feuille de panne écrit « Orange » là où
        // cette liste écrivait « ORANGE » pour la même panne.
        var parts = [model.operatorLabel(outage), stateLabel(outage)]
        if let since = SignalFormatters.date(outage.startedAt, includingTime: true, relative: true) {
            parts.append(since)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Distinct du libellé de la fiche antenne : celui-ci ne voit que des pannes ouvertes et
    /// retombe sur « Panne signalée » pour tout le reste, ce qui ferait passer une panne rétablie
    /// pour une panne en cours.
    private func stateLabel(_ outage: CommunityOutage) -> String {
        switch outage.state {
        case .resolved: return String(localized: "Rétablie")
        case .rejected: return String(localized: "Écartée")
        case .dormant: return String(localized: "En veille")
        case .confirmed:
            return outage.operatorConfirmed
                ? String(localized: "Confirmée par l'opérateur")
                : String(localized: "Panne confirmée")
        case .reported: return String(localized: "Panne signalée")
        }
    }

    private func closedReason(_ outage: CommunityOutage) -> String {
        switch outage.state {
        case .rejected: return String(localized: "La communauté n'a pas retrouvé cette panne.")
        case .dormant: return String(localized: "Sans nouvelle depuis un moment. Elle se refermera seule.")
        default: return String(localized: "Le réseau est revenu. Merci de l'avoir signalée.")
        }
    }
}
