import SwiftUI

/// Fiche détaillée d'un site prévisionnel : statut d'activation (croisé ANFR),
/// technologies prévues vs en service, et métadonnées (code site, commune, dates).
/// Même squelette que `OutageDetailSheet` pour une cohérence visuelle.
struct PlannedDetailSheet: View {
    let site: PlannedSiteLive
    let operatorLabel: String
    let operatorAccent: Color

    private var status: PlannedActivationStatus { site.activation?.status ?? .planned }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSheetHandle()
                header
                statusBanner
                if !plannedTechs.isEmpty { technologiesSection }
                infoSection
            }
            .padding()
        }
        .presentationDetents([.height(460), .medium, .large])
        .presentationBackgroundCompat(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(operatorAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(site.codeSite ?? site.idStation ?? "Site prévisionnel")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(SQColor.label)
                Text(statusLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor)
                Text(operatorLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer()
        }
    }

    private var statusBanner: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: statusGlyph)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(statusColor)
            Text(statusDescription)
                .font(.subheadline)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var technologiesSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Technologies prévues")
                .font(SQFont.archivo(12, .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(plannedTechs, id: \.self) { tech in
                    Text(tech)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(techColor(tech))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(techColor(tech).opacity(0.14), in: Capsule())
                }
            }
            HStack(spacing: SQSpace.md) {
                legendDot(Color(hex: 0x16A34A), "En service")
                legendDot(Color(hex: 0xF59E0B), "En attente")
                legendDot(SQColor.labelSecondary, "Prévue")
            }
            .font(.caption2)
            .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
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
            infoRow("Distance antenne", site.activation?.distanceM.map { "\(Int($0)) m" })
            infoRow("Mise en service", formattedDate(site.activation?.lastInServiceDate))
        }
        .padding(.vertical, SQSpace.xs)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            Divider().padding(.leading, SQSpace.md)
        }
    }

    // MARK: Statut

    private var plannedTechs: [String] {
        let planned = site.activation?.plannedTechnologies ?? []
        return planned.isEmpty ? site.technologies : planned
    }

    private func techColor(_ tech: String) -> Color {
        let active = site.activation?.activeTechnologies ?? []
        let confirmed = site.activation?.confirmedTechnologies ?? []
        let pending = site.activation?.pendingTechnologies ?? []
        if active.contains(tech) || confirmed.contains(tech) { return Color(hex: 0x16A34A) }
        if pending.contains(tech) { return Color(hex: 0xF59E0B) }
        return SQColor.labelSecondary
    }

    private var statusLabel: String {
        switch status {
        case .active: return "Site actif"
        case .upgradePending: return "Upgrade en attente"
        case .declared: return "Station déclarée"
        case .planned: return "Site prévu"
        }
    }

    private var statusColor: Color {
        switch status {
        case .active: return Color(hex: 0x16A34A)
        case .upgradePending: return Color(hex: 0xF59E0B)
        case .declared, .planned: return SQColor.labelSecondary
        }
    }

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
            return "Site en service — toutes les technologies prévues émettent."
        case .upgradePending:
            return pending.isEmpty
                ? "Site en service, mise à niveau en cours."
                : "Site en service ; reste à activer : \(pending.joined(separator: ", "))."
        case .declared:
            return "Station enregistrée à l'ANFR, pas encore d'émetteur actif."
        case .planned:
            return "Site annoncé au prévisionnel, pas encore construit."
        }
    }

    private func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "fr_FR")
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: date)
    }
}
