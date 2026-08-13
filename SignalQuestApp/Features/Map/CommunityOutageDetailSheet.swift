import SwiftUI

/// La feuille d'une panne SIGNALÉE PAR LA COMMUNAUTÉ, ouverte depuis son marqueur de carte ou
/// depuis une ligne de « Pannes signalées ».
///
/// Distincte d'`OutageDetailSheet`, qui affiche un incident publié par un opérateur : les deux
/// n'ont ni les mêmes champs (aucune date de rétablissement prévu ici, mais un décompte de
/// confirmations), ni surtout la même autorité. Les fondre ferait perdre la distinction que
/// toute la fonctionnalité cherche à établir — qui affirme quoi.
///
/// Ce que la feuille ajoute au marqueur : l'identité du site, son adresse, depuis quand, qui l'a
/// signalée, et la CHRONOLOGIE. L'état, la progression vers la confirmation et l'arbitrage restent
/// portés par `CommunityOutageCard`, déjà utilisé par la fiche antenne et la page « Pannes
/// signalées ». Les réécrire ici ferait exister trois versions du même geste — et surtout trois
/// occasions de laisser filer l'égalité visuelle stricte entre « Oui, c'est HS » et « Non, ça
/// marche », qui est précisément ce qui empêche l'arbitrage d'orienter la communauté.
struct CommunityOutageDetailSheet: View {
    let service: CommunityOutageServicing
    /// Nom d'opérateur tel que le registre du marché l'écrit — le même que le marqueur de carte.
    /// Résolu par l'appelant, comme `PlannedDetailSheet` : le registre vit dans le modèle de la
    /// carte, et la clé brute (« BOUYGUES_TELECOM ») donnerait deux noms pour une même panne.
    let operatorLabel: String
    /// Appelé quand la panne a changé d'état : la carte doit se recharger, sinon son marqueur
    /// garderait les compteurs d'avant le vote.
    var onChanged: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var services: AppServices

    /// La panne, remplacée par la version que le serveur renvoie après chaque vote. Le serveur
    /// fait autorité sur l'état, le décompte et `canVote` — les recalculer localement finirait
    /// par diverger de sa machine à états.
    @State private var outage: CommunityOutage
    @State private var voting = false
    @State private var errorMessage: String?
    /// Fermeture en vol : le bouton s'y remplace par un indicateur.
    @State private var closing = false
    /// La fermeture attend confirmation. Le geste est irréversible ET collectif : il ne part
    /// jamais du premier appui.
    @State private var confirmingClose = false
    /// Chronologie dépliée. Une panne très confirmée aligne une voix par personne : la feuille
    /// s'ouvre sur les derniers événements, qui sont ceux qu'on vient chercher.
    @State private var timelineExpanded = false
    /// Ouvre le fil de la panne. `nil` quand l'appelant ne sait pas naviguer — le bouton
    /// disparaît alors, plutôt que de mener nulle part.
    var onOpenThread: ((String) -> Void)?

    /// Au-delà, la chronologie se replie. Cinq lignes couvrent la vie d'une panne ordinaire —
    /// signalement, deux ou trois voix, confirmation.
    private static let collapsedTimelineCount = 5

    init(
        outage: CommunityOutage,
        service: CommunityOutageServicing,
        operatorLabel: String,
        onChanged: (() -> Void)? = nil
    ) {
        _outage = State(initialValue: outage)
        self.service = service
        self.operatorLabel = operatorLabel
        self.onChanged = onChanged
    }

    private var tint: Color {
        outage.state.isVisible ? OutageTint.of(outage.severity) : OutageTint.resolved
    }

    /// La même gravité, en version LISIBLE : les teintes de marqueur ne tiennent pas le 4,5:1 de
    /// WCAG 1.4.3 dès qu'elles portent des mots.
    private var ink: Color {
        outage.state.isVisible ? OutageTint.inkOf(outage.severity) : OutageTint.resolvedInk
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSheetHandle()
                header
                if outage.state.isVisible {
                    // L'ARBITRAGE seul : l'en-tête ci-dessus vient d'écrire l'état et la gravité,
                    // et la carte de la fiche antenne les aurait réécrits juste en dessous.
                    OutageArbitrationBlock(
                        outage: outage,
                        onVote: { _, kind in Task { await vote(kind) } }
                    )
                    .disabled(voting)
                } else {
                    closedNotice
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Les MÊMES actions que sur la page « Pannes signalées » : deux chemins vers la
                // même panne doivent offrir les mêmes gestes. L'auteur pouvait refermer la sienne
                // depuis la liste mais pas depuis la feuille ouverte par le marqueur ou par une
                // notification — c'est-à-dire précisément là où il l'apprend.
                if outage.canClose { closeButton }
                // LA CONVERSATION, sous l'arbitrage et nettement séparée de lui : voter demande
                // d'être sur zone et fait bouger l'état de la panne, commenter est ouvert à tous
                // et ne change rien. Le bouton ne se glisse donc pas parmi ceux d'arbitrage.
                if let postId = outage.socialPostId, let onOpenThread {
                    threadButton(postId: postId, action: onOpenThread)
                }
                timelineSection
                infoSection
            }
            .padding()
            // L'arrivée sur l'état de la panne, et son basculement quand un vote la fait changer :
            // deux des trois moments où le mouvement dit quelque chose. Rien ne bouge en régime
            // permanent.
            .sqAnimation(SQMotion.standard, value: outage.state)
        }
        .presentationDetents([.height(440), .medium, .large])
        .presentationBackgroundCompat(SQColor.bg)
        .task { await loadTimeline() }
        // `alert` et non `confirmationDialog`, pour la même raison que la page « Pannes
        // signalées » : les deux issues doivent être NOMMÉES et la phrase de portée rester
        // lisible, ce qu'un dialogue en popover ne garantit pas.
        .alert("Refermer cette panne ?", isPresented: $confirmingClose) {
            Button("Refermer", role: .destructive) { Task { await close() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Elle disparaîtra de la carte pour tout le monde, tout de suite. On ne peut pas revenir en arrière.")
        }
    }

    /// « La panne est terminée » — le composant partagé, pour que le geste soit rigoureusement le
    /// même ici, dans la page « Pannes signalées » et dans la fiche antenne.
    ///
    /// Désactivé aussi pendant un vote : les deux écritures portent sur la même panne, et laisser
    /// partir une fermeture par-dessus une voix en vol ferait revenir la réponse du serveur dans un
    /// ordre imprévisible.
    /// Ouvre le FIL — c'est-à-dire le post que la panne matérialise déjà.
    ///
    /// Un contour, pas un aplat : l'aplat appartient aux gestes qui pèsent sur l'état de la panne.
    private func threadButton(postId: String, action: @escaping (String) -> Void) -> some View {
        Button {
            action(postId)
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text(
                    outage.commentCount > 0
                        ? "Conversation · \(outage.commentCount)"
                        : "Ouvrir la conversation"
                )
                .font(SQType.button)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(SQColor.label)
            .background(
                RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous)
                    .strokeBorder(SQColor.separator, lineWidth: 1.5)
            )
        }
        .buttonStyle(SQPressButtonStyle())
    }

    private var closeButton: some View {
        OutageCloseButton(closing: closing) { confirmingClose = true }
            .disabled(voting)
    }

    // MARK: - Sections

    /// Le site EN TÊTE, avant la gravité : on arrive ici en se demandant « quel endroit ? », la
    /// couleur ayant déjà répondu à « à quel point ? » sur la carte.
    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(ink)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.13), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(siteLabel)
                    .font(SQFont.display(20, .bold, relativeTo: .title3))
                    .foregroundStyle(SQColor.label)
                Text(headline)
                    .font(SQFont.body(14.5, .semibold, relativeTo: .callout))
                    .foregroundStyle(ink)
                // L'adresse juste sous l'état, avant l'opérateur : « quel endroit ? » est la
                // question de l'en-tête, et un nom de site (« Site 3079254 ») n'y répond pas.
                if let address = secondaryAddress {
                    Text(address)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Text(operatorLabel)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Une panne close ouverte depuis une carte pas encore rechargée. Le bloc d'arbitrage ne
    /// connaît que les pannes ouvertes : sans ce texte, la feuille serait muette.
    private var closedNotice: some View {
        Text(closedReason)
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.md)
            .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// La chronologie.
    ///
    /// Absente tant que le serveur ne l'a pas chargée, et c'est une VRAIE distinction : une panne
    /// porte toujours au moins son signalement d'origine, donc un bloc vide signalerait une
    /// anomalie, pas une absence d'événement.
    ///
    /// Le serveur la rend du plus ANCIEN au plus récent ; on l'inverse à l'affichage. Ce qu'on
    /// vient lire sur une panne en cours, c'est ce qui s'est passé en dernier — et c'est aussi ce
    /// qu'un repli à cinq lignes doit garder.
    @ViewBuilder
    private var timelineSection: some View {
        if let timeline = outage.timeline, !timeline.isEmpty {
            let events = Array(timeline.reversed())
            let shown = timelineExpanded ? events : Array(events.prefix(Self.collapsedTimelineCount))
            VStack(alignment: .leading, spacing: SQSpace.md) {
                Text("Chronologie")
                    .font(SQFont.body(12.5, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, entry in
                        timelineRow(entry, isFirst: index == 0, isLast: index == shown.count - 1)
                    }
                }
                if !timelineExpanded, events.count > Self.collapsedTimelineCount {
                    Button("Voir tout") { timelineExpanded = true }
                        .font(SQFont.body(13, .semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
        }
    }

    /// Une ligne d'événement : pastille, filet de liaison, heure relative, phrase.
    ///
    /// Le filet est un rectangle ÉTIRÉ dans la colonne de gauche, pas un séparateur entre deux
    /// rangées : il doit suivre la hauteur du texte, qui passe à deux lignes dès que la phrase
    /// s'allonge. L'espacement inter-rangées est porté par le padding bas de la colonne de droite,
    /// pour que le filet le traverse au lieu de s'y interrompre.
    private func timelineRow(_ entry: OutageTimelineEntry, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isFirst ? ink : SQColor.separator)
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(SQColor.separator)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 9)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if let when = SignalFormatters.date(entry.at, includingTime: true, relative: true) {
                    Text(when)
                        .font(SQFont.body(13, .semibold))
                        .foregroundStyle(SQColor.label)
                }
                Text(phrase(for: entry))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : SQSpace.md)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("Depuis", SignalFormatters.date(outage.startedAt, includingTime: true, relative: true))
            infoRow("Adresse", outage.address)
            infoRow("Signalée par", outage.reporterName)
            infoRow("Opérateur", operatorLabel)
            infoRow("Site", outage.siteName ?? outage.targetId)
            infoRow("Démentis", outage.disputeCount > 0 ? "\(outage.disputeCount)" : nil)
            // Bandes et secteurs : absents d'une panne totale, où la question n'est pas posée —
            // `infoRow` masque donc la ligne d'elle-même. Les jetons sont affichés tels quels,
            // en majuscules : une bande inconnue de cette version doit rester lisible.
            infoRow(
                "Fréquences",
                outage.affectedBands.isEmpty
                    ? nil
                    : outage.affectedBands.map { $0.uppercased() }.joined(separator: " · ")
            )
            infoRow(
                "Secteurs",
                outage.affectedSectors.isEmpty
                    ? nil
                    : outage.affectedSectors.map { "\($0)°" }.joined(separator: " · ")
            )
            // Le RÉSUMÉ de la capture, jamais la capture : le serveur l'a déjà purgé de toute
            // position, et c'est lui qui étiquette les captures iOS comme partielles.
            infoRow("Mesure jointe", outage.radioSummary)
        }
        .padding(.vertical, SQSpace.xs)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
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
                    .font(SQFont.body(13.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            Divider().padding(.leading, SQSpace.md)
        }
    }

    // MARK: - Présentation

    private var siteLabel: String {
        if let name = outage.siteName, !name.isEmpty { return name }
        return outage.targetId.isEmpty ? String(localized: "Panne signalée") : outage.targetId
    }

    /// L'adresse, sauf quand elle RÉPÈTE mot pour mot le titre.
    ///
    /// Les deux champs viennent du même référentiel : sur les sites sans nom propre, `siteName`
    /// vaut déjà la voie — « route des Serrières », constaté sur l'API de production. L'en-tête
    /// afficherait alors deux fois le même texte. Une adresse plus complète, elle, reste affichée.
    private var secondaryAddress: String? {
        guard let address = outage.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty,
              address.localizedCaseInsensitiveCompare(siteLabel) != .orderedSame
        else { return nil }
        return address
    }

    /// L'état ET la gravité, sur une seule ligne.
    ///
    /// La gravité n'était portée que par la COULEUR de l'en-tête : « Panne signalée » ne dit pas
    /// si le service est dégradé ou totalement absent. Un lecteur d'écran ne pouvait donc pas
    /// l'apprendre, ni personne ne distinguant l'ambre du rouge — alors que c'est ce qui décide
    /// s'il faut se déplacer. Le modèle de carte exige que cette feuille soit complète.
    ///
    /// Écrite ICI et nulle part ailleurs dans la feuille : le bloc d'arbitrage en dessous ne
    /// réécrit ni l'état ni la gravité, c'est tout l'objet de sa séparation d'avec la carte de la
    /// fiche antenne. Rien pour une panne close — « Rétablie » se suffit, et rappeler la gravité
    /// d'alors ferait lire une coupure en cours.
    private var headline: String {
        guard outage.state.isVisible else { return stateLabel }
        let severity = outage.severity == .degraded
            ? String(localized: "Service dégradé")
            : String(localized: "Plus aucun service")
        return "\(stateLabel) · \(severity)"
    }

    /// Suit ce qu'est DEVENUE la panne, pas ce qu'elle a été : garder « Panne signalée » sur une
    /// panne rétablie ferait lire une coupure en cours.
    private var stateLabel: String {
        switch outage.state {
        case .resolved: return String(localized: "Rétablie")
        case .rejected: return String(localized: "Écartée")
        case .dormant: return String(localized: "En veille")
        case .confirmed:
            return outage.operatorConfirmed
                ? String(localized: "Confirmée par l'opérateur")
                : String(localized: "Panne confirmée")
        case .reported: return String(localized: "Panne signalée")
        }
    }

    private var closedReason: String {
        switch outage.state {
        case .rejected: return String(localized: "La communauté n'a pas retrouvé cette panne.")
        case .dormant: return String(localized: "Sans nouvelle depuis un moment. Elle se refermera seule.")
        default: return String(localized: "Le réseau est revenu. Merci de l'avoir signalée.")
        }
    }

    /// La phrase d'un événement, écrite ICI et nulle part ailleurs.
    ///
    /// Le serveur ne rend qu'un genre : une phrase française renvoyée par l'API serait lue telle
    /// quelle par un utilisateur anglophone. `isSelf` remplace le nom de l'acteur — d'où une
    /// variante par verbe, « Quelqu'un confirme » et « Vous confirmez » ne se conjuguant pas de la
    /// même façon. Un genre inconnu n'arrive jamais jusqu'ici : le décodeur l'a déjà écarté.
    private func phrase(for entry: OutageTimelineEntry) -> String {
        switch entry.kind {
        case .reported:
            return entry.isSelf
                ? String(localized: "Vous avez signalé la panne")
                : String(localized: "Signalé par quelqu'un")
        case .reportedAgain:
            return entry.isSelf
                ? String(localized: "Vous signalez aussi la panne")
                : String(localized: "Quelqu'un signale aussi la panne")
        case .confirm:
            guard let services = inlineServices(entry.services) else {
                return entry.isSelf
                    ? String(localized: "Vous confirmez")
                    : String(localized: "Quelqu'un confirme")
            }
            return entry.isSelf
                ? String(localized: "Vous confirmez — \(services)")
                : String(localized: "Quelqu'un confirme — \(services)")
        case .dispute:
            return entry.isSelf
                ? String(localized: "Vous dites que ça marche")
                : String(localized: "Quelqu'un dit que ça marche")
        case .repaired:
            return entry.isSelf
                ? String(localized: "Vous signalez le rétablissement")
                : String(localized: "Quelqu'un signale le rétablissement")
        case .stateConfirmed:
            return String(localized: "Panne confirmée par la communauté")
        case .operatorConfirmed:
            return String(localized: "\(operatorLabel) liste l'incident")
        case .dormant:
            return String(localized: "Panne mise en veille")
        case .resolvedCommunity:
            return String(localized: "La communauté signale le rétablissement")
        case .resolvedAuthor:
            return entry.isSelf
                ? String(localized: "Vous avez refermé la panne")
                : String(localized: "Panne refermée par son auteur")
        case .resolvedOperator:
            return String(localized: "\(operatorLabel) a rétabli le service")
        case .resolvedMeasured:
            return String(localized: "Réseau mesuré comme revenu")
        case .resolvedAdmin:
            return String(localized: "Panne close par la modération")
        case .rejected:
            return String(localized: "Panne écartée")
        }
    }

    /// « Internet, Voix » — les mêmes trois mots que partout ailleurs dans la fonctionnalité, et
    /// composés par le même helper.
    ///
    /// Pas de forme minuscule dédiée (« données », « appels ») : ce sont les libellés de services
    /// choisis pour le produit, et en donner deux versions rendrait le vocabulaire flottant.
    private func inlineServices(_ services: [String]) -> String? {
        let label = OutageServices.label(codes: services)
        return label.isEmpty ? nil : label
    }

    // MARK: - Actions

    /// Va chercher la chronologie, que seule la route de détail porte.
    ///
    /// La carte et la page « Pannes signalées » rendent `timeline` à `nil` — le serveur ne la
    /// charge pas sur une liste. Un échec reste SILENCIEUX : le bloc ne se monte pas, et tout le
    /// reste de la feuille est déjà là. Une bannière d'erreur pour un complément d'information
    /// crierait plus fort que ce qu'elle apporte.
    private func loadTimeline() async {
        guard outage.timeline == nil else { return }
        if let detailed = try? await service.detail(outageId: outage.id) {
            outage = detailed
        }
    }

    /// Se prononcer, puis adopter la panne que le serveur renvoie.
    ///
    /// La position accompagne le vote sans jamais être vérifiée ici : l'éligibilité se joue côté
    /// serveur. Un refus arrive sous forme de CODE, que `OutageWriteError` met en mots.
    private func vote(_ kind: String) async {
        guard !voting else { return }
        voting = true
        errorMessage = nil
        let here = services.location.lastLocation
        do {
            let response = try await service.vote(
                outageId: outage.id,
                kind: kind,
                latitude: here?.coordinate.latitude,
                longitude: here?.coordinate.longitude,
                accuracyMeters: here.flatMap { $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil }
            )
            // La réponse d'écriture porte la chronologie à jour : c'est ce vote-ci qui vient de
            // s'y ajouter, et le lecteur doit l'y voir sans relire la fiche.
            if let updated = response.outage { outage = updated }
            onChanged?()
        } catch {
            errorMessage = OutageWriteError.message(for: error)
        }
        voting = false
    }

    /// L'auteur referme sa panne.
    ///
    /// On adopte la panne renvoyée par le serveur plutôt que de fermer la feuille : elle bascule
    /// sous les yeux en « Rétablie », avec sa chronologie complétée de la ligne qu'on vient
    /// d'écrire. `onChanged` prévient la carte, dont le marqueur doit disparaître pour tout le
    /// monde. Le refus, lui, est écrit par le client sur le CODE reçu : `NOT_AUTHOR` et
    /// `OUTAGE_CLOSED` ne se disent pas pareil, et la phrase du serveur n'existe qu'en français.
    private func close() async {
        guard !closing else { return }
        closing = true
        errorMessage = nil
        do {
            let response = try await service.close(outageId: outage.id)
            if let updated = response.outage { outage = updated }
            onChanged?()
        } catch {
            errorMessage = OutageWriteError.message(for: error)
        }
        closing = false
    }
}
