import SwiftUI

/// L'identification qu'on vient de faire, telle que l'écran d'identification la connaît :
/// le support retenu, le nœud (eNB/gNB) et les PCI vus dans le log.
struct IdentificationCorrectionTarget: Identifiable, Equatable, Sendable {
    let siteId: String
    let kind: IdentifiedNodeKind
    let node: String
    /// PCI observés, du plus vu au moins vu : « Corriger » s'ouvre sur la première cellule qui en porte un.
    var observedPcis: [Int] = []

    var id: String { "\(siteId)|\(kind.rawValue)|\(node)" }
}

/// Ce qu'une correction a changé, pour que l'écran d'identification se remette à jour.
enum IdentificationCorrectionOutcome: Equatable, Sendable {
    /// Retirée ou supprimée : le nœud est de nouveau à identifier. `note` dit lequel des deux.
    case withdrawn(note: String)
    /// Déplacée : le support où se trouve désormais le nœud.
    case moved(siteId: String)
    /// Secteur corrigé : le nœud reste sur le même support.
    case edited
}

/// Liste plus longue que le garde-fou : on ne conclut ni présente ni absente.
private struct IncompleteRead: LocalizedError {
    var errorDescription: String? {
        String(localized: "Tes identifications n’ont pas pu être lues en entier. Réessaie.")
    }
}

/// Retrouve l'identification qu'on vient de faire dans « Mes identifications », puis la
/// retire ou la supprime. Les déplacements et les secteurs passent par leurs feuilles.
@MainActor
final class IdentificationCorrectionModel: ObservableObject {
    enum State: Equatable {
        case loading
        case found(node: MyIdentification, cells: [MyIdentification])
        case notFound
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var checks: IdentificationChecks = .unavailable
    @Published private(set) var isBusy = false
    /// Retrait ou suppression refusés : affiché dans le bloc, au-dessus des boutons.
    @Published private(set) var actionError: String?

    let target: IdentificationCorrectionTarget
    private let service: IdentifyServicing

    /// Garde-fou contre un curseur qui ne finirait pas. Atteint, on ne conclut rien.
    static let maxPages = 50

    init(target: IdentificationCorrectionTarget, service: IdentifyServicing) {
        self.target = target
        self.service = service
    }

    /// Lit les lignes du nœud filtrées par le serveur, puis conclut seulement une fois le
    /// curseur épuisé : une ligne absente d'une page n'est pas une ligne inexistante.
    /// Filtre refusé (`INVALID_FILTER`) : relecture complète, avec la même règle.
    /// `quietly` : après une correction, le bloc reste affiché le temps de relire.
    func load(quietly: Bool = false) async {
        if !quietly {
            state = .loading
            actionError = nil
        }
        do {
            let read: (items: [MyIdentification], checks: IdentificationChecks?)
            do {
                read = try await readToTheEnd { cursor in
                    try await self.service.minePage(cursor: cursor, siteId: self.target.siteId,
                                                    enb: self.target.kind == .enb ? self.target.node : nil,
                                                    gnb: self.target.kind == .gnb ? self.target.node : nil)
                }
            } catch APIError.http(400, "INVALID_FILTER"?, _, _, _) {
                read = try await readToTheEnd { cursor in
                    try await self.service.minePage(cursor: cursor, conflictOnly: false, includeRelated: true, limit: nil)
                }
            }
            checks = read.checks ?? .unavailable
            if let match = Self.match(target, in: read.items) {
                state = .found(node: match.node, cells: match.cells)
            } else {
                state = .notFound
            }
        } catch {
            // Relecture discrète ratée : le bloc affiché reste.
            guard !error.isCancellation, !quietly else { return }
            state = .failed(error.userFacingMessage)
        }
    }

    /// Toutes les pages, du début à `nextCursor == nil`. Curseur refusé : une reprise du début.
    private func readToTheEnd(
        _ page: (String?) async throws -> MyIdentificationsPage
    ) async throws -> (items: [MyIdentification], checks: IdentificationChecks?) {
        var restarted = false
        while true {
            var items: [MyIdentification] = []
            var checks: IdentificationChecks?
            var cursor: String?
            do {
                for _ in 0..<Self.maxPages {
                    let next = try await page(cursor)
                    items += next.identifications
                    checks = checks.map { $0.merged(with: next.checks) } ?? next.checks
                    guard let following = next.nextCursor else { return (items, checks) }
                    cursor = following
                }
                throw IncompleteRead()
            } catch APIError.http(400, "INVALID_CURSOR"?, _, _, _) where !restarted {
                restarted = true
            }
        }
    }

    /// La ligne du nœud sur ce support, avec ses cellules.
    nonisolated static func match(
        _ target: IdentificationCorrectionTarget,
        in items: [MyIdentification]
    ) -> (node: MyIdentification, cells: [MyIdentification])? {
        let group = IdentifiedNodeGroup.group(items).first { group in
            group.kind == target.kind && group.nodeValue == target.node
                && group.representative.siteId == target.siteId
                && (group.representative.kind == .enb || group.representative.kind == .gnb)
        }
        guard let group else { return nil }
        return (group.representative, group.cells.map(\.source))
    }

    /// La cellule que le membre a sous les yeux : la première dont le PCI a été vu ;
    /// sinon la cellule validée le plus récemment (règle commune avec le Web,
    /// maquette « Corriger une identification », planche 2), sinon la première.
    nonisolated static func observedCell(
        in cells: [MyIdentification],
        observedPcis: [Int]
    ) -> MyIdentification? {
        for pci in observedPcis {
            if let cell = cells.first(where: { $0.pci == pci || $0.pciValue == String(pci) }) { return cell }
        }
        let dated = cells.compactMap { cell in (cell.lastValidated ?? cell.createdAt).map { (cell, $0) } }
        if let newest = dated.max(by: { $0.1 < $1.1 }) { return newest.0 }
        return cells.first
    }

    /// Rend la phrase du succès, ou nil quand le retrait a échoué (la raison est dans `actionError`).
    /// `reason` est facultative : vide, rien n'est envoyé ; le serveur en garde 280 caractères.
    func withdraw(_ item: MyIdentification, reason: String? = nil) async -> String? {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await run {
            let result = try await self.service.withdraw(
                siteId: item.siteId, enb: item.enb, gnb: item.gnb, pci: item.pciValue,
                cellId: item.cellId, ci: item.ci, tech: item.tech,
                reason: reason.flatMap { $0.isEmpty ? nil : String($0.prefix(280)) }
            )
            guard result.changed else {
                return .failure(result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Retrait impossible"))
            }
            return .success(String(localized: "Identification retirée."))
        }
    }

    func delete(_ item: MyIdentification) async -> String? {
        await run {
            let result = try await self.service.delete(
                siteId: item.siteId, enb: item.enb, gnb: item.gnb, pci: item.pciValue,
                cellId: item.cellId, ci: item.ci, tech: item.tech, reason: nil
            )
            guard result.changed else {
                return .failure(result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Suppression impossible"))
            }
            // Une ligne que d'autres ont confirmée est seulement retirée pour soi.
            return .success(result.softWithdrawn > 0
                ? String(localized: "Identification retirée pour toi. D’autres l’ont confirmée, leur travail reste.")
                : String(localized: "Identification supprimée."))
        }
    }

    private enum Answer { case success(String), failure(String) }

    private func run(_ request: @escaping () async throws -> Answer) async -> String? {
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            switch try await request() {
            case let .success(note):
                Haptics.success()
                return note
            case let .failure(reason):
                actionError = reason
            }
        } catch {
            actionError = IdentificationCorrectionText.failure(error)
        }
        Haptics.error()
        return nil
    }
}

/// « Tes identifications ici » : l'identification du membre sur ce support, une rangée par
/// cellule, puis « Corriger » et « Retirer ». « Corriger » ouvre directement les secteurs de la
/// cellule observée, ou le choix du support quand la ligne est en conflit ou sans cellule.
struct IdentificationCorrectionBlock: View {
    @StateObject private var model: IdentificationCorrectionModel
    @EnvironmentObject private var services: AppServices
    @State private var route: Route?
    /// « Pas le bon support ? » depuis les secteurs : la carte s'ouvre une fois la feuille fermée.
    @State private var movesAfterSectors = false
    @State private var confirmingWithdraw = false
    @State private var withdrawReason = ""
    @State private var confirmingDelete = false
    let onOutcome: (IdentificationCorrectionOutcome) -> Void

    private enum Route: Identifiable {
        case sectors(cell: MyIdentification, cells: [MyIdentification])
        case move(MyIdentification)

        var id: String {
            switch self {
            case let .sectors(cell, _): return "sectors|\(cell.id)"
            case let .move(node): return "move|\(node.id)"
            }
        }
    }

    init(
        target: IdentificationCorrectionTarget,
        service: IdentifyServicing,
        onOutcome: @escaping (IdentificationCorrectionOutcome) -> Void
    ) {
        _model = StateObject(wrappedValue: IdentificationCorrectionModel(target: target, service: service))
        self.onOutcome = onOutcome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Tes identifications ici")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityIdentifier("identification.block")
        .task { await model.load() }
        .sheet(item: $route, onDismiss: openMoveIfAsked) { route in
            switch route {
            case let .sectors(cell, cells):
                SectorEditSheet(
                    item: cell,
                    cells: cells,
                    antennas: services.antennas,
                    identify: services.identify,
                    trustsSectorCheck: model.checks.sectorCheck == .ok,
                    onMove: {
                        movesAfterSectors = true
                        self.route = nil
                    },
                    onReload: { Task { await model.load() } },
                    onDone: {
                        onOutcome(.edited)
                        Task { await model.load(quietly: true) }
                    }
                )
            case let .move(node):
                SiteRemapSheet(
                    item: node,
                    antennas: services.antennas,
                    identify: services.identify,
                    location: services.location,
                    markets: services.markets,
                    onReload: { Task { await model.load() } },
                    onDone: { siteId in onOutcome(.moved(siteId: siteId)) }
                )
            }
        }
        .alert("Retirer cette identification ?", isPresented: $confirmingWithdraw) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer définitivement", role: .destructive) { confirmingDelete = true }
            TextField("Pourquoi ? (facultatif)", text: $withdrawReason)
            Button("Retirer") { finish { node in await model.withdraw(node, reason: withdrawReason) } }
        } message: {
            Text("La ligne disparaît de la carte et ses points te sont retirés. Tu pourras la valider à nouveau plus tard.")
        }
        .alert("Supprimer définitivement ?", isPresented: $confirmingDelete) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) { finish { node in await model.delete(node) } }
        } message: {
            Text(deleteMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                RoundedRectangle(cornerRadius: 6).fill(SQColor.chip).frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 6).fill(SQColor.chip).frame(width: 220, height: 12)
                Text("Ta nouvelle identification arrive…")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Recherche de l’identification"))
        case .notFound:
            missing(String(localized: "Ta nouvelle identification n’apparaît pas encore. Elle est bien enregistrée."))
        case let .failed(message):
            missing(message)
        case let .found(node, cells):
            found(node: node, cells: cells)
        }
    }

    private func missing(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(message)
                .font(SQType.subhead(.regular))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Recharger"), systemImage: "arrow.clockwise", style: .secondary) {
                Task { await model.load() }
            }
            .accessibilityIdentifier("identification.block.reload")
        }
    }

    private func found(node: MyIdentification, cells: [MyIdentification]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            // Une cellule par cellId ou CI ; une ligne pci sans cellule compte pour une.
            nodeHeader(node, cellCount: SectorRow.rows(cells).reduce(0) { $0 + max($1.cells.count, 1) })
            if node.conflict {
                Text(conflictLine(node))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cells.isEmpty {
                // Tuile interne crème, une rangée par PCI séparée d'un filet (DESIGN.md, SECTOR-PCI r1).
                let rows = SectorRow.rows(cells)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if row.pci == nil, index == 0 || rows[index - 1].pci != nil {
                            Text("Sans PCI")
                                .font(SQType.micro.weight(.semibold))
                                .tracking(1.2)
                                .textCase(.uppercase)
                                .foregroundStyle(SQColor.labelTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, SQSpace.md)
                                .padding(.top, SQSpace.sm)
                                .accessibilityAddTraits(.isHeader)
                        } else if index > 0 {
                            Rectangle()
                                .fill(SQColor.separator)
                                .frame(height: 1 / UIScreen.main.scale)
                                .padding(.leading, SQSpace.md + 32 + SQSpace.sm2)
                                .accessibilityHidden(true)
                        }
                        // Toucher une rangée ouvre le schéma de SON PCI (règle commune avec le Web).
                        Button {
                            route = .sectors(cell: row.primary, cells: cells)
                        } label: {
                            HStack(spacing: SQSpace.sm2) {
                                sectorRowView(row)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(SQColor.labelTertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.sm)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .accessibilityHint(Text("Ouvre les secteurs de cette cellule"))
                        .accessibilityIdentifier("identification.block.cell.\(row.primary.id)")
                    }
                }
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            if let error = model.actionError {
                SQNotice(message: error, tone: .danger)
                    .accessibilityIdentifier("identification.actionError")
                if IdentificationCorrectionText.needsReload(error) {
                    GradientButton(IdentificationCorrectionText.reload, systemImage: "arrow.clockwise", style: .secondary) {
                        Task { await model.load() }
                    }
                    .accessibilityIdentifier("identification.block.reloadMine")
                }
            }
            HStack(spacing: SQSpace.sm) {
                GradientButton(String(localized: "Corriger"), systemImage: "pencil", isBusy: model.isBusy, style: .secondary) {
                    correct(node: node, cells: cells)
                }
                .accessibilityIdentifier("radioLogs.identify.correct")
                Button("Retirer") { withdrawReason = ""; confirmingWithdraw = true }
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.dangerInk)
                    .frame(minWidth: 88, minHeight: 44)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("identification.block.withdraw")
            }
        }
    }

    /// En-tête du nœud : pastille, « eNB 608665 », puis « Bouygues Telecom · 6 cellules ».
    private func nodeHeader(_ node: MyIdentification, cellCount: Int) -> some View {
        HStack(spacing: SQSpace.sm2) {
            SQIconPastille(
                systemImage: node.conflict ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                size: 36,
                tint: node.conflict ? OutageTint.degradedInk : SQColor.success,
                fill: node.conflict ? SQColor.warningSoft : SQColor.successSoft
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.nodeLabel)
                    .font(.sqTechnical(15, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(verbatim: [node.operatorDisplayName,
                                cellCount == 0 ? String(localized: "Aucune cellule") : String(localized: "\(cellCount) cellules")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if node.conflict {
                SignalPill(text: "En conflit")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Pastille du secteur, nom du PCI, sa référence, puis ses cellules en sous-lignes.
    private func sectorRowView(_ row: SectorRow) -> some View {
        HStack(spacing: SQSpace.sm2) {
            sectorBadge(row)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.label)
                    .font(SQType.rowTitle)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                if row.isMisaligned {
                    reference(SectorRowText.misaligned(row.storedSectors), systemImage: "exclamationmark.triangle.fill",
                              tint: OutageTint.degradedInk)
                } else if model.checks.sectorCheck == .ok {
                    // La référence vient du numéro de cellule, même sans secteur enregistré.
                    switch row.reference {
                    case let .sector(derived) where row.commonSectors == [derived]:
                        reference(String(localized: "Conforme au numéro de cellule"), systemImage: "checkmark", tint: SQColor.success)
                    case let .sector(derived):
                        reference(String(localized: "Le numéro de cellule indique le secteur \(derived)"),
                                  systemImage: "diamond.fill", tint: OutageTint.degradedInk)
                    case .disagreement:
                        reference(String(localized: "Désaccord entre cellules"), systemImage: "questionmark.diamond",
                                  tint: SQColor.labelSecondary)
                    case .none:
                        EmptyView()
                    }
                }
                if row.pci != nil {
                    ForEach(row.cells) { cell in
                        Text(verbatim: cellLine(cell, showsSector: row.reference == .disagreement))
                            .font(SQType.caption)
                            .monospacedDigit()
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
            Spacer(minLength: SQSpace.sm)
        }
        .accessibilityElement(children: .combine)
    }

    /// « Cellule 154834434 · B20 », avec le secteur de son numéro quand les cellules divergent.
    private func cellLine(_ cell: MyIdentification, showsSector: Bool) -> String {
        var parts = [cell.cellId.flatMap { $0.isEmpty ? nil : String(localized: "Cellule \($0)") } ?? cell.ci.map { "CI \($0)" } ?? ""]
        if let band = cell.band { parts.append(cell.techLabel == "5G" ? "n\(band)" : "B\(band)") }
        if showsSector, let derived = cell.referenceSector { parts.append(String(localized: "secteur \(derived)")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Numéro du secteur dans un disque, « – » quand aucun n'est enregistré, « ! » en désaccord.
    private func sectorBadge(_ row: SectorRow) -> some View {
        let sectors = row.commonSectors
        return Text(verbatim: row.isMisaligned ? "!" : sectors.isEmpty ? "–" : sectors.map(String.init).joined(separator: ","))
            .font(SQFont.display(13, .bold, relativeTo: .subheadline))
            .monospacedDigit()
            .foregroundStyle(row.isMisaligned ? OutageTint.degradedInk : sectors.isEmpty ? SQColor.labelSecondary : SQColor.label)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .frame(width: 32, height: 32)
            .background(SQColor.surface, in: Circle())
            // Lu après le nom du PCI : « PCI 181, secteur 2, Conforme au numéro de cellule ».
            .accessibilityLabel(sectorText(row).map { Text(verbatim: $0) } ?? Text("Aucun secteur"))
            .accessibilitySortPriority(-1)
            // En désaccord, la ligne « secteurs 1 et 2 · à réaligner » le dit déjà.
            .accessibilityHidden(row.isMisaligned)
    }

    private func reference(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage).imageScale(.small).foregroundStyle(tint)
        }
        .font(SQType.caption)
        .foregroundStyle(SQColor.labelSecondary)
    }

    private func sectorText(_ row: SectorRow) -> String? {
        let sectors = row.commonSectors
        switch sectors.count {
        case 0: return nil
        case 1: return String(localized: "secteur \(sectors[0])")
        default: return String(localized: "secteurs \(sectors.map(String.init).joined(separator: ", "))")
        }
    }

    private func conflictLine(_ node: MyIdentification) -> String {
        guard let other = node.conflictSiteId else {
            return String(localized: "Un autre support a plus de validations pour ce nœud.")
        }
        // `validations` compte des validations, pas des personnes : règle commune aux trois apps.
        switch node.conflictSiteValidations {
        case .some(1): return String(localized: "1 validation la place sur le support \(other).")
        case let .some(count): return String(localized: "\(count) validations la placent sur le support \(other).")
        case .none: return String(localized: "Plus validée sur le support \(other).")
        }
    }

    private var deleteMessage: String {
        String(localized: "Tes contributions seules sont effacées pour de bon. Si d’autres personnes ont confirmé la ligne, elle est seulement retirée pour toi : leur travail reste.")
    }

    /// Secteurs de la cellule observée ; la carte quand la ligne est en conflit ou sans cellule.
    private func correct(node: MyIdentification, cells: [MyIdentification]) {
        if node.conflict || cells.isEmpty {
            route = .move(node)
        } else if let cell = IdentificationCorrectionModel.observedCell(in: cells, observedPcis: model.target.observedPcis) {
            route = .sectors(cell: cell, cells: cells)
        }
    }

    private func openMoveIfAsked() {
        guard movesAfterSectors else { return }
        movesAfterSectors = false
        if case let .found(node, _) = model.state { route = .move(node) }
    }

    /// Retrait et suppression : le bloc garde la raison d'un échec, un succès est annoncé à l'écran.
    private func finish(_ action: @escaping @MainActor (MyIdentification) async -> String?) {
        guard case let .found(node, _) = model.state else { return }
        Task {
            guard let note = await action(node) else { return }
            onOutcome(.withdrawn(note: note))
        }
    }
}
