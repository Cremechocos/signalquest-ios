import SwiftUI

/// Carte de feed pour `kind = outage` — une panne signalée par la communauté.
///
/// Héro = la gravité, en toutes lettres et en couleur : c'est la seule chose qu'on doit pouvoir
/// lire en faisant défiler. Puis l'opérateur, l'endroit et les codes du site — ce qui permet à un
/// lecteur de reconnaître SON antenne sans ouvrir la carte.
///
/// Tout vient de `metadata` plutôt que de `signal` : une panne n'a pas de mesure radio à montrer,
/// et le résumé radio du serveur n'a pas de champ pour la gravité ni pour l'état.
struct OutageCardView: View {
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    var onReact: ((String) -> Void)? = nil

    // MARK: - Lecture de la metadata

    private func string(_ key: String) -> String? {
        guard case .string(let value)? = item.metadata?[key], !value.isEmpty else { return nil }
        return value
    }

    private func int(_ key: String) -> Int? {
        guard case .number(let value)? = item.metadata?[key] else { return nil }
        return Int(value)
    }

    private func flag(_ key: String) -> Bool {
        guard case .bool(let value)? = item.metadata?[key] else { return false }
        return value
    }

    private var severity: String { string("outageSeverity") ?? "down" }
    private var state: String { string("outageState") ?? "reported" }
    private var isResolved: Bool { state == "resolved" }
    private var operatorConfirmed: Bool { flag("outageOperatorConfirmed") }

    /// Vert dès que c'est rétabli : garder le rouge sur une panne finie ferait paniquer pour rien.
    private var accent: Color {
        if isResolved { return OutageTint.resolved }
        return severity == "degraded" ? OutageTint.degraded : OutageTint.down
    }

    private var headline: String {
        if isResolved { return String(localized: "Réseau rétabli") }
        return severity == "degraded"
            ? String(localized: "Réseau dégradé")
            : String(localized: "Plus de réseau")
    }

    /// L'état, dit du point de vue de qui lit — pas du modèle de données.
    private var stateTag: (label: String, color: Color)? {
        if operatorConfirmed {
            return (String(localized: "Confirmée par l'opérateur"), OutageTint.resolved)
        }
        switch state {
        case "resolved": return (String(localized: "Rétablie"), OutageTint.resolved)
        case "confirmed": return (String(localized: "Confirmée"), accent)
        case "reported": return (String(localized: "À confirmer"), SQColor.labelSecondary)
        default: return nil
        }
    }

    private var place: String? { string("outageAddress") ?? item.placeLabel }

    /// Le code du site.
    ///
    /// Le numéro de site de l'opérateur d'abord quand on l'a — c'est celui que l'opérateur emploie
    /// au téléphone —, sinon le code ANFR. JAMAIS l'un sous l'étiquette de l'autre.
    private var siteCode: (label: String, value: String)? {
        if let operatorSiteId = string("outageOperatorSiteId") {
            return (String(localized: "Code opérateur"), operatorSiteId)
        }
        if let anfr = string("outageAnfrCode") {
            return (String(localized: "Code ANFR"), anfr)
        }
        if let siteId = string("siteId") {
            return (String(localized: "Site"), siteId)
        }
        return nil
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                CardHeader(
                    author: item.author,
                    place: place,
                    createdAt: item.createdAt,
                    kindBadge: String(localized: "Panne"),
                    kindColor: accent,
                    onAuthorTap: onAuthorTap
                )

                hero

                LazyVGrid(columns: gridColumns, spacing: SQSpace.sm) {
                    CardMetricTile(
                        label: String(localized: "Opérateur"),
                        value: string("operator") ?? string("operatorKey") ?? "—",
                        highlight: true,
                        accent: accent
                    )
                    if let siteCode {
                        CardMetricTile(label: siteCode.label, value: siteCode.value)
                    }
                    CardMetricTile(
                        label: String(localized: "Touché"),
                        value: string("outageServices") ?? "—"
                    )
                }

                if let footer {
                    Text(footer)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                }

                CardActionsBar(
                    item: item,
                    onLike: onLike,
                    onRepost: onRepost,
                    onComment: onComment,
                    onFavorite: onFavorite,
                    onShare: onShare,
                    onReact: onReact
                )
            }
            .padding(SQSpace.lg)
            .sqEditorialCard()
        }
        .buttonStyle(SQPressButtonStyle())
    }

    /// Héro : la gravité, lisible d'un coup d'œil dans le défilement.
    private var hero: some View {
        HStack(alignment: .center, spacing: SQSpace.md) {
            Image(systemName: isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(headline)
                .font(SQFont.display(19, .bold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if let stateTag {
                SQEditorialTag(text: stateTag.label, color: stateTag.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 3)
    }

    /// Ce que l'opérateur en dit, quand il en dit quelque chose — sinon le décompte communautaire.
    private var footer: String? {
        if let raison = string("outageOperatorRaison") { return raison }
        guard let count = int("outageConfirmCount"), count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 personne a constaté la panne.")
            : String(localized: "\(count) personnes ont constaté la panne.")
    }
}
