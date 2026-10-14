import SwiftUI

/// Fiche détaillée d'un site prévisionnel : statut d'activation (croisé ANFR),
/// technologies prévues vs en service, et métadonnées (code site, commune, dates).
/// Même squelette que `OutageDetailSheet` pour une cohérence visuelle.
struct PlannedDetailSheet: View {
    let site: PlannedSiteLive
    let operatorLabel: String
    let operatorAccent: Color

    @Environment(\.dismiss) private var dismiss

    private var status: PlannedActivationStatus { site.activation?.status ?? .planned }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                statusBanner
                if !plannedTechs.isEmpty { technologiesSection }
                infoSection
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetents([.height(460), .medium, .large])
        .sqSheet(background: SQColor.bg)
    }

    /// En-tête Halo, comme `ObservedCellSheet` : l'opérateur en petites capitales, le code du
    /// site, puis le statut ; la fermeture est un bouton rond de 44 pt.
    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                // La pastille de l'opérateur accompagne son nom : la couleur ne le porte pas seule.
                HStack(spacing: SQSpace.xs2) {
                    Circle().fill(operatorAccent).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(verbatim: operatorLabel).sqKicker()
                }
                Text(site.codeSite ?? site.idStation ?? String(localized: "Site prévisionnel"))
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                HStack(spacing: SQSpace.xs) {
                    Image(systemName: statusGlyph)
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(statusLabel)
                        .font(SQFont.body(14.5, .semibold))
                }
                // L'encre, pas le hex du marqueur : l'ambre posé en texte tombe à ~2:1.
                .foregroundStyle(statusInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "planned.detail.close") { dismiss() }
        }
    }

    private var statusBanner: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: statusGlyph)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusInk)
                .accessibilityHidden(true)
            Text(statusDescription)
                .font(SQType.subhead)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private var technologiesSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Technologies prévues")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(plannedTechs, id: \.self) { tech in
                    let state = techState(tech)
                    // Symbole ET valeur d'accessibilité : l'état d'une technologie ne tient plus à
                    // la seule couleur.
                    HStack(spacing: 4) {
                        Image(systemName: state.symbol)
                            .font(.caption2.weight(.bold))
                            .accessibilityHidden(true)
                        Text(tech)
                    }
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(state.color)
                    .sqSingleLine()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(state.color.opacity(0.14), in: Capsule(style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(state.label)
                }
            }
            HStack(spacing: SQSpace.md) {
                legendItem(.inService)
                legendItem(.pending)
                legendItem(.planned)
            }
            .font(SQType.micro)
            .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func legendItem(_ state: TechState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(state.color)
                .accessibilityHidden(true)
            Text(verbatim: state.label)
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Opérateur", operatorLabel)
            infoRow("Code site", site.codeSite)
            infoRow("Station ANFR", site.activation?.matchType == "anfr" ? site.idStation : nil)
            infoRow("Commune", site.commune?.capitalized)
            infoRow("Département", site.departement)
            infoRow("Activation 5G prévue", formattedDate(site.date5g))
            infoRow("Distance antenne", site.activation?.distanceM.map { SQUnits.distance(meters: $0) })
            infoRow(String(localized: "Mise en service"), formattedDate(site.activation?.lastInServiceDate))
        }
        .padding(.vertical, SQSpace.xs)
        .sqCardBackground()
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(LocalizedStringKey(label))
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text(value)
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            Divider().overlay(SQColor.separator).padding(.leading, SQSpace.md)
        }
    }

    // MARK: Statut

    private var plannedTechs: [String] {
        let planned = site.activation?.plannedTechnologies ?? []
        return planned.isEmpty ? site.technologies : planned
    }

    private enum TechState {
        case inService, pending, planned

        var color: Color {
            switch self {
            case .inService: return SQColor.success
            case .pending: return SQColor.warning
            case .planned: return SQColor.labelSecondary
            }
        }

        var symbol: String {
            switch self {
            case .inService: return "checkmark.circle.fill"
            case .pending: return "clock.fill"
            case .planned: return "calendar"
            }
        }

        var label: String {
            switch self {
            case .inService: return String(localized: "En service")
            case .pending: return String(localized: "En attente")
            case .planned: return String(localized: "Prévue")
            }
        }
    }

    private func techState(_ tech: String) -> TechState {
        let active = site.activation?.activeTechnologies ?? []
        let confirmed = site.activation?.confirmedTechnologies ?? []
        let pending = site.activation?.pendingTechnologies ?? []
        if active.contains(tech) || confirmed.contains(tech) { return .inService }
        if pending.contains(tech) { return .pending }
        return .planned
    }

    private var statusLabel: String {
        switch status {
        case .active: return String(localized: "Site actif")
        case .upgradePending: return String(localized: "Upgrade en attente")
        case .declared: return String(localized: "Station déclarée")
        case .planned: return String(localized: "Site prévu")
        }
    }

    // Même source de vérité que la pastille sur la carte → fiche et marqueur
    // affichent toujours la même couleur de statut (déclaré = bleu, pas gris).
    private var statusColor: Color { MapExplorerView.plannedStatusColor(status) }
    /// La même lecture en version encre, pour le texte et les pictogrammes.
    private var statusInk: Color { MapExplorerView.plannedStatusInk(status) }

    private var statusGlyph: String {
        switch status {
        case .active: return "checkmark.seal.fill"
        case .upgradePending: return "arrow.up.circle.fill"
        case .declared: return "doc.text.fill"
        case .planned: return "clock.fill"
        }
    }

    private var statusDescription: String {
        let pending = site.activation?.pendingTechnologies ?? []
        switch status {
        case .active:
            return String(localized: "Site en service — toutes les technologies prévues émettent.")
        case .upgradePending:
            return pending.isEmpty
                ? String(localized: "Site en service, mise à niveau en cours.")
                : String(localized: "Site en service ; reste à activer : \(pending.formatted(.list(type: .and))).")
        case .declared:
            return String(localized: "Station enregistrée à l'ANFR, pas encore d'émetteur actif.")
        case .planned:
            return String(localized: "Site annoncé au prévisionnel, pas encore construit.")
        }
    }

    private func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = Locale.autoupdatingCurrent
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: date)
    }
}
