import SwiftUI

/// SECTOR-ORIGIN r1.3 à r1.3.5 : un membre qui a voté pour une ligne peut confirmer son secteur
/// depuis la fiche. Seules les entrées où `myRole` vaut « voter » portent le bouton ; l'auteur
/// garde son geste dans « Tes identifications ici » (r1.3.3 §4).
struct SectorVoterLine: Identifiable, Equatable, Sendable {
    let target: SectorConfirmTarget
    let counts: SectorConfirmCounts?
    var id: String { target.id }

    /// Les lignes votées de la fiche, une par valeur, nœud et secteurs. Une entrée sans opérateur,
    /// sans secteur ou sans statut n'a pas de bouton : le serveur les sert ensemble (r1.3.3).
    static func lines(in identifiers: AntennaCellIdentifiers?, siteId: String, marketCode: String?) -> [SectorVoterLine] {
        guard let identifiers else { return [] }
        var seen = Set<String>()
        var lines: [SectorVoterLine] = []
        func add(kind: String, value: String, pci: String?, cellId: String?, ci: String?, enb: String?, gnb: String?,
                 tech: String?, role: String?, status: String?, mine: String?, op: String?, sectors: [Int]?,
                 members: Int?, verified: Int?) {
            guard role == "voter", let op = op?.trimmingCharacters(in: .whitespaces), !op.isEmpty,
                  let sectors = sectors?.sorted(), !sectors.isEmpty, let status = SectorStatus(raw: status) else { return }
            let id = "voter-\(kind)-\(value)-\(enb ?? gnb ?? "")-\(sectors.map(String.init).joined(separator: ","))"
            guard seen.insert(id).inserted else { return }
            let label = kind == "pci" ? "PCI \(value)" : String(localized: "Cellule \(value)")
            let target = SectorConfirmTarget(id: id, label: label, siteId: siteId, enb: enb, gnb: gnb, pci: pci,
                                             cellId: cellId, ci: ci, tech: tech, operatorName: op,
                                             marketCode: marketCode, sectors: sectors, status: status,
                                             own: SectorStatus(raw: mine))
            let counts = members.flatMap { $0 > 0 ? SectorConfirmCounts(members: $0, verified: min(verified ?? 0, $0)) : nil }
            lines.append(SectorVoterLine(target: target, counts: counts))
        }
        for entry in identifiers.pci {
            add(kind: "pci", value: entry.value, pci: entry.value, cellId: nil, ci: nil, enb: entry.enb, gnb: entry.gnb,
                tech: entry.tech, role: entry.myRole, status: entry.sectorStatus, mine: entry.myConfirmation,
                op: entry.operator, sectors: entry.sectors, members: entry.sectorConfirmations,
                verified: entry.sectorVerifiedConfirmations)
        }
        for entry in identifiers.cellId {
            add(kind: "cell", value: entry.value, pci: entry.pci, cellId: entry.value, ci: entry.ci, enb: entry.enb,
                gnb: entry.gnb, tech: entry.tech, role: entry.myRole, status: entry.sectorStatus,
                mine: entry.myConfirmation, op: entry.operator, sectors: entry.sectors,
                members: entry.sectorConfirmations, verified: entry.sectorVerifiedConfirmations)
        }
        return lines
    }
}

/// « Tes votes ici » : les lignes votées par le membre sur ce site, chacune avec son statut et
/// « Je confirme ». Après la réponse, le statut servi s'affiche aussitôt : celui de la fiche peut
/// avoir jusqu'à 5 min de retard (r1.3.5 §3), alors que `myConfirmation` est relu à jour.
struct SectorVoterSection: View {
    let identifiers: AntennaCellIdentifiers?
    let siteId: String
    let marketCode: String?
    let isOnline: Bool
    /// Relit la fiche et rend ses identifiants à jour.
    let reload: @MainActor () async -> AntennaCellIdentifiers?
    @StateObject private var confirm: SectorConfirmModel

    init(identifiers: AntennaCellIdentifiers?, siteId: String, marketCode: String?, service: IdentifyServicing,
         isOnline: Bool, reload: @escaping @MainActor () async -> AntennaCellIdentifiers?) {
        self.identifiers = identifiers
        self.siteId = siteId
        self.marketCode = marketCode
        self.isOnline = isOnline
        self.reload = reload
        _confirm = StateObject(wrappedValue: SectorConfirmModel(service: service))
    }

    var body: some View {
        let lines = SectorVoterLine.lines(in: identifiers, siteId: siteId, marketCode: marketCode)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.xs2) {
                Text("Tes votes ici").sqKicker().accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        row(line)
                            .overlay(alignment: .top) {
                                if index > 0 { Rectangle().fill(SQColor.separator).frame(height: 1) }
                            }
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                SectorConfirmBanner(model: confirm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("antenna.detail.sectorVotes")
        }
    }

    private func row(_ line: SectorVoterLine) -> some View {
        let target = line.target
        let note = confirm.notes[target.id]
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(verbatim: target.label)
                    .font(SQType.callout(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                Spacer(minLength: SQSpace.sm)
                Text(verbatim: SectorStatusText.sectors(target.sectors))
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            SectorStatusLine(status: note?.status ?? target.status, counts: line.counts, own: target.own,
                             secondsLeft: confirm.secondsLeft(for: target.id))
            if let note { SectorConfirmNoteView(note: note) }
            HStack {
                Spacer(minLength: 0)
                SectorConfirmButton(target: target, model: confirm, isOnline: isOnline) { target in
                    let fresh = await reload()
                    return SectorVoterLine.lines(in: fresh, siteId: siteId, marketCode: marketCode)
                        .first { $0.target.label == target.label && $0.target.enb == target.enb && $0.target.gnb == target.gnb }?
                        .target.sectors
                }
            }
        }
        .padding(.vertical, SQSpace.sm)
    }
}
