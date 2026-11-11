import SwiftUI

/// « Tes identifications ici » sur la fiche d'un support (choix d'Alexandre du 11/11,
/// comme Android) : un bloc de correction par eNB/gNB que le membre a placé sur CE
/// support. Rien ne s'affiche sans compte, sans identification ici, ou si la lecture
/// échoue : la fiche reste la même pour qui n'a rien identifié.
@MainActor
final class SiteIdentificationsModel: ObservableObject {
    @Published private(set) var targets: [IdentificationCorrectionTarget] = []

    let siteId: String
    private let service: IdentifyServicing

    init(siteId: String, service: IdentifyServicing) {
        self.siteId = siteId
        self.service = service
    }

    /// Lit les lignes du membre sur ce support jusqu'au bout du curseur, puis garde
    /// ses nœuds eNB/gNB. Une lecture incomplète ou refusée ne montre rien.
    func load() async {
        guard LocalAccountScope.sessionSnapshot() != nil else { targets = []; return }
        var items: [MyIdentification] = []
        var cursor: String?
        do {
            for _ in 0..<IdentificationCorrectionModel.maxPages {
                let page = try await service.minePage(cursor: cursor, siteId: siteId, enb: nil, gnb: nil)
                items += page.identifications
                guard let next = page.nextCursor else {
                    targets = Self.targets(siteId: siteId, in: items)
                    return
                }
                cursor = next
            }
        } catch {
            guard !error.isCancellation else { return }
        }
        targets = []
    }

    /// Un nœud eNB/gNB par bloc, dans l'ordre des groupes ; jamais une ligne sans nœud.
    nonisolated static func targets(siteId: String, in items: [MyIdentification]) -> [IdentificationCorrectionTarget] {
        var seen = Set<String>()
        return IdentifiedNodeGroup.group(items).compactMap { group in
            guard group.kind == .enb || group.kind == .gnb, group.representative.siteId == siteId else { return nil }
            let target = IdentificationCorrectionTarget(siteId: siteId, kind: group.kind, node: group.nodeValue)
            return seen.insert(target.id).inserted ? target : nil
        }
    }
}

struct SiteIdentificationsSection: View {
    @StateObject private var model: SiteIdentificationsModel
    private let service: IdentifyServicing

    init(siteId: String, service: IdentifyServicing) {
        _model = StateObject(wrappedValue: SiteIdentificationsModel(siteId: siteId, service: service))
        self.service = service
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ForEach(model.targets) { target in
                // Retirée ou déplacée : le nœud n'est plus ici, la liste se relit.
                IdentificationCorrectionBlock(target: target, service: service) { outcome in
                    if case .edited = outcome { return }
                    Task { await model.load() }
                }
            }
        }
        .task(id: model.siteId) { await model.load() }
        .accessibilityIdentifier("antenna.detail.myIdentifications")
    }
}
