import SwiftUI

/// L'identification qu'on vient de faire, telle que l'écran d'identification la connaît :
/// le support retenu et le nœud (eNB/gNB).
struct IdentificationCorrectionTarget: Identifiable, Equatable, Sendable {
    let siteId: String
    let kind: IdentifiedNodeKind
    let node: String

    var id: String { "\(siteId)|\(kind.rawValue)|\(node)" }
}

/// Ce qu'une correction a changé, pour que l'écran d'identification se remette à jour.
enum IdentificationCorrectionOutcome: Equatable, Sendable {
    /// Retirée ou supprimée : le nœud est de nouveau à identifier.
    case withdrawn
    /// Déplacée : le support où se trouve désormais le nœud.
    case moved(siteId: String)
    /// Secteur corrigé : le nœud reste sur le même support.
    case edited
}

/// Retrouve l'identification qu'on vient de faire dans « Mes identifications », puis la
/// retire ou la supprime. Les déplacements et les secteurs passent par les feuilles de la fiche.
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
    /// Retrait ou suppression refusés : affiché dans la fiche, qui reste ouverte.
    @Published private(set) var actionError: String?

    let target: IdentificationCorrectionTarget
    private let service: IdentifyServicing

    /// Pages lues au plus : la liste va du plus récent au plus ancien, l'identification
    /// qu'on vient de faire est presque toujours sur la première.
    static let maxPages = 5

    init(target: IdentificationCorrectionTarget, service: IdentifyServicing) {
        self.target = target
        self.service = service
    }

    /// `quietly` : le consensus a bougé, la fiche reste affichée le temps de relire.
    func load(quietly: Bool = false) async {
        if !quietly { state = .loading }
        var items: [MyIdentification] = []
        var cursor: String?
        var checks: IdentificationChecks?
        do {
            for _ in 0..<Self.maxPages {
                let page = try await service.minePage(cursor: cursor, conflictOnly: false, includeRelated: true, limit: nil)
                items += page.identifications
                checks = checks.map { $0.merged(with: page.checks) } ?? page.checks
                if let match = Self.match(target, in: items) {
                    self.checks = checks ?? .unavailable
                    state = .found(node: match.node, cells: match.cells)
                    return
                }
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            state = .notFound
        } catch {
            // Relecture discrète ratée : la fiche affichée reste, avec son message.
            guard !error.isCancellation, !quietly else { return }
            state = .failed(error.userFacingMessage)
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

    func withdraw(_ item: MyIdentification) async -> Bool {
        await run {
            let result = try await self.service.withdraw(
                siteId: item.siteId, enb: item.enb, gnb: item.gnb, pci: item.pciValue,
                cellId: item.cellId, ci: item.ci, tech: item.tech, reason: nil
            )
            return result.changed ? nil : (result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Retrait impossible"))
        }
    }

    func delete(_ item: MyIdentification) async -> Bool {
        await run {
            let result = try await self.service.delete(
                siteId: item.siteId, enb: item.enb, gnb: item.gnb, pci: item.pciValue,
                cellId: item.cellId, ci: item.ci, tech: item.tech, reason: nil
            )
            return result.changed ? nil : (result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Suppression impossible"))
        }
    }

    /// `request` rend le message d'échec, ou nil quand la correction a changé quelque chose.
    private func run(_ request: @escaping () async throws -> String?) async -> Bool {
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            if let failure = try await request() {
                actionError = failure
            } else {
                Haptics.success()
                return true
            }
        } catch {
            actionError = error.userFacingMessage
        }
        Haptics.error()
        return false
    }
}

/// « Corriger », juste après une identification : la fiche de cette identification, sans
/// passer par la liste. Le temps de la retrouver, la feuille dit qu'elle la cherche.
struct IdentificationCorrectionSheet: View {
    @StateObject private var model: IdentificationCorrectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var moved = false
    let onOutcome: (IdentificationCorrectionOutcome) -> Void

    init(
        target: IdentificationCorrectionTarget,
        service: IdentifyServicing,
        onOutcome: @escaping (IdentificationCorrectionOutcome) -> Void
    ) {
        _model = StateObject(wrappedValue: IdentificationCorrectionModel(target: target, service: service))
        self.onOutcome = onOutcome
    }

    var body: some View {
        Group {
            switch model.state {
            case let .found(node, cells):
                IdentificationDetailSheet(
                    item: node,
                    checks: model.checks,
                    isWithdrawing: model.isBusy,
                    onWithdraw: { finish { await model.withdraw(node) } },
                    onDelete: { finish { await model.delete(node) } },
                    // Appelé après un déplacement (précédé d'`onMoved`) ou un secteur corrigé.
                    onChanged: { if !moved { onOutcome(.edited) } },
                    onStale: { Task { await model.load(quietly: true) } },
                    onMoved: { siteId in
                        moved = true
                        onOutcome(.moved(siteId: siteId))
                    },
                    cells: cells,
                    actionError: model.actionError
                )
            case .loading:
                placeholder {
                    SQSpinner()
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityLabel(Text("Recherche de l’identification"))
                }
            case .notFound:
                placeholder {
                    ErrorStateView(
                        title: String(localized: "Identification introuvable"),
                        message: String(localized: "Elle n’apparaît pas encore dans « Mes identifications ». Réessaie dans un instant.")
                    ) { Task { await model.load() } }
                }
            case let .failed(message):
                placeholder {
                    ErrorStateView(title: String(localized: "Identification indisponible"), message: message) {
                        Task { await model.load() }
                    }
                }
            }
        }
        .task { await model.load() }
    }

    /// Retrait et suppression : la fiche se ferme seulement si la correction a changé quelque chose.
    private func finish(_ action: @escaping @MainActor () async -> Bool) {
        Task {
            guard await action() else { return }
            onOutcome(.withdrawn)
            dismiss()
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapSheetHeader(title: String(localized: "Identification"), closeIdentifier: "identification.close") { dismiss() }
                content()
            }
            .padding(SQSpace.lg)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("identification.correction")
    }
}
