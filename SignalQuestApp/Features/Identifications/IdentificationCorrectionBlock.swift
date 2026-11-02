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
        if !quietly { state = .loading }
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

    /// La cellule que le membre a sous les yeux : la première dont le PCI a été vu, sinon la première.
    nonisolated static func observedCell(
        in cells: [MyIdentification],
        observedPcis: [Int]
    ) -> MyIdentification? {
        for pci in observedPcis {
            if let cell = cells.first(where: { $0.pci == pci || $0.pciValue == String(pci) }) { return cell }
        }
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
            actionError = error.userFacingMessage
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
                .font(SQType.subhead(.bold))
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
            HStack(spacing: SQSpace.sm) {
                Text(node.nodeLabel)
                    .font(.sqTechnical(15, .semibold))
                    .foregroundStyle(SQColor.label)
                if node.conflict {
                    SignalPill(text: "En conflit")
                }
            }
            if node.conflict {
                Text(conflictLine(node))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cells.isEmpty {
                Text("Aucune cellule")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    ForEach(cells) { cell in
                        cellRow(cell)
                    }
                }
            }
            if let error = model.actionError {
                SQNotice(message: error, tone: .danger)
                    .accessibilityIdentifier("identification.actionError")
            }
            HStack(spacing: SQSpace.sm) {
                GradientButton(String(localized: "Corriger"), systemImage: "pencil", isBusy: model.isBusy, style: .secondary) {
                    correct(node: node, cells: cells)
                }
                .accessibilityIdentifier("radioLogs.identify.correct")
                Button("Retirer") { withdrawReason = ""; confirmingWithdraw = true }
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.ink2)
                    .frame(minWidth: 88, minHeight: 44)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("identification.block.withdraw")
            }
        }
    }

    /// « PCI 214 ····· secteur 2 », puis la référence du PCI quand elle est connue.
    private func cellRow(_ cell: MyIdentification) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SQSpace.sm) {
                Text(cell.nodeLabel)
                    .font(SQType.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                Spacer(minLength: SQSpace.sm)
                if let sectors = sectorText(cell) {
                    Text(sectors)
                        .font(SQType.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                }
            }
            if model.checks.sectorCheck == .ok, let derived = cell.derivedSector {
                // `derivedSector` dit le secteur prouvé, même sans secteur enregistré.
                if cell.sectors == [derived] {
                    reference(String(localized: "Conforme au PCI"), systemImage: "checkmark", tint: SQColor.success)
                } else {
                    reference(String(localized: "Le PCI indique le secteur \(derived)"), systemImage: "diamond.fill", tint: OutageTint.degradedInk)
                }
            } else if model.checks.sectorCheck == .ok, let check = cell.sectorCheck {
                switch check.status {
                case .mismatch:
                    if let expected = check.expected {
                        reference(String(localized: "Le PCI indique le secteur \(expected)"), systemImage: "diamond.fill", tint: OutageTint.degradedInk)
                    }
                case .match:
                    reference(String(localized: "Conforme au PCI"), systemImage: "checkmark", tint: SQColor.success)
                case .notApplicable, .unknown:
                    EmptyView()
                }
            }
        }
        .accessibilityElement(children: .combine)
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

    private func sectorText(_ cell: MyIdentification) -> String? {
        switch cell.sectors.count {
        case 0: return nil
        case 1: return String(localized: "secteur \(cell.sectors[0])")
        default: return String(localized: "secteurs \(cell.sectors.map(String.init).joined(separator: ", "))")
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
