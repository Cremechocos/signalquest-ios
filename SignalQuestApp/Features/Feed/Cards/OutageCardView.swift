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

    private var kindBadge: String { OutageFeedBadge.label(severity: severity, state: state) }

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

    private var place: String? { string("outageAddress") ?? item.placeLabel }

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
        // Vide, et pas « — » : c'est `affected` qui décide du repli, une fois les générations
        // ajoutées. Un tiret posé ici ferait lire « — · 4G » sur une panne dont on connaît la
        // génération mais pas les services.
        return string("outageServices") ?? ""
    }

    /// « Internet, Voix · 4G, 5G » — services ET générations sur UNE ligne, dans UNE tuile.
    ///
    /// Le serveur joint les jetons de génération par une virgule dans la metadata : un tableau y
    /// aurait disparu en silence, `inputJsonRecord` ne gardant que les scalaires. Clé absente sur
    /// les pannes ouvertes avant ce champ, et sur celles où personne n'a su répondre — la ligne se
    /// réduit alors aux services, sans séparateur orphelin ni « inconnu ».
    ///
    /// Une seule tuile et non deux : la grille en compte trois par rangée, et une quatrième
    /// « Technologies » repartait sur une rangée à elle avec deux vides à sa droite. C'est aussi
    /// la même ligne, au caractère près, que la fiche antenne, la feuille de panne et la page
    /// « Pannes signalées » — la même panne doit se lire pareil partout.
    private var affected: String {
        let line = OutageTechnologies.detail(
            services: affectedServices,
            csv: string("outageTechnologies")
        )
        return line.isEmpty ? "—" : line
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
                    kindBadge: kindBadge,
                    kindColor: ink,
                    onAuthorTap: onAuthorTap
                )

                hero

                LazyVGrid(columns: gridColumns, spacing: SQSpace.sm) {
                    CardMetricTile(
                        label: String(localized: "Opérateur"),
                        value: string("operator") ?? string("operatorKey") ?? "—",
                        highlight: true,
                        accent: ink
                    )
                    if let siteCode {
                        CardMetricTile(label: siteCode.label, value: siteCode.value)
                    }
                    // Le point médian sépare deux listes INDÉPENDANTES : « Internet, Voix » d'un
                    // côté, « 4G, 5G » de l'autre. Il ne dit pas « Internet en 4G » — le
                    // formulaire ne demande pas les paires, et les afficher comme telles
                    // affirmerait un croisement que personne n'a déclaré.
                    // TROIS lignes, et non deux : mesuré par rendu de la tuile réelle (390 pt de
                    // large, grille à 3 colonnes). À la taille de texte par défaut, deux suffisent
                    // et la troisième ne change rien — « Internet, / Voix · 4G, 5G ». Au premier
                    // cran d'accessibilité (`dynamicTypeSize .accessibility1`), la limite à deux
                    // coupait la ligne à « Voix · 4G,… » : les générations, qui sont l'information
                    // ajoutée ici, disparaissaient précisément chez les gens qui grossissent le
                    // texte. Avec trois, elle se pose entière sur « Internet, / Voix · / 4G, 5G ».
                    CardMetricTile(
                        label: String(localized: "Touché"),
                        value: affected,
                        valueLineLimit: 3
                    )
                }

                // Les précisions sous la grille, et non dans une quatrième tuile : la grille en
                // compte trois par rangée, et une quatrième tuile facultative repartirait sur une
                // rangée à elle avec deux vides à sa droite — creusant un trou à chaque panne
                // totale, où la question n'est même pas posée.
                if !precisions.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 52), spacing: SQSpace.xs + 2)],
                        alignment: .leading,
                        spacing: SQSpace.xs + 2
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
        HStack(alignment: .center, spacing: SQSpace.md) {
            Image(systemName: isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.13), in: Circle())
                // Moment 3 : la coche ARRIVE. Le pictogramme et sa pastille changent ensemble.
                .sqLikePop(trigger: isResolved)
                .accessibilityHidden(true)
            Text(headline)
                .font(SQFont.display(19, .bold))
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let stateTag {
                SQEditorialTag(text: stateTag.label, color: stateTag.color)
                    // Moment 2 : le mot de l'état vient de changer (« À confirmer » → « Confirmée »,
                    // puis « Rétablie »). Déclencheur = le LIBELLÉ, donc rien ne bouge quand seul
                    // le décompte de confirmations avance sans franchir le seuil.
                    .sqLikePop(trigger: stateTag.label)
            }
        }
        // Fondu de tout ce qui change d'un état à l'autre : la teinte de la pastille, l'encre du
        // pictogramme, le mot de l'étiquette. Déclencheur = `state`, dont dérivent les trois.
        .sqAnimation(SQMotion.smooth, value: state)
        .accessibilityElement(children: .combine)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3)
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
