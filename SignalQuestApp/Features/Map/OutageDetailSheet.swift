import SwiftUI
import MapKit

/// Sheet détaillée d'un site en panne / maintenance : type d'incident, raison
/// lisible, services impactés (voix/data par génération), dates de début et de
/// rétablissement prévu, localisation.
struct OutageDetailSheet: View {
    let site: OutageSiteLive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSheetHandle()
                header
                if !site.services.isEmpty { servicesSection }
                infoSection
            }
            .padding()
        }
        .presentationDetents([.height(440), .medium, .large])
        .presentationBackgroundCompat(SQColor.bg)
    }

    var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: issueGlyph)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(issueColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(site.commune?.capitalized ?? site.siteId ?? "Site en panne")
                    .font(SQFont.display(20, .bold, relativeTo: .title3))
                    .foregroundStyle(SQColor.label)
                Text(issueLabel)
                    .font(SQFont.body(14.5, .semibold, relativeTo: .callout))
                    .foregroundStyle(issueColor)
                if let op = site.operator {
                    Text(op)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
        }
    }

    var servicesSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Services impactés")
                .font(SQFont.body(12.5, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(site.services, id: \.label) { service in
                    HStack(spacing: 6) {
                        Circle().fill(serviceColor(service.status)).frame(width: 8, height: 8)
                        Text(service.label)
                            .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(SQColor.label)
                        Spacer(minLength: 0)
                        Text(serviceStatusLabel(service.status))
                            .font(SQFont.body(11, .bold, relativeTo: .caption2))
                            .foregroundStyle(serviceColor(service.status))
                    }
                    .padding(.horizontal, SQSpace.sm + 2)
                    .padding(.vertical, 7)
                    .background(serviceColor(service.status).opacity(0.12), in: Capsule(style: .continuous))
                }
            }
        }
    }

    var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Raison", reasonText)
            infoRow("Début", formattedDate(site.startedAt))
            infoRow("Rétablissement prévu", formattedDate(site.estimatedEnd) ?? "Non communiqué")
            infoRow("Commune", site.commune?.capitalized)
            infoRow("Département", site.departement)
            infoRow("Site", site.siteId)
        }
        .padding(.vertical, SQSpace.xs)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    @ViewBuilder
    func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text(value)
                    .font(SQFont.body(13.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            Divider().padding(.leading, SQSpace.md)
        }
    }

    // MARK: Présentation

    var issueKey: String { (site.issueType ?? "").lowercased() }

    var issueLabel: String {
        switch issueKey {
        case "maintenance": return String(localized: "Maintenance programmée")
        case "degraded": return String(localized: "Service dégradé")
        default: return "Panne / hors service"
        }
    }

    var issueColor: Color {
        switch issueKey {
        case "maintenance": return Color(hex: 0xF97316)
        case "degraded": return Color(hex: 0xEAB308)
        default: return Color(hex: 0xEF4444)
        }
    }

    var issueGlyph: String {
        switch issueKey {
        case "maintenance": return "wrench.and.screwdriver.fill"
        case "degraded": return "exclamationmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    /// Code opérateur brut → libellé lisible (au lieu d'« INT » / « MAINT »).
    var reasonText: String {
        switch (site.reason ?? "").uppercased() {
        case "INT": return "Interruption de service"
        case "MAINT": return String(localized: "Maintenance programmée")
        case "": return site.detail ?? issueLabel
        default: return site.detail ?? (site.reason ?? issueLabel)
        }
    }

    func serviceStatusLabel(_ status: String) -> String {
        switch status.uppercased() {
        case "HS": return "Hors service"
        case "DE": return String(localized: "Dégradé")
        case "OK": return "OK"
        default: return status
        }
    }

    func serviceColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "HS": return Color(hex: 0xEF4444)
        case "DE": return Color(hex: 0xF59E0B)
        case "OK": return Color(hex: 0x10B981)
        default: return SQColor.labelSecondary
        }
    }

    /// Parse une date backend (ISO avec/sans fraction, ou « jour seul ») et la
    /// formate en français lisible.
    func formattedDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let date: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) {
            date = d
        } else {
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: raw) {
                date = d
            } else {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 0)
                f.dateFormat = "yyyy-MM-dd"
                date = f.date(from: raw)
            }
        }
        guard let date else { return raw }
        let out = DateFormatter()
        out.locale = Locale(identifier: "fr_FR")
        out.dateStyle = .medium
        out.timeStyle = raw.contains("T") ? .short : .none
        return out.string(from: date)
    }
}
