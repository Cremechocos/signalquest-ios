import SwiftUI

/// Textes communs aux corrections d'une identification (retrait, suppression, site, secteur).
enum IdentificationCorrectionText {
    /// Les routes de correction répondent 200 même quand aucune ligne ne correspond :
    /// on ne présente jamais comme faite une correction qui n'a rien changé (comme le web).
    static var nothingChanged: String {
        String(localized: "Rien n’a été modifié. Aucune de tes lignes ne correspond : elle a peut-être déjà été retirée ou déplacée.")
    }
    static var consensusChanged: String {
        String(localized: "Le support le plus validé a changé. Recharge la liste avant de déplacer.")
    }
    static var noConsensus: String {
        String(localized: "Aucun autre support n’est plus validé : rien à déplacer.")
    }

    /// Échec d'une correction, tel que le dit la maquette commune (planche 6) : jamais de
    /// code brut. Les corrections iOS partent sans file : hors ligne, rien n'est parti.
    static func failure(_ error: Error) -> String {
        guard let api = error as? APIError else { return error.userFacingMessage }
        switch api {
        case .http(401, _, _, _, _), .missingAuthToken:
            // Le refresh a déjà échoué : l'app repasse seule sur l'écran de connexion.
            return String(localized: "Ta session a expiré. Reconnecte-toi, puis refais la correction.")
        case .http(404, "IDENTIFICATION_NOT_FOUND"?, _, _, _):
            // edit-site après #954 : plus de 200 « moved: 0 », même échec qu'avant.
            return nothingChanged
        case .http(404, "TARGET_SITE_NOT_FOUND"?, _, _, _):
            return String(localized: "Ce support n’est plus sur la carte. Il a pu être retiré entre-temps : choisis-en un autre.")
        case .http(409, "CONSENSUS_TARGET_CHANGED"?, _, _, _):
            return consensusChanged
        case .http(409, "NO_CONSENSUS_CONFLICT"?, _, _, _):
            return noConsensus
        case let .http(status, code, message, _, _):
            // Le message du serveur s'il est lisible, sinon un texte propre à la correction.
            let readable = APIError.userFacingMessage(status: status, code: code, serverMessage: message)
            return readable == APIError.statusFallback(status)
                ? String(localized: "La correction n’a pas pu être enregistrée.") : readable
        case .transport where !api.isServerUnreachable:
            return String(localized: "Erreur réseau. Ta correction n’est pas partie. Elle reste ici : réessaie quand le réseau revient.")
        default:
            return api.userFacingMessage
        }
    }

    /// Échecs qui se règlent en relisant ses identifications, jamais en réessayant.
    static func needsReload(_ message: String?) -> Bool {
        guard let message else { return false }
        return [nothingChanged, consensusChanged, noConsensus].contains(message)
    }

    static var reload: String { String(localized: "Recharger mes identifications") }
}

@MainActor
final class MyIdentificationsViewModel: ObservableObject {
    @Published var items: [MyIdentification] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var withdrawingId: String?
    @Published var filter: Filter = .all { didSet { rebuild() } }
    @Published var toast: String?
    /// Filtre serveur `conflict=only` : seulement les nœuds en conflit.
    @Published private(set) var conflictOnly = false
    /// Page suivante (`nil` en fin de liste).
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadMoreError: String?
    /// Change à chaque page reçue : relance la demande de la suite même quand une
    /// première page rechargée a le même nombre de lignes.
    @Published private(set) var pagesReceived = 0
    /// La liste a changé pendant le parcours : on propose de recharger.
    @Published private(set) var restartAdvised = false
    /// Totaux de la première page : sur toute la liste, pas sur les pages chargées.
    @Published private(set) var totals: IdentificationTotals?
    @Published private(set) var checks = IdentificationChecks.unavailable

    enum Filter: String, CaseIterable, Identifiable {
        case all, lte, nr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return String(localized: "Toutes")
            case .lte: return "4G"
            case .nr: return "5G"
            }
        }
    }

    private let service: IdentifyServicing
    /// Une réponse d'un chargement remplacé (filtre changé, rechargement) est ignorée.
    private var generation = 0
    /// Une reprise automatique sur curseur périmé a eu lieu sans page réussie depuis.
    private var restartedForInvalidCursor = false
    init(service: IdentifyServicing) { self.service = service }

    var filtered: [MyIdentification] { items(for: filter) }
    var hasMore: Bool { nextCursor != nil }

    private func items(for filter: Filter) -> [MyIdentification] {
        switch filter {
        case .all: return items
        case .lte: return items.filter { $0.kind == .enb || $0.techLabel == "4G" }
        case .nr: return items.filter { $0.kind == .gnb || $0.techLabel == "5G" }
        }
    }

    /// Regroupement en nœuds, CALCULÉ UNE FOIS par changement d'entrée.
    ///
    /// En propriété calculée, `IdentifiedNodeGroup.group` — qui construit un
    /// dictionnaire, agrège les cellules et trie deux fois — repartait à chaque
    /// évaluation du `body`, donc à chaque frappe, chaque retrait, chaque
    /// bascule de filtre, et plusieurs fois par passe (la liste ET son état vide
    /// le lisent).
    @Published private(set) var filteredGroups: [IdentifiedNodeGroup] = []
    /// Nombre d'antennes par filtre, affiché dans le segment (« 4G · 9 »).
    @Published private(set) var counts: [Filter: Int] = [:]

    /// Conflits de toute la liste ; `nil` quand la vérification est indisponible.
    var conflictCount: Int? {
        guard checks.conflict == .ok else { return nil }
        if let totals { return totals.conflicts }
        // Sans totaux, seule la liste entièrement chargée permet de compter.
        return hasMore ? nil : items.filter { $0.conflict }.count
    }

    /// Le contrôle de conflit a échoué : on le dit, sans jamais conclure « aucun conflit ».
    var conflictCheckUnavailable: Bool {
        checks.conflict == .unavailable || (totals != nil && totals?.conflicts == nil)
    }

    private func rebuild() {
        filteredGroups = IdentifiedNodeGroup.group(filtered)
        if let totals, !conflictOnly {
            // Les totaux du serveur comptent toute la liste, même avant la dernière page.
            counts = [.all: totals.nodes, .lte: totals.enb, .nr: totals.gnb]
        } else if !hasMore {
            counts = Dictionary(uniqueKeysWithValues: Filter.allCases.map { filter in
                (filter, IdentifiedNodeGroup.group(items(for: filter)).filter { $0.kind != .unassigned }.count)
            })
        } else {
            counts = [:]
        }
    }

    func load() async {
        generation += 1
        let current = generation
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        defer { if current == generation { isLoading = false } }
        do {
            let page = try await service.minePage(cursor: nil, conflictOnly: conflictOnly, includeRelated: true, limit: nil)
            guard current == generation else { return }
            items = page.identifications
            nextCursor = page.nextCursor
            totals = page.totals
            checks = page.checks
            restartAdvised = page.restartAdvised
            pagesReceived += 1
            rebuild()
        } catch {
            guard current == generation else { return }
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    /// Page suivante, demandée quand la fin de la liste apparaît.
    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        let current = generation
        isLoadingMore = true
        loadMoreError = nil
        defer { if current == generation { isLoadingMore = false } }
        do {
            let page = try await service.minePage(cursor: cursor, conflictOnly: conflictOnly, includeRelated: true, limit: nil)
            guard current == generation else { return }
            let known = Set(items.map(\.id))
            items += page.identifications.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
            checks = checks.merged(with: page.checks)
            restartAdvised = restartAdvised || page.restartAdvised
            restartedForInvalidCursor = false
            pagesReceived += 1
            rebuild()
        } catch APIError.http(400, "INVALID_CURSOR"?, _, _, _) {
            guard current == generation else { return }
            // Curseur périmé : on repart une fois de la première page, sans message. Un
            // second refus juste après la reprise s'affiche, pour ne pas boucler.
            guard !restartedForInvalidCursor else {
                loadMoreError = String(localized: "Impossible de charger la suite")
                return
            }
            restartedForInvalidCursor = true
            isLoadingMore = false
            await load()
        } catch {
            guard current == generation, !error.isCancellation else { return }
            loadMoreError = error.userFacingMessage
        }
    }

    /// Bascule le filtre serveur des conflits et recharge depuis la première page.
    func setConflictOnly(_ value: Bool) async {
        guard value != conflictOnly else { return }
        conflictOnly = value
        items = []
        nextCursor = nil
        rebuild()
        await load()
    }

    func withdraw(_ item: MyIdentification) async {
        withdrawingId = item.id
        defer { withdrawingId = nil }
        do {
            let result = try await service.withdraw(
                siteId: item.siteId,
                enb: item.enb, gnb: item.gnb,
                pci: item.pciValue,
                cellId: item.cellId, ci: item.ci,
                tech: item.tech, reason: nil
            )
            if result.changed {
                await load()
                toast = String(localized: "Identification retirée")
                Haptics.success()
            } else {
                toast = result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Retrait impossible")
                Haptics.error()
            }
        } catch {
            // En toast, visible à la fermeture de la fiche : la ligne d'erreur en
            // bas de liste passait inaperçue et laissait croire au retrait.
            toast = IdentificationCorrectionText.failure(error)
            Haptics.error()
        }
    }

    /// Suppression DÉFINITIVE (hard delete) des contributions solo de l'utilisateur.
    /// Les lignes confirmées par autrui sont seulement retirées (soft) côté serveur —
    /// on l'indique alors dans le toast pour ne pas laisser croire à un effacement total.
    func delete(_ item: MyIdentification) async {
        withdrawingId = item.id
        defer { withdrawingId = nil }
        do {
            let result = try await service.delete(
                siteId: item.siteId,
                enb: item.enb, gnb: item.gnb,
                pci: item.pciValue,
                cellId: item.cellId, ci: item.ci,
                tech: item.tech, reason: nil
            )
            if result.changed {
                await load()
                toast = (result.deleted == 0 && result.softWithdrawn > 0)
                    ? String(localized: "Retirée : des cellules sont confirmées par d’autres")
                    : String(localized: "Identification supprimée")
                Haptics.success()
            } else {
                toast = result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Suppression impossible")
                Haptics.error()
            }
        } catch {
            // En toast, visible à la fermeture de la fiche : la ligne d'erreur en
            // bas de liste passait inaperçue et laissait croire au retrait.
            toast = IdentificationCorrectionText.failure(error)
            Haptics.error()
        }
    }
}

/// « Mes identifications » — les cellules→sites que l'utilisateur a identifiées
/// (compte partagé : inclut celles faites sur Android). Consultation + retrait.
struct MyIdentificationsView: View {
    @StateObject private var model: MyIdentificationsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingWithdraw: MyIdentification?
    @State private var selected: MyIdentification?

    init(service: IdentifyServicing) {
        _model = StateObject(wrappedValue: MyIdentificationsViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.xs, trailing: 0))
                    .listRowBackground(Color.clear)
                SQSegmentedFilter(
                    selection: $model.filter,
                    options: MyIdentificationsViewModel.Filter.allCases.map { filter in
                        (value: filter, label: segmentLabel(filter), icon: String?.none)
                    }
                )
                .accessibilityIdentifier("identifications.filter")
                // Le segment ajoute sa propre marge latérale de 16 pt : on la compense.
                .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: -SQSpace.lg, bottom: SQSpace.xs, trailing: -SQSpace.lg))
                .listRowBackground(Color.clear)

                Group {
                    if model.conflictOnly {
                        conflictFilterNote
                    } else if let count = model.conflictCount, count > 0 {
                        conflictNote(count)
                    } else if model.conflictCheckUnavailable && !model.items.isEmpty {
                        notice(String(localized: "Vérification des conflits indisponible pour le moment."),
                               systemImage: "questionmark.circle", identifier: "identifications.conflictsUnavailable")
                    }
                    if model.restartAdvised {
                        restartNote
                    }
                }
                .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)

            if model.filteredGroups.isEmpty && !model.isLoading, let errorMessage = model.errorMessage {
                // Un échec n'est pas une liste vide : « Aucune identification »
                // au-dessus de l'erreur se contredisait (AF-RAD-16).
                ErrorStateView(title: "Identifications indisponibles", message: errorMessage) {
                    Task { await model.load() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else if model.filteredGroups.isEmpty && !model.isLoading {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } else {
                ForEach(model.filteredGroups) { group in
                    Section {
                        // Sans nœud, aucune ligne ne représente le groupe : seules ses
                        // cellules s'ouvrent et se retirent.
                        if group.kind != .unassigned {
                            Button {
                                selected = group.representative
                            } label: {
                                IdentificationNodeRow(group: group, isWithdrawing: model.withdrawingId == group.representative.id)
                            }
                                .buttonStyle(.plain)
                                .listRowBackground(SQColor.surface)
                                .listRowSeparatorTint(SQColor.separator)
                                .contentShape(Rectangle())
                                .accessibilityHint("Ouvre le détail de cette identification")
                                .accessibilityIdentifier("identifications.node.\(group.id)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingWithdraw = group.representative
                                    } label: {
                                        Label("Retirer", systemImage: "trash")
                                    }
                                }
                        }

                        ForEach(group.cells) { cell in
                            Button {
                                selected = cell.source
                            } label: {
                                IdentificationCellRow(
                                    cell: cell,
                                    isWithdrawing: model.withdrawingId == cell.source.id,
                                    indented: group.kind != .unassigned
                                )
                            }
                                .buttonStyle(.plain)
                                .listRowBackground(SQColor.surface)
                                .listRowSeparatorTint(SQColor.separator)
                                .contentShape(Rectangle())
                                .accessibilityHint("Ouvre le détail de cette cellule")
                                .accessibilityIdentifier("identifications.cell.\(cell.id)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingWithdraw = cell.source
                                    } label: {
                                        Label("Retirer", systemImage: "trash")
                                    }
                                }
                        }

                        if group.cellsTruncated {
                            Text("Seules les 4 000 cellules les plus récentes de ce nœud sont affichées.")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .padding(.leading, IdentificationNodeRow.textInset)
                                .listRowBackground(SQColor.surface)
                        }

                        if group.cells.isEmpty {
                            Text("Aucun identifiant de cellule (PCI/CI) associé à cette antenne.")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .padding(.leading, IdentificationNodeRow.textInset)
                                .listRowBackground(SQColor.surface)
                        }
                    } header: {
                        if group.kind == .unassigned {
                            Text(group.title).sqKicker()
                        }
                    }
                }
            }

            if model.hasMore || model.loadMoreError != nil {
                loadMoreRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let errorMessage = model.errorMessage, !model.filteredGroups.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Mes identifications")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .refreshable { await model.load() }
        .overlay {
            if model.isLoading && model.items.isEmpty { SQSpinner().tint(SQColor.brandRed) }
        }
        .task { if model.items.isEmpty { await model.load() } }
        .confirmationDialog(
            "Retirer cette identification ?",
            isPresented: Binding(get: { pendingWithdraw != nil }, set: { if !$0 { pendingWithdraw = nil } }),
            presenting: pendingWithdraw
        ) { item in
            Button("Retirer", role: .destructive) {
                Task { await model.withdraw(item); pendingWithdraw = nil }
            }
            Button("Annuler", role: .cancel) { pendingWithdraw = nil }
        } message: { item in
            Text("« \(item.nodeLabel) » ne te sera plus attribuée. Tu pourras la ré-identifier.")
        }
        .sheet(item: $selected) { item in
            IdentificationDetailSheet(
                item: item,
                checks: model.checks,
                isWithdrawing: model.withdrawingId == item.id,
                onWithdraw: {
                    Task {
                        await model.withdraw(item)
                        selected = nil
                    }
                },
                onDelete: {
                    Task {
                        await model.delete(item)
                        selected = nil
                    }
                },
                onChanged: {
                    selected = nil
                    Task { await model.load() }
                },
                onStale: { Task { await model.load() } }
            )
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.onInk)
                    .padding(.horizontal, SQSpace.md).padding(.vertical, SQSpace.sm)
                    .background(SQColor.label, in: Capsule(style: .continuous))
                    .sqShadowCard()
                    .padding(.bottom, SQSpace.lg)
                    .accessibilityIdentifier("identifications.toast")
                    // Un message qui en remplace un autre relance la minuterie.
                    .task(id: toast) {
                        guard (try? await Task.sleep(nanoseconds: 2_200_000_000)) != nil else { return }
                        model.toast = nil
                    }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "identifications.back") { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Mes identifications")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("identifications.title")
                Text("Les antennes que tu as reliées à un site, ici et sur Android.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « Toutes · 14 » : le nombre n'apparaît qu'une fois la liste chargée.
    private func segmentLabel(_ filter: MyIdentificationsViewModel.Filter) -> String {
        guard let count = model.counts[filter] else { return filter.label }
        return "\(filter.label) · \(count.formatted())"
    }

    /// Compte tous les conflits (totaux du serveur) ; le toucher n'affiche qu'eux.
    private func conflictNote(_ count: Int) -> some View {
        Button {
            Haptics.selection()
            Task { await model.setConflictOnly(true) }
        } label: {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(OutageTint.degradedInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    // AttributedString : le gras d'une variante plurielle n'est pas interprété par Text.
                    Text(AttributedString(localized: "**\(count) identification en conflit** : un autre site a plus de validations sur cette antenne. Vérifie-la ou retire-la."))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Afficher seulement les conflits")
                        .font(SQFont.body(13, .semibold, relativeTo: .caption))
                        .foregroundStyle(SQColor.accentInk)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("identifications.conflicts")
    }

    /// Filtre des conflits actif : on le dit, et on permet d'en sortir.
    private var conflictFilterNote: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(OutageTint.degradedInk)
                .accessibilityHidden(true)
            Text("Seulement les antennes en conflit")
                .font(SQType.caption)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Tout afficher") {
                Haptics.selection()
                Task { await model.setConflictOnly(false) }
            }
            .font(SQFont.body(13, .semibold, relativeTo: .caption))
            .foregroundStyle(SQColor.accentInk)
            .frame(minHeight: 44)
            .accessibilityIdentifier("identifications.showAll")
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityIdentifier("identifications.conflictFilter")
    }

    /// La liste a bougé pendant le chargement : rien n'est perdu, mais il faut recharger.
    private var restartNote: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(SQColor.accentInk)
                .accessibilityHidden(true)
            Text("Ta liste a changé pendant le chargement. Recharge-la pour tout voir.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Recharger") {
                Task { await model.load() }
            }
            .font(SQFont.body(13, .semibold, relativeTo: .caption))
            .foregroundStyle(SQColor.accentInk)
            .frame(minHeight: 44)
            .accessibilityIdentifier("identifications.restart")
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.md, elevation: .rest)
    }

    private func notice(_ text: String, systemImage: String, identifier: String) -> some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .font(SQType.caption)
        .foregroundStyle(SQColor.labelSecondary)
        .padding(.horizontal, SQSpace.xs)
        .accessibilityIdentifier(identifier)
    }

    /// Fin de liste : la page suivante se charge dès que cette ligne apparaît.
    @ViewBuilder
    private var loadMoreRow: some View {
        if let error = model.loadMoreError {
            VStack(spacing: SQSpace.xs) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                Button("Réessayer") { Task { await model.loadMore() } }
                    .font(SQFont.body(13, .semibold, relativeTo: .caption))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("identifications.loadMoreRetry")
            }
            .frame(maxWidth: .infinity)
        } else {
            SQSpinner()
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel(Text("Chargement de la suite"))
                .accessibilityIdentifier("identifications.loadMore")
                .task(id: model.pagesReceived) { await model.loadMore() }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            title: "Aucune identification",
            message: "Identifie une antenne depuis une session ou la carte. Tes identifications, y compris depuis Android, apparaîtront ici.",
            systemImage: "checkmark.seal"
        )
    }
}

/// Pastille de génération (« 4G », « 5G ») aux couleurs de la carte et des fiches.
private struct GenerationTile: View {
    let label: String
    var size: CGFloat = 44

    @Environment(\.colorScheme) private var colorScheme

    private var color: Color { SQBrand.techColor(label == "5G" ? "5G" : "4G") }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                .fill(color)
            Text(label)
                .font(SQFont.display(size > 48 ? 14 : 12, .bold))
                .foregroundStyle(SQBrand.operatorBadgeForeground(for: color, colorScheme: colorScheme))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Pastille de signal (« Conflit », « Contesté »…) : point de couleur et mot,
/// comme les statuts du lot.
struct SignalPill: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(SQColor.warning).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(text)
        }
        .font(SQFont.body(12, .bold, relativeTo: .caption))
        .foregroundStyle(OutageTint.degradedInk)
        .padding(.horizontal, SQSpace.sm)
        .padding(.vertical, 3)
        .background(SQColor.warning.opacity(0.14), in: Capsule(style: .continuous))
        .fixedSize()
    }
}

private struct IdentificationNodeRow: View {
    let group: IdentifiedNodeGroup
    let isWithdrawing: Bool

    /// Retrait des cellules : leur pastille s'aligne sur le texte du nœud.
    static let textInset: CGFloat = 44 + SQSpace.md

    var body: some View {
        HStack(spacing: SQSpace.md) {
            GenerationTile(label: group.kind == .gnb ? "5G" : "4G")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SQSpace.sm) {
                    Text(group.title)
                        .font(SQFont.body(15, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                        .sqSingleLine()
                    if group.conflict {
                        SignalPill(text: "Conflit")
                    } else if group.contested {
                        SignalPill(text: "Contesté")
                    }
                }
                Text(group.subtitle)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                HStack(spacing: SQSpace.md) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill").accessibilityHidden(true)
                        Text("Validée \(group.validations) fois")
                    }
                    .foregroundStyle(OutageTint.resolvedInk)
                    if !group.sectorsUnion.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.right").accessibilityHidden(true)
                            Text("\(group.sectorsUnion.count) secteurs")
                        }
                    }
                }
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if isWithdrawing { SQSpinner() }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SQSpace.xs)
        .accessibilityElement(children: .combine)
    }
}

private struct IdentificationCellRow: View {
    let cell: IdentifiedCell
    let isWithdrawing: Bool
    var indented = true

    /// « Secteur 2 · CI 160466202 » ; plusieurs secteurs restent listés.
    private var detail: Text? {
        var parts: [Text] = []
        if cell.sectors.count == 1, let sector = cell.sectors.first {
            parts.append(Text("Secteur \(sector)"))
        } else if !cell.sectors.isEmpty {
            parts.append(Text("Secteurs \(cell.sectors.map(String.init).joined(separator: ", "))"))
        }
        if let ci = cell.ci { parts.append(Text(verbatim: "CI \(ci)").monospacedDigit()) }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() { line = line + Text(verbatim: " · ") + part }
        return line
    }

    var body: some View {
        HStack(spacing: SQSpace.sm2) {
            Image(systemName: "dot.radiowaves.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(width: 30, height: 30)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SQSpace.sm) {
                    Text(cell.label)
                        .font(SQFont.body(14, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    if cell.source.sectorCheck?.status == .mismatch {
                        SignalPill(text: "Secteur à vérifier")
                    } else if let conflict = cell.source.cellConflict {
                        switch conflict.reason {
                        case .otherSite: SignalPill(text: "Autre support")
                        case .pciMismatch: SignalPill(text: "Autre PCI")
                        }
                    }
                }
                if let detail {
                    detail
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isWithdrawing { SQSpinner() }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.leading, indented ? IdentificationNodeRow.textInset : 0)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Fiche détaillée d'une identification : tous les identifiants radio + retrait.
private struct IdentificationDetailSheet: View {
    let item: MyIdentification
    /// Contrôles de la liste : un contrôle indisponible ne vaut jamais « rien à signaler ».
    let checks: IdentificationChecks
    let isWithdrawing: Bool
    let onWithdraw: () -> Void
    var onDelete: () -> Void = {}
    var onChanged: () -> Void = {}
    /// Le consensus a bougé : la liste se recharge, la fiche reste ouverte avec le message.
    var onStale: () -> Void = {}
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingWithdraw = false
    @State private var confirmingDelete = false
    @State private var showRemap = false
    @State private var showSector = false
    /// Secteur proposé à l'ouverture de « Corriger le secteur » (écart de règle).
    @State private var sectorPrefill: Int?
    @State private var adoptBusy = false
    @State private var adoptError: String?

    private var is5G: Bool { item.kind == .gnb || item.techLabel == "5G" }
    /// Ré-attribution de site : seulement pour les nœuds eNB/gNB.
    private var canRemapSite: Bool { (item.kind == .enb || item.kind == .gnb) && (item.enb != nil || item.gnb != nil) }
    /// Correction de secteur : pour les cellules (PCI/CellID).
    private var canEditSector: Bool { item.kind == .pci || item.kind == .cellid }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapSheetHeader(title: "Identification", closeIdentifier: "identification.close") { dismiss() }
                header
                if item.conflict {
                    conflictSection
                }
                signalsSection
                detailsCard
                editSection
                withdrawBlock
                dangerZone
            }
            .padding(SQSpace.lg)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .sheet(isPresented: $showRemap) {
            SiteRemapSheet(
                item: item,
                antennas: services.antennas,
                identify: services.identify,
                location: services.location,
                markets: services.markets,
                onReload: { onChanged(); dismiss() },
                onDone: { _ in onChanged(); dismiss() }
            )
        }
        .sheet(isPresented: $showSector) {
            SectorEditSheet(
                item: item,
                antennas: services.antennas,
                identify: services.identify,
                prefilledSector: sectorPrefill,
                onReload: { onChanged(); dismiss() },
                onDone: { onChanged(); dismiss() }
            )
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Conflit de consensus (MYID-TELECOM-02) : avertissement + bloc « Site communautaire »
    /// avec bouton « Adopter ce site » (parité Android).
    @ViewBuilder
    private var conflictSection: some View {
        // L'icône a sa colonne : le site communautaire et le bouton s'alignent sur le texte.
        HStack(alignment: .top, spacing: SQSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OutageTint.degradedInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text(AttributedString(localized: "**Conflit** : un autre site a plus de validations sur cette antenne."))
                    .font(SQType.subhead(.regular))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let consensusId = item.conflictSiteId {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Site communautaire · \(consensusId)")
                            .font(SQFont.body(14, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                        if let line = consensusLine {
                            Text(line)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    // Halo ne remplit jamais un bouton de carmin : pilule carte et filet.
                    GradientButton("Adopter ce site", systemImage: "checkmark.seal", isBusy: adoptBusy, style: .secondary) {
                        Task { await adoptConsensus(toSiteId: consensusId) }
                    }
                    .accessibilityIdentifier("identification.adopt")
                    if let adoptError {
                        Text(adoptError).font(SQType.micro).foregroundStyle(SQColor.dangerInk)
                    }
                } else {
                    Text("Retire cette identification si elle est erronée.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqNoticeBackground(SQColor.warningSoft)
        .accessibilityIdentifier("identification.conflict")
    }

    /// « Quai Claude-Bernard · 6 validations ».
    private var consensusLine: String? {
        let parts = [
            item.conflictSiteAddress,
            item.conflictSiteValidations.map { String(localized: "\($0) validations") }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func adoptConsensus(toSiteId: String) async {
        adoptBusy = true
        adoptError = nil
        defer { adoptBusy = false }
        do {
            // Le serveur recalcule le consensus ; `toSiteId` est celui affiché ici.
            let result = try await services.identify.adoptConsensus(
                fromSiteId: item.siteId, toSiteId: toSiteId,
                enb: item.enb, gnb: item.gnb
            )
            if result.changed {
                Haptics.success()
                onChanged()
                dismiss()
            } else {
                adoptError = result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Adoption non appliquée.")
                Haptics.error()
            }
        } catch APIError.http(409, "CONSENSUS_TARGET_CHANGED"?, _, _, _) {
            adoptError = IdentificationCorrectionText.consensusChanged
            Haptics.error()
            onStale()
        } catch APIError.http(409, "NO_CONSENSUS_CONFLICT"?, _, _, _) {
            adoptError = IdentificationCorrectionText.noConsensus
            Haptics.error()
            onStale()
        } catch {
            adoptError = IdentificationCorrectionText.failure(error)
            Haptics.error()
        }
    }

    private var isNode: Bool { item.kind == .enb || item.kind == .gnb }

    /// Signaux v2 : contrôle indisponible, support contesté, cellule déclarée
    /// ailleurs, secteur à vérifier, nœud tronqué. Chacun en une phrase.
    @ViewBuilder
    private var signalsSection: some View {
        let notes = signalNotes
        if !notes.isEmpty || sectorMismatch != nil {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                ForEach(notes, id: \.self) { text in
                    HStack(alignment: .top, spacing: SQSpace.sm) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(SQColor.accentInk)
                            .accessibilityHidden(true)
                        Text(verbatim: text)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let expected = sectorMismatch {
                    HStack(alignment: .top, spacing: SQSpace.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(OutageTint.degradedInk)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            Text("D’après la règle de l’opérateur, cette cellule serait le secteur \(expected).")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.label)
                                .fixedSize(horizontal: false, vertical: true)
                            GradientButton("Corriger le secteur", style: .secondary) {
                                // Prérempli avec la règle ; le membre reste libre de choisir autre chose.
                                sectorPrefill = expected
                                showSector = true
                            }
                            .accessibilityIdentifier("identification.sectorMismatch")
                        }
                    }
                }
            }
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqNoticeBackground(SQColor.warningSoft)
            .accessibilityIdentifier("identification.signals")
        }
    }

    /// Secteur attendu par la règle, seulement sur un écart.
    private var sectorMismatch: Int? {
        guard canEditSector, checks.sectorCheck == .ok, item.sectorCheck?.status == .mismatch else { return nil }
        return item.sectorCheck?.expected
    }

    private var signalNotes: [String] {
        var notes: [String] = []
        if isNode, !item.conflict, checks.conflict == .unavailable || item.conflictCheckUnavailable {
            notes.append(String(localized: "Vérification des conflits indisponible pour le moment."))
        }
        if isNode, let contested = item.contested {
            switch contested.reason {
            case .tie:
                notes.append(String(localized: "Ce nœud est aussi déclaré sur un autre support, à égalité de validations."))
            case .minorityElsewhere:
                notes.append(String(localized: "Ce nœud est aussi déclaré ailleurs, mais ton support reste le plus validé."))
            case nil:
                notes.append(String(localized: "Ce nœud est aussi déclaré sur un autre support."))
            }
            for site in contested.otherSites {
                notes.append("\(String(localized: "Support \(site.siteId)")) · \(String(localized: "\(site.validations) validations"))")
            }
        }
        if isNode, item.cellsTruncated {
            notes.append(String(localized: "Seules les 4 000 cellules les plus récentes de ce nœud sont affichées."))
        }
        if canEditSector {
            // Le contrôle des doublons ne porte que sur les cellules avec ECI/NCI.
            if checks.cellConflict == .unavailable, item.ci != nil {
                notes.append(String(localized: "Vérification des doublons indisponible pour le moment."))
            } else if let conflict = item.cellConflict {
                switch conflict.reason {
                case .otherSite:
                    notes.append(String(localized: "Cette cellule est déclarée sur un autre support."))
                    if let siteId = conflict.siteId {
                        notes.append(String(localized: "Support \(siteId)"))
                    }
                case .pciMismatch:
                    if let pci = conflict.pci {
                        notes.append(String(localized: "Sur ce support, cette cellule est aussi déclarée avec un autre PCI (\(pci))."))
                    } else {
                        notes.append(String(localized: "Sur ce support, cette cellule est aussi déclarée avec un autre PCI."))
                    }
                }
            }
            if checks.sectorCheck == .unavailable {
                notes.append(String(localized: "Vérification du secteur indisponible pour le moment."))
            } else if item.sectorCheck?.status == .unknown {
                notes.append(String(localized: "Le secteur ne peut pas encore être vérifié pour ce support."))
            }
        }
        if item.orphan {
            notes.append(String(localized: "Aucune de tes identifications de nœud actives ne porte cette cellule."))
        }
        return notes
    }

    @ViewBuilder
    private var editSection: some View {
        if canRemapSite || canEditSector {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Corriger").sqKicker().accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    if canRemapSite {
                        editRow(
                            title: "Corriger le site",
                            subtitle: "Choisir le bon site sur la carte",
                            icon: "mappin.and.ellipse",
                            identifier: "identification.remap"
                        ) { showRemap = true }
                    }
                    if canRemapSite && canEditSector {
                        Divider().overlay(SQColor.separator).padding(.leading, 64)
                    }
                    if canEditSector {
                        editRow(
                            title: "Corriger le secteur",
                            subtitle: "Toucher le bon secteur sur le radar",
                            icon: "dot.radiowaves.right",
                            identifier: "identification.sector"
                        ) { sectorPrefill = nil; showSector = true }
                    }
                }
                .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
            }
        }
    }

    private func editRow(title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String,
                         identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SQSpace.md) {
                IdentificationIconTile(systemImage: icon)
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text(title).font(SQType.subhead(.semibold)).foregroundStyle(SQColor.label)
                    Text(subtitle).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    private var header: some View {
        HStack(spacing: SQSpace.md) {
            GenerationTile(label: is5G ? "5G" : "4G", size: 52)
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(item.operatorDisplayName ?? String(localized: "Opérateur inconnu"))
                    .font(SQFont.display(20, .bold))
                    .foregroundStyle(SQColor.label)
                Text(item.nodeLabel)
                    .font(SQType.subhead)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var detailsCard: some View {
        VStack(spacing: SQSpace.sm) {
            SQFactRow(label: "Validations", value: item.validations.formatted())
            if !item.sectors.isEmpty {
                SQFactRow(label: "Secteurs", value: item.sectors.map(String.init).joined(separator: ", "))
            }
            if let band = item.band { SQFactRow(label: "Bande", value: SQUnits.band(band, technology: item.tech ?? (item.type == "gnb" ? "NR" : nil))) }
            if let ci = item.ci { SQFactRow(label: "CI / ECI", value: ci) }
            if let mcc = mccMnc { SQFactRow(label: "MCC / MNC", value: mcc) }
            if let market = item.marketCode { SQFactRow(label: "Marché", value: market) }
            if let source = sourceLabel { SQFactRow(label: "Source", value: source) }
            SQFactRow(label: "Identifiant site", value: item.siteId)
            if let created = item.createdAt { SQFactRow(label: "Créée le", value: created.sqFormatted(date: .medium)) }
            if let validated = item.lastValidated { SQFactRow(label: "Dernière validation", value: validated.sqFormatted(date: .medium)) }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.md)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityIdentifier("identification.details")
    }

    private var mccMnc: String? {
        guard item.operatorMcc != nil || item.operatorMnc != nil else { return nil }
        let mcc = item.operatorMcc.map(String.init) ?? "—"
        let mnc = item.operatorMnc.map(String.init) ?? "—"
        return "\(mcc) / \(mnc)"
    }

    /// « iPhone », « Manuelle »… plutôt que la valeur brute du serveur. La source se
    /// lit sur chaque ligne : un nœud peut porter des cellules de sources différentes.
    private var sourceLabel: String? {
        guard let source = item.source, !source.isEmpty else { return nil }
        switch source.lowercased() {
        case "ios", "iphone": return "iPhone"
        case "android": return "Android"
        case "manual", "manuel": return String(localized: "Manuelle")
        case "auto": return String(localized: "Automatique")
        case "auto_capture": return String(localized: "Capture automatique")
        // Imports de logs externes (NetMonster, eNB Analytics…) : provenance honnête.
        case let value where value.contains("sync") || value.contains("import"): return "Import"
        default: return source
        }
    }

    private var withdrawBlock: some View {
        VStack(spacing: SQSpace.xs) {
            GradientButton(
                "Retirer cette identification",
                systemImage: "trash",
                isBusy: isWithdrawing,
                style: .destructive
            ) {
                confirmingWithdraw = true
            }
            .accessibilityIdentifier("identification.withdraw")
            .confirmationDialog("Retirer cette identification ?", isPresented: $confirmingWithdraw) {
                Button("Retirer", role: .destructive, action: onWithdraw)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("« \(item.nodeLabel) » ne te sera plus attribuée. Tu pourras la ré-identifier.")
            }
            Text("Réversible : tu peux ré-identifier ce site.")
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    /// Geste irréversible (hard delete owner-scoped), à part du retrait : le serveur
    /// n'efface que les lignes solo et retire en soft celles confirmées par d'autres.
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Zone sensible").sqKicker().accessibilityAddTraits(.isHeader)
            Button {
                confirmingDelete = true
            } label: {
                HStack(spacing: SQSpace.md) {
                    IdentificationIconTile(systemImage: "trash.slash", tint: SQColor.dangerInk, fill: SQColor.dangerSoft)
                    VStack(alignment: .leading, spacing: SQSpace.xxs) {
                        Text("Supprimer définitivement")
                            .font(SQType.subhead(.semibold))
                            .foregroundStyle(SQColor.dangerInk)
                        Text("Irréversible. Les cellules confirmées par d’autres sont seulement retirées.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if isWithdrawing { SQSpinner().tint(SQColor.danger) }
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
                .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
            }
            .buttonStyle(SQPressButtonStyle())
            .disabled(isWithdrawing)
            .accessibilityIdentifier("identification.delete")
            .confirmationDialog("Supprimer définitivement ?", isPresented: $confirmingDelete) {
                Button("Supprimer définitivement", role: .destructive, action: onDelete)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("« \(item.nodeLabel) » sera effacée définitivement. Les cellules confirmées par d’autres seront seulement retirées.")
            }
        }
        .padding(.top, SQSpace.md)
    }
}

/// Tuile d'icône d'une rangée Halo (`ListRow`) : 38 pt, coins de tuile, icône à l'encre
/// secondaire sur la puce ; le carmin reste à l'identité et à la sélection.
private struct IdentificationIconTile: View {
    let systemImage: String
    var tint: Color = SQColor.ink2
    var fill: Color = SQColor.chip

    var body: some View {
        Image(systemName: systemImage)
            .font(SQFont.body(16, .semibold, relativeTo: .body))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(fill, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
            .accessibilityHidden(true)
    }
}

private extension View {
    /// Fond d'un encadré Halo (`Notice`) : 14 pt de coins, ton doux, filet en « Noir intense ».
    func sqNoticeBackground(_ fill: Color) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .strokeBorder(SQOledPalette.cardStroke, lineWidth: 1)
            }
    }
}
