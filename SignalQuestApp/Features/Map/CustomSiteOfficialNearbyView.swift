import SwiftUI

/// OFFICIAL-NEARBY r1 : « Ton antenne est peut-être déjà là ». Avant de créer un site en Belgique
/// ou en Suisse, les positions officielles du même opérateur à 300 m ou moins : le registre ne
/// donne pas les eNB, la position du nœud y est peut-être déjà. Android y propose « Identifier
/// celle-ci », qui ouvre l'identification sur la carte ; iOS n'a pas cette identification pour une
/// cellule observée, la feuille informe donc et ouvre la position (choix d'Alexandre, 13/11).
struct CustomSiteOfficialNearbyView: View {
    let sites: [OfficialNearbySite]
    let radio: CustomSiteRadioSnapshot?
    let operatorLabel: (String) -> String
    /// « Voir cette position » ; nil = pas de bouton (l'hôte ne sait pas ouvrir une fiche).
    var onViewPosition: ((OfficialNearbySite) -> Void)? = nil
    let onCreate: () -> Void
    var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Image(systemName: "mappin.and.ellipse")
                    .font(SQFont.body(18, .semibold, relativeTo: .title3))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: String(localized: "Ton antenne est peut-être déjà là"))
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
            }
            Text(verbatim: bodyText)
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: SQSpace.sm) {
                ForEach(sites) { site in row(site) }
            }
            Text(verbatim: String(localized: "Une position peut porter plusieurs eNB du même opérateur : un eNB déjà posé n’exclut pas le tien."))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Aucune ne convient, créer le site"), isBusy: isBusy, style: .secondary,
                           allowsMultiline: true, action: onCreate)
                .disabled(isBusy)
                .accessibilityIdentifier("createSite.officialNearby.create")
        }
    }

    private var bodyText: String {
        let registry = sites.first?.market == "CH"
            ? String(localized: "Le registre suisse ne donne pas les eNB.")
            : String(localized: "Le registre belge ne donne pas les eNB.")
        let advice: String
        if let node = radio?.nodeLabel {
            advice = String(localized: "Si le nœud \(node) est sur l’une de ces positions, c’est la même antenne : inutile de créer un doublon.")
        } else {
            advice = String(localized: "Si ton antenne est l’une de ces positions, inutile de créer un doublon.")
        }
        return "\(registry) \(advice)"
    }

    /// « Proximus · Bruxelles Environnement », puis « à 120 m · Aucun eNB posé ».
    private func row(_ site: OfficialNearbySite) -> some View {
        let title = [operatorLabel(site.operatorKey), site.registryName].joined(separator: " · ")
        let distance = String(localized: "à \(SQUnits.distance(meters: site.distanceMeters))")
        let enb = site.enbCount == 0
            ? String(localized: "Aucun eNB posé")
            : String(localized: "\(site.enbCount) eNB posés")
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(verbatim: title)
                    .font(SQType.rowTitle)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "\(distance) · \(enb)")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let onViewPosition {
                Button { onViewPosition(site) } label: {
                    Label(String(localized: "Voir cette position"), systemImage: "arrow.up.right")
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("createSite.officialNearby.view")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SQSpace.md)
        .padding(.top, SQSpace.md)
        .padding(.bottom, onViewPosition == nil ? SQSpace.md : SQSpace.xxs)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }
}

extension OfficialNearbySite {
    /// Le registre qui publie la position : son nom propre, traduit seulement là où il l'est.
    var registryName: String {
        switch region {
        case .flanders: "Omgeving Vlaanderen"
        case .brussels: String(localized: "Bruxelles Environnement")
        case .switzerland: "OFCOM"
        }
    }
}
