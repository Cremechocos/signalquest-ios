import SwiftUI
import UIKit

/// Couleurs de sévérité, identiques à Android et fixes en clair comme en sombre.
///
/// Sémantiques, donc jamais dérivées du thème : une panne qui changerait de couleur selon
/// l'apparence obligerait à réapprendre le code à chaque bascule. Les mêmes valeurs que la
/// couche carte Android, pour qu'un utilisateur des deux plateformes lise la même chose.
enum OutageTint {
    static let down = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    /// Ambre PROFOND. Le jaune-500 d'avant (#EAB308) tombait à 1,80:1 sur la crème : une pastille
    /// qu'on ne voyait pas, et un texte de gravité illisible. Même valeur qu'Android.
    static let degraded = Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
    static let resolved = Color(red: 0x2E / 255, green: 0x7D / 255, blue: 0x5B / 255)

    static func of(_ severity: OutageSeverity) -> Color {
        severity == .degraded ? degraded : down
    }

    // MARK: Encres

    /// Les encres à poser quand la gravité doit ÉCRIRE, et non seulement signaler.
    ///
    /// Les trois teintes ci-dessus sont calibrées comme des APLATS — marqueur, pastille, jauge —
    /// où WCAG 1.4.11 ne demande que 3:1. Posées en texte sur une surface de carte elles tombent
    /// sous le 4,5:1 que réclame WCAG 1.4.3, et le rouge y échoue dans les deux apparences. Ces
    /// encres les remplacent partout où la couleur porte des mots.
    ///
    /// Dynamiques, et pas une constante choisie au moment de l'appel : la feuille et la liste ne
    /// sont pas ré-instanciées au basculement clair/sombre, une couleur figée y resterait celle de
    /// l'ancien thème. Mêmes valeurs qu'Android (`OutageColors.onLight` / `onDark`).
    static let downInk = ink(light: (0xB3, 0x26, 0x1E), dark: (0xE0, 0x7A, 0x7E))
    static let degradedInk = ink(light: (0x8A, 0x3F, 0x06), dark: (0xE3, 0xB6, 0x5E))
    static let resolvedInk = ink(light: (0x1F, 0x6B, 0x4A), dark: (0x7B, 0xD8, 0x9A))

    static func inkOf(_ severity: OutageSeverity) -> Color {
        severity == .degraded ? degradedInk : downInk
    }

    private static func ink(light: (UInt8, UInt8, UInt8), dark: (UInt8, UInt8, UInt8)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: 1
            )
        })
    }
}

/// L'ARBITRAGE seul : progression vers la confirmation, services touchés, et les deux voix.
///
/// Séparé de `CommunityOutageCard` à dessein, et c'est le correctif du grief n°1 des essais sur
/// appareil : la ligne de liste et la feuille de carte encastraient la carte entière, laquelle
/// réécrivait « Panne signalée » et « Touché : Internet » juste sous l'en-tête qui venait de les
/// dire. Le bloc n'a donc plus d'en-tête d'état — chaque hôte porte le sien, une seule fois.
///
/// Ce qui reste commun est exactement ce qui DOIT l'être : confirmer depuis la fiche antenne,
/// depuis la liste ou depuis la carte est le même geste, avec les mêmes mots et la même égalité
/// visuelle stricte entre les deux réponses.
struct OutageArbitrationBlock: View {
    let outage: CommunityOutage
    /// `nil` = lecture seule (aucun bouton, aucune phrase de position).
    var onVote: ((String, String) -> Void)?

    var body: some View {
        let tint = OutageTint.of(outage.severity)
        VStack(alignment: .leading, spacing: SQSpace.md) {
            OutageConfirmationGauge(outage: outage, tint: tint)
            // Services ET générations sur la même ligne (« Internet, Voix · 4G, 5G »), séparés par
            // le point médian que le serveur emploie déjà dans le texte du post : la même panne se
            // lit pareil ici et dans le fil. Une panne sans technologie déclarée — toutes celles
            // d'avant le champ, et celles où l'on n'a pas su répondre — n'affiche que ses services.
            if !outage.affectedLabel.isEmpty {
                Text("Touché : \(outage.affectedLabel)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            OutageVoteRow(outage: outage, onVote: onVote)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Le décompte vers la confirmation.
///
/// Une jauge SEGMENTÉE et non continue : il manque des gens, pas un pourcentage. On voit combien
/// de crans sont remplis, exactement comme sur Android.
struct OutageConfirmationGauge: View {
    let outage: CommunityOutage
    let tint: Color

    var body: some View {
        let threshold = max(outage.confirmThreshold, 1)
        let filled = min(max(outage.confirmCount, 0), threshold)
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: 5) {
                ForEach(0..<threshold, id: \.self) { index in
                    Capsule()
                        .fill(index < filled ? tint : SQColor.separator)
                        .frame(height: 8)
                }
            }
            // Le mouvement marque un CHANGEMENT, jamais un état : un cran se remplit quand une
            // voix vient d'arriver, et rien ne bouge le reste du temps.
            .sqAnimation(SQMotion.smooth, value: filled)
            Text(progressLabel)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressLabel: String {
        if outage.operatorConfirmed {
            return String(localized: "L'opérateur liste l'incident dans son fichier.")
        }
        if outage.state == .confirmed {
            let n = outage.confirmCount
            let base = n <= 1
                ? String(localized: "1 personne a constaté la panne.")
                : String(localized: "\(n) personnes ont constaté la panne.")
            // L'échelon opérateur n'est mentionné QUE là où il peut exister — les cinq flux lus
            // sont tous français. Ailleurs, l'annoncer ferait attendre une confirmation qui
            // n'arrivera jamais, et transformerait un état complet en état incomplet.
            guard outage.operatorConfirmationPossible else { return base }
            return base + " " + String(localized: "L'opérateur ne l'a pas encore listée.")
        }
        let remaining = outage.confirmationsRemaining
        if remaining <= 0 { return String(localized: "En attente de confirmation.") }
        return remaining == 1
            ? String(localized: "Encore 1 personne et la panne est confirmée.")
            : String(localized: "Encore \(remaining) personnes et la panne est confirmée.")
    }
}

/// Confirmer ou démentir, à poids visuel STRICTEMENT égal.
///
/// Mettre le « oui » en avant orienterait la communauté vers la confirmation — le biais que
/// l'arbitrage est censé écarter. C'est aussi pourquoi les deux boutons n'ont AUCUNE icône : une
/// coche face à une croix rétablit la hiérarchie que les libellés évitent, et la version
/// précédente donnait en prime le vert au démenti, c'est-à-dire la couleur du « tout va bien » à
/// l'une des deux réponses.
struct OutageVoteRow: View {
    let outage: CommunityOutage
    var onVote: ((String, String) -> Void)?

    var body: some View {
        if let onVote {
            if outage.canVote {
                HStack(spacing: SQSpace.sm) {
                    voteButton(
                        title: String(localized: "Oui, c'est HS"),
                        action: { onVote(outage.id, "confirm") }
                    )
                    voteButton(
                        title: String(localized: "Non, ça marche"),
                        action: { onVote(outage.id, "dispute") }
                    )
                }
            } else {
                // Déjà positionné, ou auteur : on le DIT plutôt que d'afficher des boutons inertes.
                Text(myVoteLabel)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    private var myVoteLabel: String {
        switch outage.myVote {
        case "report": return String(localized: "Vous avez signalé cette panne.")
        case "confirm": return String(localized: "Vous avez confirmé cette panne.")
        case "dispute": return String(localized: "Vous avez indiqué que ça marche.")
        case "repaired": return String(localized: "Vous avez signalé le rétablissement.")
        default: return String(localized: "Approchez-vous du site pour vous prononcer.")
        }
    }

    /// UNE fonction pour les deux voix, et c'est la garantie structurelle de leur égalité : même
    /// fonte, même hauteur, même fond, et la MÊME vibration. Confirmer qui vibrerait plus fort que
    /// démentir achèterait des confirmations, et le décompte ne vaudrait plus rien. Deux fonctions
    /// jumelles auraient fini par diverger ; ici c'est impossible sans le voir.
    ///
    /// `selection()` et non `success()` : se prononcer est un choix, pas une réussite — et
    /// « réussite » n'a de sens que pour l'une des deux réponses.
    private func voteButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.selection()
            action()
        }) {
            Text(title)
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.label)
                // 44 pt : le minimum d'Apple, et le geste se fait dehors, à une main.
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    SQColor.fill,
                    in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// « La panne est terminée » — le geste de l'AUTEUR, écrit une fois pour les trois hôtes.
///
/// Bouton PLEIN et pleine largeur, alors que l'arbitrage juste au-dessus s'interdit toute
/// hiérarchie : ce n'est pas un avis parmi deux, c'est l'auteur qui dispose de sa propre
/// contribution. Vert « rétabli » de la palette de gravité — exactement la couleur que prendra le
/// marqueur une fois la panne close.
///
/// Extrait parce qu'un QUATRIÈME chemin mène à une panne : la page « Pannes signalées », la feuille
/// de carte, la notification… et la fiche antenne, seule à ne pas l'offrir. La décision produit
/// n° 12 veut les mêmes actions partout ; trois copies de ce bouton auraient fini par diverger.
///
/// L'appelant garde la CONFIRMATION : le geste est irréversible et collectif, il ne part jamais du
/// premier appui — mais l'alerte doit vivre dans l'hôte, qui seul sait où la présenter.
struct OutageCloseButton: View {
    /// Fermeture en vol, portée par l'hôte : lui seul sait si c'est CETTE panne qui part.
    let closing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SQSpace.sm) {
                Spacer(minLength: 0)
                if closing {
                    ProgressView().tint(.white)
                    Text("Fermeture…")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                    Text("La panne est terminée")
                }
                Spacer(minLength: 0)
            }
            .font(SQFont.body(14, .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(OutageTint.resolved, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(closing)
    }
}

/// Le bloc « panne » de la fiche antenne.
///
/// Deux visages, comme sur Android : rien de signalé → une invitation discrète ; une panne
/// existe → une carte qui prend la place qu'elle mérite. Un bloc de taille constante aurait soit
/// crié dans le vide, soit chuchoté une coupure.
///
/// ⚠️ Conçue pour être SEULE dans son hôte : elle porte son propre en-tête d'état. Une liste ou
/// une feuille qui a déjà écrit cet état doit poser `OutageArbitrationBlock`, pas celle-ci.
struct CommunityOutageCard: View {
    let outages: [CommunityOutage]
    var onReport: (() -> Void)?
    var onVote: ((String, String) -> Void)?
    /// Demande de fermeture par l'auteur. `nil` = l'hôte ne l'offre pas.
    ///
    /// La fiche antenne était le seul des quatre chemins vers une panne à ne pas proposer « La
    /// panne est terminée » — alors que c'est le chemin par lequel on revient vérifier son propre
    /// signalement, une fois sur place. Décision produit n° 12 : les mêmes actions partout.
    var onClose: ((CommunityOutage) -> Void)?
    /// Identifiant de la panne dont la fermeture est en vol, porté par l'hôte.
    var closingOutageId: String?

    /// La panne en cours — il ne peut y en avoir qu'UNE dans cette liste.
    ///
    /// `first` et non une boucle : le serveur garantit l'unicité des pannes ouvertes par
    /// `SiteOutage.openKey`, un index unique valant `marché:opérateur:cible` qu'il pose à
    /// l'ouverture et efface à la fermeture. Deux pannes visibles sur le même site pour le même
    /// opérateur — une `down` et une `degraded` — sont donc impossibles à créer, et les trois
    /// appelants d'ici fournissent tous une liste déjà réduite à un opérateur : la fiche antenne
    /// interroge `selectedOperator` (jamais « ALL », cf. son init), la feuille de panne et la page
    /// « Pannes signalées » passent un tableau d'un seul élément. Rien n'est masqué en silence.
    private var active: CommunityOutage? {
        outages.first { $0.state.isVisible }
    }

    var body: some View {
        if let active {
            outageBody(active)
        } else if onReport != nil {
            reportInvitation
        }
    }

    // MARK: - Panne en cours

    @ViewBuilder
    private func outageBody(_ outage: CommunityOutage) -> some View {
        let tint = OutageTint.of(outage.severity)
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    // L'encre, pas la teinte : le pictogramme est posé sur le conteneur de sa
                    // PROPRE couleur, où la teinte de base tombe à 2,2:1 en apparence sombre —
                    // sous le 3:1 que WCAG 1.4.11 demande à un objet graphique porteur de sens.
                    .foregroundStyle(OutageTint.inkOf(outage.severity))
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateLabel(outage))
                        .font(SQFont.body(13.5, .semibold))
                        .foregroundStyle(SQColor.label)
                    Text(outage.severity == .degraded
                         ? "Service dégradé"
                         : "Plus aucun service")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
            }

            OutageArbitrationBlock(outage: outage, onVote: onVote)

            // `canClose` est arbitré par le serveur — vrai pour le seul auteur d'une panne encore
            // ouverte. Le redéduire ici afficherait un bouton qui rend 403.
            if let onClose, outage.canClose {
                OutageCloseButton(closing: closingOutageId == outage.id) { onClose(outage) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
        )
    }

    /// Chaque phrase de ce bloc passe par `String(localized:)`.
    ///
    /// Ces fonctions rendent un `String`, que la vue affiche par `Text(String)` : cette surcharge
    /// ne consulte JAMAIS le catalogue. Les littéraux laissés nus n'y étaient même pas versés.
    ///
    /// L'échelon opérateur n'est nommé que là où il peut exister : dans les 47 marchés sans flux,
    /// « Panne confirmée » EST le dernier état, et laisser entendre qu'il en manque un ferait
    /// attendre indéfiniment une confirmation qui n'arrivera jamais.
    private func stateLabel(_ outage: CommunityOutage) -> String {
        if outage.operatorConfirmed { return String(localized: "Confirmée par l'opérateur") }
        return outage.state == .confirmed
            ? String(localized: "Panne confirmée")
            : String(localized: "Panne signalée")
    }

    // MARK: - Rien de signalé

    private var reportInvitation: some View {
        Button {
            onReport?()
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(SQColor.labelSecondary)
                Text("Signaler une panne sur cette antenne")
                    .font(SQFont.body(13.5, .medium))
                    .foregroundStyle(SQColor.label)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, SQSpace.md)
            .background(
                SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
