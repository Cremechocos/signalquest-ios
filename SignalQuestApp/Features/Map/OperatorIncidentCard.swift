import SwiftUI

/// Le bloc « incident déclaré par l'opérateur » de la fiche antenne.
///
/// ⚠️ JAMAIS fondu avec `CommunityOutageCard`, et posé AU-DESSUS de lui : un opérateur qui
/// déclare sa propre panne est une parole de première main, un signalement d'utilisateur est une
/// observation qui attend d'être corroborée. Toute la fonctionnalité tient à ce que l'on sache
/// d'un coup d'œil QUI affirme.
///
/// D'où deux silhouettes délibérément dissemblables :
/// — le communautaire est un aplat TEINTÉ, aux angles doux, avec une jauge qui se remplit ; il a
///   l'air en cours de constitution, parce qu'il l'est ;
/// — celui-ci est une carte OPAQUE barrée d'un liseré plein, sans jauge et sans bouton : il n'y a
///   rien à arbitrer, l'opérateur a parlé.
///
/// La COULEUR, elle, reste celle de la gravité dans les deux blocs : elle répond à « à quel
/// point ? », jamais à « qui ? ». Deux échelles de couleur pour la même question rendraient la
/// carte illisible.
struct OperatorIncidentCard: View {
    let incidents: [SiteOperatorIncident]
    /// Nom d'opérateur tel que le registre du marché l'écrit, résolu par l'appelant — le même
    /// que le marqueur de carte. La clé brute (« BOUYGUES_TELECOM ») donnerait deux graphies
    /// pour un même opérateur d'un écran à l'autre.
    var operatorLabel: (String) -> String

    var body: some View {
        if !incidents.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Déclaré par l'opérateur")
                    .font(SQFont.body(12.5, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(incidents) { incident in
                    row(incident)
                }
            }
        }
    }

    private func row(_ incident: SiteOperatorIncident) -> some View {
        let tint = Self.tint(for: incident.issueType)
        return HStack(alignment: .top, spacing: 0) {
            // Liseré PLEIN, à gauche, sur toute la hauteur : la marque d'une déclaration signée.
            // Le bloc communautaire, lui, baigne dans une teinte diffuse — on distingue les deux
            // avant même d'avoir lu un mot.
            Rectangle()
                .fill(tint)
                .frame(width: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SQSpace.xs + 2) {
                    Image(systemName: Self.glyph(for: incident.issueType))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Self.ink(for: incident.issueType))
                        .accessibilityHidden(true)
                    Text(Self.issueLabel(for: incident.issueType))
                        .font(SQFont.body(13.5, .semibold))
                        .foregroundStyle(SQColor.label)
                    Spacer(minLength: 0)
                }
                Text(operatorLabel(incident.operator))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                // La parole de l'opérateur, telle qu'il l'écrit. Jamais retraduite : « INT » ou
                // « Coupure d'alimentation » sont SA formulation, et la reformuler reviendrait à
                // lui faire dire ce qu'il n'a pas dit.
                if let reason = incident.detail ?? incident.raison, !reason.isEmpty {
                    Text(reason)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let services = servicesLabel(incident) {
                    Text("Touché : \(services)")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let end = incident.expectedEndAt, !end.isEmpty {
                    Text("Rétablissement prévu : \(end)")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                // Le rapprochement est APPROXIMATIF par construction : le code de site d'un
                // opérateur n'est pas le `sup_id` de l'ANFR, donc c'est la distance qui tranche —
                // et sur un toit urbain elle désigne parfois le pylône voisin. Le taire ferait
                // passer une estimation pour une déclaration nominative.
                if incident.isGeoMatch, let meters = incident.matchDistanceMeters {
                    Text("Incident rattaché à ce site par proximité (\(meters) m).")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, SQSpace.sm + 1)
            .padding(.horizontal, SQSpace.md)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SQColor.surface,
            in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// « Internet, Voix » — les mêmes mots que partout, composés par le même helper.
    ///
    /// ⚠️ Aucun SMS : les flux opérateurs n'en publient pas, et le déduire de la voix inventerait
    /// une déclaration que personne n'a faite.
    private func servicesLabel(_ incident: SiteOperatorIncident) -> String? {
        let label = OutageServices.label(
            data: incident.affectsData,
            voice: incident.affectsVoice,
            sms: false
        )
        return label.isEmpty ? nil : label
    }

    // MARK: - Présentation

    /// La gravité, dans la même échelle que le communautaire.
    ///
    /// ⚠️ La maintenance N'A PAS de teinte à elle : elle partage l'ambre du « dégradé »
    /// (`OutageTint.degraded`, #B45309 — exactement la même valeur). C'est cohérent avec la règle
    /// du chantier, la couleur ne répondant qu'à « à quel point ? », et une coupure programmée
    /// n'étant pas plus grave qu'un service dégradé. Ce qui la distingue est ailleurs : la clé à
    /// molette et le libellé « Maintenance programmée », dans cette carte. Le badge de carte, lui,
    /// n'a ni glyphe ni mot : maintenance et dégradé y sont indiscernables. Assumé — le badge
    /// ALERTE, la nature se lit en ouvrant la fiche.
    static func tint(for issueType: String) -> Color {
        switch issueType.lowercased() {
        case "maintenance", "degraded": return OutageTint.degraded
        default: return OutageTint.down
        }
    }

    /// La même lecture en version ENCRE : les teintes ci-dessus sont calibrées comme des aplats
    /// (3:1, WCAG 1.4.11) et ne tiennent pas le 4,5:1 dès qu'elles portent des mots.
    static func ink(for issueType: String) -> Color {
        switch issueType.lowercased() {
        case "degraded", "maintenance": return OutageTint.degradedInk
        default: return OutageTint.downInk
        }
    }

    /// Le TRIANGLE, comme le marqueur d'incident opérateur sur la carte — et jamais le cercle du
    /// signalement communautaire. La forme suit la source d'un écran à l'autre.
    static func glyph(for issueType: String) -> String {
        issueType.lowercased() == "maintenance"
            ? "wrench.and.screwdriver.fill"
            : "exclamationmark.triangle.fill"
    }

    static func issueLabel(for issueType: String) -> String {
        switch issueType.lowercased() {
        case "maintenance": return String(localized: "Maintenance programmée")
        case "degraded": return String(localized: "Service dégradé")
        default: return String(localized: "Site hors service")
        }
    }
}
