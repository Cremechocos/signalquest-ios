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
    // Voir `OutageFeedBadge` en bas de fichier pour l'étiquette de genre et ses couleurs.
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    var onReact: ((String) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    private var accent: Color { OutageFeedBadge.tint(severity: severity, state: state) }

    /// La même gravité en version LISIBLE. Les trois teintes de `OutageTint` sont calibrées comme
    /// des APLATS (marqueur, pastille) où WCAG 1.4.11 ne demande que 3:1 ; posées en TEXTE sur la
    /// surface de carte, elles tombent sous le 4,5:1 de WCAG 1.4.3 — et le rouge y échoue dans les
    /// deux apparences. Même règle que la feuille de panne et la carte de la fiche antenne.
    private var ink: Color { OutageFeedBadge.ink(severity: severity, state: state) }

    private var headline: String {
        if isResolved { return String(localized: "Réseau rétabli") }
        return severity == "degraded"
            ? String(localized: "Réseau dégradé")
            : String(localized: "Plus de réseau")
    }

    /// L'état, dit du point de vue de qui lit — pas du modèle de données.
    private var stateTag: (label: String, color: Color)? {
        if operatorConfirmed {
            return (String(localized: "Confirmée par l'opérateur"), OutageTint.resolvedInk)
        }
        switch state {
        case "resolved": return (String(localized: "Rétablie"), OutageTint.resolvedInk)
        case "confirmed": return (String(localized: "Confirmée"), ink)
        case "reported": return (String(localized: "À confirmer"), SQColor.labelSecondary)
        default: return nil
        }
    }

    private var place: String? { string("outageAddress") ?? item.readablePlaceLabel }

    /// Les services touchés, composés ICI à partir des trois drapeaux de la metadata.
    ///
    /// `outageServices` est une phrase RÉDIGÉE PAR LE SERVEUR, en français : affichée telle quelle,
    /// elle laissait « Internet, Voix » au milieu d'une carte anglaise. Elle ne sert plus que de
    /// repli, pour les posts écrits avant que le serveur n'expose `outageAffects*` — leur metadata
    /// est figée en base, ces posts-là ne repasseront jamais par la nouvelle composition.
    private var affectedServices: String {
        let label = OutageServices.label(
            data: flag("outageAffectsData"),
            voice: flag("outageAffectsVoice"),
            sms: flag("outageAffectsSms")
        )
        if !label.isEmpty { return label }
        // Vide, et pas « — » : sans drapeau ni phrase, la carte n'affiche aucune ligne de services.
        return string("outageServices") ?? ""
    }

    /// Les précisions du constat : bandes puis secteurs, telles que la personne les a désignées.
    ///
    /// Vide sur une panne totale — « plus rien » veut dire toutes les fréquences, la question n'est
    /// pas posée — et vide sur les pannes ouvertes avant ce champ, dont la metadata est figée en
    /// base. La carte se contracte alors d'elle-même, sans rangée vide.
    ///
    /// Mêmes jetons, même ordre et même écriture que la carte Android : la même panne doit se lire
    /// pareil d'un téléphone à l'autre.
    private var precisions: [String] {
        var out: [String] = []
        // En capitales, sans traduction : « N78 » s'écrit pareil dans les cinq langues de l'app, et
        // un jeton que cette version ne connaît pas s'affiche tel quel plutôt que de disparaître.
        out += (string("outageBands") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        // Le DEGRÉ, jamais un numéro de secteur : celui-ci dépend de l'opérateur (SFR compte à
        // partir de 0, les trois autres à partir de 1), et l'afficher ici finirait par le faire
        // ressaisir — faux pour un opérateur sur quatre.
        out += (string("outageSectors") ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map { "\($0)°" }
        return out
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: place,
                    createdAt: item.createdAt,
                    // L'état est dans le bandeau : une étiquette en plus le répétait.
                    kindBadge: nil,
                    kindColor: ink,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                hero

                // L'opérateur et les générations touchées, puis ce qui ne marche plus
                // (refonte du 04/11) : plus de tuiles « Opérateur » et « Touché ».
                FeedNetworkLine(operator: operatorName, technologies: outageTechnologies)

                serviceChips

                // Les précisions sous la grille, et non dans une quatrième tuile : la grille en
                // compte trois par rangée, et une quatrième tuile facultative repartirait sur une
                // rangée à elle avec deux vides à sa droite — creusant un trou à chaque panne
                // totale, où la question n'est même pas posée.
                if !precisions.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 52), spacing: SQSpace.xs2)],
                        alignment: .leading,
                        spacing: SQSpace.xs2
                    ) {
                        ForEach(precisions, id: \.self) { token in
                            Text(token)
                                .font(SQType.caption.weight(.semibold))
                                .foregroundStyle(ink)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, SQSpace.sm + 1)
                                .padding(.vertical, SQSpace.xs + 1)
                                // Un CONTOUR teinté, jamais un aplat : l'aplat est réservé à
                                // l'état de la panne, dans le héros. Deux aplats de la même
                                // couleur mettraient sur le même plan le constat et son détail.
                                .overlay(
                                    RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous)
                                        .stroke(ink.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                }

                if let footer {
                    Text(footer)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Le constat se fait depuis Android ; iOS lit la panne.
                FeedOpenCapsule(
                    title: String(localized: "Voir la panne"),
                    destination: .link(.outage(id: string("outageId"), siteId: OutageFeedBadge.fallbackSiteId(string("siteId"), targetKind: string("outageTargetKind")),
                                               market: string("marketCode"))),
                    onOpenPost: onTap
                )

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
    ///
    /// ── Le MOUVEMENT, et pourquoi il est là ──
    ///
    /// Trois moments seulement, et aucun régime permanent : une pastille qui pulse coûterait de la
    /// batterie et suggérerait une mesure en cours là où il n'y en a pas.
    ///
    /// 1. L'APPARITION de la carte dans le fil est déjà portée par `sqFadeUp()`, posé une fois sur
    ///    chaque rangée (`FeedView.feedCard`). Le redoubler ici ferait deux entrées superposées.
    /// 2. Le FRANCHISSEMENT DU SEUIL : le serveur met à jour la metadata du post quand la panne
    ///    passe à `confirmed`, donc `state` change entre deux chargements sur une carte dont
    ///    l'identité, elle, ne bouge pas (`ForEach(model.page.items)`, clé = id du post). Le fondu
    ///    des couleurs et le pop de la pastille marquent ce basculement.
    /// 3. Le PASSAGE EN RÉTABLI : même chemin, plus le pop du pictogramme qui devient une coche.
    ///
    /// `sqLikePop` et `sqAnimation` sont le vocabulaire déjà en place dans le fil : ce sont
    /// exactement les modificateurs que portent le cœur et le signet de CHAQUE carte
    /// (`CardActionsBar`), déclenchés sur un changement de valeur, et tous deux s'effacent sous
    /// Reduce Motion (`SQReduceMotionAnimation`, et le `reduce` de `SQLikePopModifier`).
    private var hero: some View {
        // En grande taille de texte, titre et état passent l'un sous l'autre : côte à côte,
        // ils se coupaient en « Plus de r… » et « À confir… » (revue q34, constat 10).
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.sm))
            : AnyLayout(HStackLayout(alignment: .center, spacing: SQSpace.md))
        return layout {
            Image(systemName: isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 36, height: 36)
                .background(SQColor.surface, in: Circle())
                // Moment 3 : la coche ARRIVE. Le pictogramme et sa pastille changent ensemble.
                .sqLikePop(trigger: isResolved)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(SQFont.display(17, .bold, relativeTo: .headline))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let since = bannerDetail {
                    Text(verbatim: since)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !stacked { Spacer(minLength: 0) }
            if let stateTag {
                SQEditorialTag(text: stateTag.label, color: stateTag.color)
                    // Moment 2 : le mot de l'état vient de changer (« À confirmer » → « Confirmée »,
                    // puis « Rétablie »). Déclencheur = le LIBELLÉ, donc rien ne bouge quand seul
                    // le décompte de confirmations avance sans franchir le seuil.
                    .sqLikePop(trigger: stateTag.label)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Le bandeau porte la teinte de l'état : danger, ambre, ou olive une fois rétabli.
        .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        // Fondu de tout ce qui change d'un état à l'autre : la teinte de la pastille, l'encre du
        // pictogramme, le mot de l'étiquette. Déclencheur = `state`, dont dérivent les trois.
        .sqAnimation(SQMotion.smooth, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.outage.banner")
    }

    /// « Depuis le 1 nov., 11:00 · 1 confirmation ».
    private var bannerDetail: String? {
        var parts: [String] = []
        if let started = string("outageStartedAt").flatMap(Self.parseDate) {
            parts.append(String(localized: "depuis \(started.sqFormatted(date: .medium))"))
        }
        if let count = int("outageConfirmCount"), count > 0 {
            parts.append(String(localized: "\(count) confirmations"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Jetons de génération de la metadata (« 4G,5G ») pour la ligne réseau.
    private var outageTechnologies: [String] {
        (string("outageTechnologies") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Internet, appels et SMS : coupé (ou perturbé) contre « OK ». Seulement sur une
    /// panne en cours dont le serveur donne les trois drapeaux ; sinon la phrase de repli.
    @ViewBuilder
    private var serviceChips: some View {
        let flags = [("outageAffectsData", "antenna.radiowaves.left.and.right", String(localized: "Internet")),
                     ("outageAffectsVoice", "phone", String(localized: "Appels")),
                     ("outageAffectsSms", "message", String(localized: "SMS"))]
        let hasFlags = flags.contains { item.metadata?[$0.0] != nil }
        if isResolved {
            EmptyView()
        } else if hasFlags {
            FlowRow(spacing: SQSpace.xs2) {
                ForEach(flags, id: \.0) { key, symbol, name in
                    let hit = flag(key)
                    Label {
                        Text(verbatim: hit
                            ? (severity == "degraded" ? String(localized: "\(name) perturbé") : String(localized: "\(name) coupé"))
                            : String(localized: "\(name) OK"))
                    } icon: {
                        Image(systemName: symbol).accessibilityHidden(true)
                    }
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(hit ? ink : SQColor.labelSecondary)
                    .padding(.horizontal, SQSpace.sm2)
                    .padding(.vertical, SQSpace.xs + 1)
                    .background(hit ? accent.opacity(0.13) : SQColor.surfaceMuted, in: Capsule(style: .continuous))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("feed.outage.services")
        } else if !affectedServices.isEmpty {
            Text(verbatim: affectedServices)
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private var operatorName: String? {
        guard let raw = string("operator") ?? string("operatorKey") else { return nil }
        return SQBrand.operatorName(raw) ?? raw
    }

    /// Ce que l'opérateur en dit, quand il en dit quelque chose — sinon le décompte communautaire.
    private var footer: String? {
        // Le décompte des constats est dans le bandeau.
        string("outageOperatorRaison")
    }
}

/// L'étiquette de GENRE d'une carte de fil « panne » : le mot, et ses deux couleurs.
///
/// Elle disait « Panne », en rouge, sur une carte dont le titre annonçait « Réseau dégradé » — et
/// pire, sur une panne rétablie. Une étiquette qui contredit le contenu qu'elle coiffe abîme la
/// confiance dans les deux. Le serveur envoie déjà `outageSeverity` et `outageState` dans la
/// metadata du post, et les met à jour quand la panne évolue : il n'y a rien à aller chercher.
///
/// Sortie de la vue pour être vérifiable — c'est une règle produit tranchée explicitement, et la
/// même sur les trois plateformes.
enum OutageFeedBadge {
    /// Repli vers la fiche quand la panne n'a pas d'id : `siteId` n'est un site que pour une cible
    /// `anfr`, `custom` ou `community` ; en `geo` c'est une clé de position (contrat des posts
    /// automatiques v1 §2.9). Clé absente (anciens posts, tous `anfr`) : repli inchangé.
    static func fallbackSiteId(_ siteId: String?, targetKind: String?) -> String? {
        guard let targetKind else { return siteId }
        return ["anfr", "custom", "community"].contains(targetKind.lowercased()) ? siteId : nil
    }

    /// `severity` et `state` BRUTS, tels que la metadata du post les porte. Les deux
    /// initialiseurs tolérants font le reste : une valeur inconnue retombe sur `down` / `reported`,
    /// donc sur « Panne », qui est la bonne moitié de l'erreur à commettre.
    static func label(severity: String?, state: String?) -> String {
        if isResolved(state) { return String(localized: "Rétabli") }
        return OutageSeverity(rawServerValue: severity) == .degraded
            ? String(localized: "Dégradé")
            : String(localized: "Panne")
    }

    /// L'aplat : pastille du pictogramme, teintes de la couche carte.
    static func tint(severity: String?, state: String?) -> Color {
        isResolved(state) ? OutageTint.resolved : OutageTint.of(OutageSeverity(rawServerValue: severity))
    }

    /// L'encre : partout où la couleur porte des MOTS (l'étiquette, le pictogramme, la valeur
    /// mise en avant). Les aplats n'y tiennent pas le 4,5:1 de WCAG 1.4.3.
    static func ink(severity: String?, state: String?) -> Color {
        isResolved(state) ? OutageTint.resolvedInk : OutageTint.inkOf(OutageSeverity(rawServerValue: severity))
    }

    private static func isResolved(_ state: String?) -> Bool {
        OutageState(rawServerValue: state) == .resolved
    }
}
