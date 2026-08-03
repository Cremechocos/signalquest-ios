import Foundation

/// Restreint la couche couverture aux mesures d'UN site.
///
/// La couverture communautaire est un nuage de mesures : à l'échelle d'une
/// ville, impossible de savoir lesquelles viennent du pylône qu'on regarde.
/// Le rattachement se fait par identité radio — l'eNB et le gNB relevés sur
/// place — pas par proximité, qui confondrait deux sites d'une même rue.
struct AntennaCoverageFocus: Equatable, Identifiable, Sendable {
    /// Nom affiché dans le bandeau « couverture isolée ».
    let siteLabel: String
    /// Opérateur retenu : la couche couverture en exige toujours un.
    let operatorKey: String
    let enb: String?
    let gnb: String?

    var id: String { "\(operatorKey)|\(enb ?? "-")|\(gnb ?? "-")" }

    /// Un site 5G NSA porte les deux identifiants et ses mesures se répartissent
    /// entre eux : le backend les croise en OU.
    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let enb, !enb.isEmpty { items.append(URLQueryItem(name: "enb", value: enb)) }
        if let gnb, !gnb.isEmpty { items.append(URLQueryItem(name: "gnb", value: gnb)) }
        return items
    }

    /// Sans identifiant, le filtre ne restreindrait rien et la carte afficherait
    /// toute la couverture de l'opérateur en prétendant montrer ce site.
    var isUsable: Bool { !queryItems.isEmpty }

    var summary: String {
        let ids = [enb.map { "eNB \($0)" }, gnb.map { "gNB \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return ids.isEmpty ? siteLabel : "\(siteLabel) — \(ids)"
    }
}
