import SwiftUI
import UIKit

/// SECTOR-ORIGIN r1, planche validée par Alexandre le 18/11 : la ligne de statut d'un secteur et
/// le geste « Je confirme ». Partagés par « Tes identifications ici » (fiche, journal Radio) et le
/// détail d'une ligne dans « Mes identifications ».
enum SectorStatusText {
    static func label(_ status: SectorStatus) -> String {
        switch status {
        case .verifiedOnSite: return String(localized: "Vérifié sur place")
        case .confirmed: return String(localized: "Confirmé par un membre")
        case .manualEdit: return String(localized: "Corrigé par un membre")
        case .operatorRule: return String(localized: "Auto (règle opérateur)")
        case .azimuth: return String(localized: "Déduit de l’azimut")
        case .client: return String(localized: "Saisi par l’app")
        case .legacyMatchesRule: return String(localized: "Ancien, conforme à la règle")
        case .legacyDiffersRule: return String(localized: "Ancien, saisi à la main ?")
        case .legacyUnknown, .unrecognized: return String(localized: "Origine inconnue")
        }
    }

    static func systemImage(_ status: SectorStatus) -> String? {
        switch status {
        case .verifiedOnSite: return "checkmark"
        case .legacyDiffersRule: return "diamond.fill"
        default: return nil
        }
    }

    static func tint(_ status: SectorStatus) -> Color {
        switch status {
        case .verifiedOnSite: return OutageTint.resolvedInk
        case .legacyDiffersRule: return OutageTint.degradedInk
        case .legacyUnknown, .unrecognized: return SQColor.labelSecondary
        default: return SQColor.label
        }
    }

    /// « Confirmé par 3 membres, dont 2 sur place » : des comptes, jamais d'identité.
    static func counts(_ counts: SectorConfirmCounts) -> String {
        switch (counts.members, counts.verified) {
        case (1, 0): return String(localized: "Confirmé par 1 membre")
        case (1, _): return String(localized: "Confirmé par 1 membre, sur place")
        case let (members, 0): return String(localized: "Confirmé par \(members) membres")
        case let (members, verified): return String(localized: "Confirmé par \(members) membres, dont \(verified) sur place")
        }
    }

    /// La ligne `confirmed` de « Mes identifications » est celle du membre : c'est lui qui a confirmé.
    static var ownConfirmation: String { String(localized: "Toi, sans relevé radio de cette cellule") }

    static func proof(_ proof: SectorConfirmProof) -> String {
        switch proof {
        case .radioLog: return String(localized: "Preuve : ton journal Radio")
        case .coverage: return String(localized: "Preuve : ta couverture")
        case .speedtest: return String(localized: "Preuve : ton speedtest")
        }
    }

    /// Option 1 de la planche : seulement après une réponse sans preuve.
    static var noProof: String {
        String(localized: "Pour passer à « Vérifié sur place », il faut un relevé de cette cellule fait avec un appareil Android (journal Radio, couverture ou speedtest) dans les 30 derniers jours. Confirme à nouveau ensuite.")
    }

    static func skipped(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 cellule de ce PCI porte un autre secteur : elle reste telle quelle.")
            : String(localized: "\(count) cellules de ce PCI portent un autre secteur : elles restent telles quelles.")
    }

    static func sectors(_ sectors: [Int]) -> String {
        sectors.count == 1 ? String(localized: "Secteur \(sectors[0])")
            : String(localized: "Secteurs \(sectors.map(String.init).joined(separator: ", "))")
    }

    static func pending(_ target: SectorConfirmTarget) -> String {
        String(localized: "\(sectors(target.sectors)) confirmé pour \(target.label)")
    }

    static func countdown(_ seconds: Int) -> String {
        String(localized: "Confirmation dans \(seconds) s…")
    }

    static func changed(to sectors: [Int]?) -> String {
        guard let sectors, !sectors.isEmpty else {
            return String(localized: "Le secteur a changé entre-temps. Rien n’a été confirmé.")
        }
        return sectors.count == 1
            ? String(localized: "Le secteur est passé à \(sectors[0]) entre-temps. Rien n’a été confirmé.")
            : String(localized: "Les secteurs sont passés à \(sectors.map(String.init).joined(separator: ", ")) entre-temps. Rien n’a été confirmé.")
    }

    /// « Confirmer à nouveau » quand MA confirmation est sans preuve, pour en obtenir une.
    static func buttonTitle(own: SectorStatus?) -> String {
        own == .confirmed ? String(localized: "Confirmer à nouveau") : String(localized: "Je confirme")
    }
}

/// Ce que le membre confirme : le même ciblage qu'`edit-sectors` et les secteurs qu'il voit.
struct SectorConfirmTarget: Identifiable, Equatable, Sendable {
    let id: String
    /// « PCI 215 », « Cellule 156266497 ».
    let label: String
    let siteId: String
    let enb: String?
    let gnb: String?
    let pci: String?
    let cellId: String?
    let ci: String?
    let tech: String?
    let operatorName: String
    let marketCode: String?
    let sectors: [Int]
    let status: SectorStatus
    /// Ma confirmation encore valide (`myConfirmation`), qui choisit le libellé du bouton.
    var own: SectorStatus?

    /// r1.3.4 (« Griser pour moi seul ») : grisé quand MA confirmation est vérifiée sur place,
    /// quel que soit le statut de la ligne, qui peut venir d'un autre membre.
    var canConfirm: Bool { own != .verifiedOnSite }

    /// Une rangée de « Tes identifications ici » : portée PCI quand elle a un nœud (le serveur
    /// compare la ligne PCI et confirme les cellules égales), sinon la ligne seule. Rien à
    /// confirmer sans statut, sans secteur, ou quand les lignes du PCI ne s'accordent pas.
    static func row(_ row: SectorRow) -> SectorConfirmTarget? {
        let line = row.primary
        guard let status = line.sectorStatus, !row.isMisaligned, !row.commonSectors.isEmpty else { return nil }
        if let pci = row.pci, row.usesPciScope {
            return SectorConfirmTarget(id: row.id, label: row.label, siteId: line.siteId, enb: row.enb, gnb: row.gnb,
                                       pci: String(pci), cellId: nil, ci: nil, tech: line.tech,
                                       operatorName: line.operatorName ?? "", marketCode: line.marketCode,
                                       sectors: row.commonSectors, status: status, own: line.ownConfirmation)
        }
        return Self.line(line, id: row.id, label: row.label)
    }

    /// Une ligne seule : portée PCI pour une ligne pci rattachée à un nœud, sinon la cellule.
    static func line(_ line: MyIdentification, id: String? = nil, label: String? = nil,
                     status override: SectorStatus? = nil, own ownOverride: SectorStatus? = nil) -> SectorConfirmTarget? {
        guard let status = override ?? line.sectorStatus, !line.sectors.isEmpty,
              line.kind == .pci || line.kind == .cellid || line.pciValue != nil || line.cellId != nil else { return nil }
        let pciScope = line.kind == .pci && (line.enb != nil || line.gnb != nil)
        return SectorConfirmTarget(id: id ?? line.id, label: label ?? line.cellLabel, siteId: line.siteId,
                                   enb: line.enb, gnb: line.gnb, pci: line.pciValue,
                                   cellId: pciScope ? nil : line.cellId, ci: pciScope ? nil : line.ci,
                                   tech: line.tech, operatorName: line.operatorName ?? "", marketCode: line.marketCode,
                                   sectors: line.sectors.sorted(), status: status,
                                   own: ownOverride ?? line.ownConfirmation)
    }
}

/// Le geste « Je confirme » : 8 s pendant lesquelles rien ne part (« Annuler » ne coûte aucun
/// appel), puis l'appel, puis une relecture des lignes du membre pour afficher les statuts servis.
@MainActor
final class SectorConfirmModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case counting(SectorConfirmTarget, secondsLeft: Int)
        case sending(SectorConfirmTarget)
    }

    struct Note: Equatable {
        let lines: [String]
        /// Statut servi par la réponse : l'écran l'affiche avant même la relecture.
        var status: SectorStatus?
    }

    static let delay = 8

    @Published private(set) var phase: Phase = .idle
    /// Après une réponse : preuve trouvée, ou la phrase « sans preuve », par rangée.
    @Published private(set) var notes: [String: Note] = [:]
    /// Conflit ou échec, affiché sous les rangées.
    @Published private(set) var message: String?

    private let service: IdentifyServicing
    private var task: Task<Void, Never>?
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(service: IdentifyServicing,
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.service = service
        self.sleep = sleep
    }

    var pendingId: String? {
        switch phase {
        case .idle: return nil
        case let .counting(target, _), let .sending(target): return target.id
        }
    }

    func secondsLeft(for id: String) -> Int? {
        if case let .counting(target, seconds) = phase, target.id == id { return seconds }
        return nil
    }

    /// `reload` relit les lignes du membre et rend les secteurs actuels de la cible, pour dire
    /// sur quel secteur la ligne est passée après un `409 SECTOR_CHANGED`.
    func start(_ target: SectorConfirmTarget, reload: @escaping @MainActor (SectorConfirmTarget) async -> [Int]?) {
        guard pendingId == nil, target.canConfirm else { return }
        message = nil
        notes[target.id] = nil
        phase = .counting(target, secondsLeft: Self.delay)
        UIAccessibility.post(notification: .announcement,
                             argument: "\(SectorStatusText.pending(target)). \(SectorStatusText.countdown(Self.delay))")
        task = Task { [weak self] in
            for remaining in stride(from: Self.delay - 1, through: 0, by: -1) {
                guard let self else { return }
                do { try await self.sleep(1_000_000_000) } catch { return }
                guard !Task.isCancelled, case .counting = self.phase else { return }
                if remaining > 0 { self.phase = .counting(target, secondsLeft: remaining) }
            }
            await self?.send(target, reload: reload)
        }
    }

    func cancel() {
        guard case .counting = phase else { return }
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func send(_ target: SectorConfirmTarget, reload: @escaping @MainActor (SectorConfirmTarget) async -> [Int]?) async {
        phase = .sending(target)
        defer { phase = .idle; task = nil }
        do {
            let result = try await service.confirmSector(
                siteId: target.siteId, enb: target.enb, gnb: target.gnb, pci: target.pci,
                cellId: target.cellId, ci: target.ci, tech: target.tech,
                operatorName: target.operatorName, marketCode: target.marketCode, sectors: target.sectors
            )
            var lines = [result.proof.map(SectorStatusText.proof) ?? SectorStatusText.noProof]
            if result.skipped > 0 { lines.append(SectorStatusText.skipped(result.skipped)) }
            notes[target.id] = Note(lines: lines, status: result.sectorStatus)
            Haptics.success()
            _ = await reload(target)
        } catch APIError.http(409, "SECTOR_CHANGED"?, _, _, _) {
            Haptics.error()
            let current = await reload(target)
            message = SectorStatusText.changed(to: current)
        } catch APIError.http(404, _, _, _, _) {
            Haptics.error()
            message = IdentificationCorrectionText.nothingChanged
        } catch {
            guard !error.isCancellation else { return }
            Haptics.error()
            message = IdentificationCorrectionText.failure(error)
        }
    }
}

/// Ligne de statut d'une cellule (planche « Fiche antenne · origine des secteurs ») : l'étiquette,
/// le secteur attendu par la règle s'il diffère, les comptes de la fiche, et le décompte en cours.
struct SectorStatusLine: View {
    let status: SectorStatus
    /// Secteur que la règle de l'opérateur indique, seulement quand il diffère du secteur enregistré.
    var expected: Int?
    var counts: SectorConfirmCounts?
    /// Ma confirmation : « Toi, sans relevé radio » quand elle est sans preuve.
    var own: SectorStatus?
    var secondsLeft: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label {
                Text(verbatim: SectorStatusText.label(status))
                    .font(SQType.caption.weight(.semibold))
                    .foregroundStyle(SectorStatusText.tint(status))
            } icon: {
                if let image = SectorStatusText.systemImage(status) {
                    Image(systemName: image).imageScale(.small).foregroundStyle(SectorStatusText.tint(status))
                }
            }
            .labelStyle(SectorStatusLabelStyle(hasIcon: SectorStatusText.systemImage(status) != nil))
            ForEach(details, id: \.self) { line in
                Text(verbatim: line)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: [String] {
        var lines: [String] = []
        if let secondsLeft { lines.append(SectorStatusText.countdown(secondsLeft)) }
        if let expected { lines.append(String(localized: "Le numéro de cellule indique le secteur \(expected)")) }
        if let counts, counts.members > 0 {
            lines.append(SectorStatusText.counts(counts))
        } else if own == .confirmed {
            lines.append(SectorStatusText.ownConfirmation)
        }
        return lines
    }
}

private struct SectorStatusLabelStyle: LabelStyle {
    let hasIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if hasIcon { configuration.icon }
            configuration.title
        }
    }
}

/// Le bouton « Je confirme » / « Confirmer à nouveau », grisé sur MA confirmation vérifiée et hors ligne.
struct SectorConfirmButton: View {
    let target: SectorConfirmTarget
    @ObservedObject var model: SectorConfirmModel
    let isOnline: Bool
    let reload: @MainActor (SectorConfirmTarget) async -> [Int]?

    var body: some View {
        let isPending = model.pendingId == target.id
        Button {
            model.start(target, reload: reload)
        } label: {
            HStack(spacing: SQSpace.xs) {
                if case .sending = model.phase, isPending { SQSpinner() }
                Text(verbatim: SectorStatusText.buttonTitle(own: target.own))
            }
            .font(SQType.caption.weight(.semibold))
            .foregroundStyle(enabled ? SQColor.label : SQColor.labelTertiary)
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .strokeBorder(SQColor.separator, lineWidth: 1)
                    .background(enabled ? SQColor.surface : .clear,
                                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: "\(SectorStatusText.buttonTitle(own: target.own)), \(SectorStatusText.sectors(target.sectors)), \(target.label)"))
        .accessibilityIdentifier("identification.sector.confirm.\(target.id)")
    }

    private var enabled: Bool {
        target.canConfirm && isOnline && model.pendingId == nil
    }
}

/// Le bandeau des 8 s (« Secteur 2 confirmé pour PCI 215 · Annuler »), puis le conflit ou l'échec.
struct SectorConfirmBanner: View {
    @ObservedObject var model: SectorConfirmModel

    var body: some View {
        if case let .counting(target, _) = model.phase {
            HStack(spacing: SQSpace.sm) {
                Text(verbatim: SectorStatusText.pending(target))
                    .font(SQType.subhead(.regular))
                    .foregroundStyle(SQColor.onInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: SQSpace.sm)
                Button("Annuler") { model.cancel() }
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.onInk)
                    .underline()
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("identification.sector.confirm.cancel")
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
            .background(SQColor.label, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .accessibilityElement(children: .contain)
        } else if let message = model.message {
            SQNotice(message: message, tone: .warning)
                .accessibilityIdentifier("identification.sector.confirm.message")
        }
    }
}

/// Preuve ou phrase « sans preuve » sous une rangée, après la réponse du serveur.
struct SectorConfirmNoteView: View {
    let note: SectorConfirmModel.Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(note.lines, id: \.self) { line in
                Text(verbatim: line)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("identification.sector.confirm.note")
    }
}

/// « Origine du secteur » dans le détail d'une ligne de « Mes identifications » : le statut, le
/// geste, puis la preuve ou le conflit. Possède son propre modèle, la fiche n'en a pas besoin.
struct SectorConfirmSection: View {
    let item: MyIdentification
    /// Secteur attendu par la règle, seulement sur un écart.
    var expected: Int?
    let isOnline: Bool
    /// La liste se relit : les statuts servis remplacent ceux de la réponse.
    let onChanged: () -> Void
    @StateObject private var confirm: SectorConfirmModel

    init(item: MyIdentification, expected: Int?, service: IdentifyServicing, isOnline: Bool, onChanged: @escaping () -> Void) {
        self.item = item
        self.expected = expected
        self.isOnline = isOnline
        self.onChanged = onChanged
        _confirm = StateObject(wrappedValue: SectorConfirmModel(service: service))
    }

    var body: some View {
        if let status {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Origine du secteur").sqKicker().accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    HStack(alignment: .center, spacing: SQSpace.sm) {
                        SectorStatusLine(status: status, expected: expected, own: own,
                                         secondsLeft: target.flatMap { confirm.secondsLeft(for: $0.id) })
                        Spacer(minLength: 0)
                        if let target {
                            SectorConfirmButton(target: target, model: confirm, isOnline: isOnline) { _ in
                                onChanged()
                                return nil
                            }
                        }
                    }
                    if let note { SectorConfirmNoteView(note: note) }
                    SectorConfirmBanner(model: confirm)
                }
                .padding(SQSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
            }
            .accessibilityIdentifier("identification.sectorStatus")
        }
    }

    private var targetId: String { item.id }
    private var note: SectorConfirmModel.Note? { confirm.notes[targetId] }
    /// Le statut de la réponse tant que la ligne n'a pas été relue.
    private var status: SectorStatus? { note?.status ?? item.sectorStatus }
    /// Après ma confirmation, elle est la mienne : celle de la réponse.
    private var own: SectorStatus? { note?.status ?? item.ownConfirmation }
    private var target: SectorConfirmTarget? { SectorConfirmTarget.line(item, id: targetId, status: status, own: own) }
}
