import CoreLocation
import SwiftUI

/// Feuille de signalement d'une panne.
///
/// L'ordre suit la question qu'on se pose vraiment sur place : « qu'est-ce qui ne marche pas »,
/// puis « quoi précisément », puis « où je suis ». Demander la position en premier — le réflexe
/// technique, puisque c'est elle qui conditionne l'envoi — ferait passer une formalité avant le
/// constat. Même ordre que sur Android, à dessein.
struct OutageReportSheet: View {
    let siteId: String
    /// Référentiel de la cible : `anfr` pour une antenne publiée, `custom` pour un site posé à la
    /// main. Ce n'est pas un détail de contrat — dans les 44 marchés sans open data, le site
    /// communautaire est la SEULE antenne existante, et un `anfr` figé y rendait la résolution de
    /// cible impossible côté serveur (`unknown_site`).
    var targetKind: String = "anfr"
    let siteLabel: String
    let marketCode: String
    let operatorKey: String
    /// Le nom d'opérateur tel que le registre du marché l'écrit — « Bouygues Telecom », pas
    /// « BOUYGUES_TELECOM ». L'en-tête affichait la CLÉ brute : la seule chaîne de cette feuille
    /// qui atteignait encore l'écran sans passer par rien, et la même panne s'y nommait autrement
    /// que dans sa feuille, sa carte de fil et son marqueur. Résolu par l'appelant, comme
    /// `CommunityOutageDetailSheet` : le registre vit dans le modèle de la carte.
    let operatorLabel: String
    let siteLatitude: Double?
    let siteLongitude: Double?
    /// Les bandes et azimuts de CE site, fournis par la fiche qui les a déjà chargés.
    /// Vides = les deux blocs facultatifs ne s'affichent pas, plutôt qu'une liste générique.
    var siteBands: [OutageBandOption] = []
    var siteSectors: [Int] = []
    let service: CommunityOutageServicing
    /// Appelé après un envoi réussi, pour que la fiche recharge ses pannes.
    var onSubmitted: ((OutageWriteResponse) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var services: AppServices

    /// Tout ce que la personne répond, dans un type valeur testable — la vue n'arbitre plus rien.
    /// Aucune gravité à l'ouverture : la feuille arrivait avec « Plus rien » déjà coché, si bien
    /// qu'un signalement pouvait partir sans que personne n'ait jamais choisi.
    @State private var draft = OutageReportDraft()
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var distanceMeters: Int?
    @State private var accuracyMeters: Int?
    /// Ce que le SITE porte : seules ses bandes et ses azimuts sont proposés. Proposer le
    /// catalogue entier reviendrait à offrir des réponses fausses sur une donnée facultative.
    private var availableBands: [OutageBandOption] { siteBands }
    private var availableSectors: [Int] { siteSectors }

    /// Deux conditions, et pas une seule : la gravité doit avoir été CHOISIE, et « quelque chose
    /// ne marche pas, mais rien de précis » n'est pas exploitable par la communauté. Les
    /// technologies n'en font pas partie — ne pas savoir laquelle est en cause n'empêche personne
    /// de constater que rien ne passe.
    private var canSubmit: Bool { !submitting && draft.canSubmit }

    /// Neutre tant que rien n'est choisi : teinter la feuille en rouge avant la réponse serait
    /// remettre par la couleur la pré-sélection qu'on vient de retirer.
    private var tint: Color {
        guard let severity = draft.severity else { return SQColor.labelSecondary }
        return OutageTint.of(severity)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    header
                    whatSection
                    servicesSection
                    technologiesSection
                    // Les deux blocs facultatifs n'existent que pour une dégradation : « plus
                    // rien » veut dire toutes les fréquences et tous les secteurs, et la
                    // question ne se pose pas. `showsImpactFields` porte la règle, testée.
                    if draft.showsImpactFields {
                        if !availableBands.isEmpty { bandsSection }
                        if !availableSectors.isEmpty { sectorsSection }
                    }
                    captureSection
                    commentSection
                    positionSection
                    if let errorMessage {
                        Text(errorMessage)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }
                    submitButton
                    Text("Votre signalement est visible tout de suite. Il devient « confirmé » quand deux autres personnes constatent la même chose.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .padding(SQSpace.lg)
            }
            .background(SQColor.bg)
            .navigationTitle("Signaler un problème")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .task { await measureDistance() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(siteLabel)
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(operatorLabel)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private var whatSection: some View {
        module("Que constatez-vous ?") {
            VStack(spacing: SQSpace.sm) {
                severityOption(
                    .down,
                    title: "Plus rien",
                    detail: "Rien ne passe : ni Internet, ni appels",
                    accent: OutageTint.down
                )
                severityOption(
                    .degraded,
                    title: "Dégradé",
                    detail: "Ça passe moins bien que d'habitude",
                    accent: OutageTint.degraded
                )
            }
        }
    }

    /// ⚠️ DEUX services, plus trois : le SMS a quitté le formulaire.
    ///
    /// Les fiches d'incident des opérateurs ne croisent que Voix et Data — c'est sur elles qu'on
    /// s'aligne, le rapprochement avec leurs fichiers étant tout l'objet du dispositif. Le champ
    /// `affectsSms` reste au contrat et les pannes qui le portent continuent de l'afficher (cf.
    /// `OutageServices.label`) : on cesse de le DEMANDER, on ne supprime aucune donnée.
    private var servicesSection: some View {
        module("Services touchés") {
            HStack(spacing: SQSpace.sm) {
                serviceChip("Internet", isOn: $draft.affectsData)
                serviceChip("Voix", isOn: $draft.affectsVoice)
            }
        }
    }

    /// Les générations touchées — liste SÉPARÉE des services, pas une grille de paires.
    ///
    /// Croiser {Internet, Voix} × {3G, 4G, 5G} comme le fait la feuille d'un opérateur donnerait
    /// six décisions à prendre debout dans la rue, souvent sans réseau. Deux listes indépendantes
    /// en demandent deux. La perte d'information est réelle et assumée : on saura « la 4G et la
    /// 5G, sur Internet et la Voix », pas quelle paire exactement.
    private var technologiesSection: some View {
        module("Technologies touchées") {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(spacing: SQSpace.sm) {
                    ForEach(OutageTechnologies.choices, id: \.self) { token in
                        technologyChip(token)
                    }
                }
                Text("Si vous le savez. Sinon, laissez vide.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }


    /// Les bandes du site. Le libellé porte l'identifiant 3GPP ET la fréquence : « B28 » ne parle
    /// qu'aux experts, « 700 » est ambigu (B28 en 4G, n28 en 5G). Les deux ensemble se lisent.
    private var bandsSection: some View {
        module("Fréquences touchées") {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                OutageWrapRow(items: availableBands, id: \.token) { band in
                    OutageChip(
                        label: LocalizedStringKey(band.displayLabel),
                        selected: draft.bands.contains(band.token),
                        tint: tint
                    ) { draft.toggle(band: band.token) }
                }
                Text("Seules les bandes de ce site sont proposées. Sinon, laissez vide.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    /// Les secteurs, désignés par leur AZIMUT.
    ///
    /// Jamais par un numéro : la numérotation dépend de l'opérateur (SFR compte à partir de 0, les
    /// trois autres à partir de 1), et un numéro écrit ici serait faux une fois sur quatre.
    private var sectorsSection: some View {
        module("Secteurs touchés") {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                OutageSectorRadar(
                    azimuths: availableSectors,
                    selected: draft.sectors,
                    tint: tint
                )
                OutageWrapRow(items: availableSectors, id: \.self) { azimuth in
                    OutageChip(
                        label: LocalizedStringKey("\(azimuth)°"),
                        selected: draft.sectors.contains(azimuth),
                        tint: tint
                    ) { draft.toggle(sector: azimuth) }
                }
                Text("La direction dans laquelle pointe l'antenne. Sinon, laissez vide.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    /// La capture, explicitement étiquetée PARTIELLE.
    ///
    /// iOS ne lit ni le niveau reçu ni l'identifiant de cellule — c'est une limite d'Apple, pas un
    /// manque à combler. Le dire ici évite qu'une capture iOS et une capture Android se lisent
    /// comme équivalentes alors qu'elles ne mesurent pas la même chose.
    private var captureSection: some View {
        module("Joindre la mesure") {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Toggle(isOn: $draft.attachRadio) {
                    Text("Ce que l'iPhone sait du réseau. Votre position n'est jamais publiée.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .tint(SQColor.success)
                if draft.attachRadio {
                    Text(OutageRadioCaptureBuilder.previewText(
                        status: services.networkPath.status,
                        isOnline: services.networkPath.isOnline
                    ))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
                    Text("Capture partielle — iOS ne donne accès ni au niveau reçu, ni à l'identifiant de cellule.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }

    private var commentSection: some View {
        module("Précisions") {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                TextField(
                    "Depuis quand, ce que vous avez essayé…",
                    text: $draft.comment,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .font(SQType.body)
                Text("\(draft.comment.count) / 500")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// La position est DITE, pas demandée.
    ///
    /// L'éligibilité se joue côté serveur ; on annonce simplement ce qu'il verra, pour qu'un
    /// refus ne soit jamais une surprise. Position inconnue ne bloque pas : la branche
    /// « historique récent » peut encore faire passer le signalement.
    private var positionSection: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "location.fill")
                .font(.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Text(positionLabel)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// ⚠️ `String(localized:)` et non des littéraux nus : cette fonction rend un `String`, que la
    /// vue affiche par `Text(String)` — la surcharge qui ne consulte JAMAIS le catalogue. Les trois
    /// phrases Y SONT pourtant traduites (« You are %lld m from the site. »), et restaient
    /// affichées en français. Même correction que `module` / `severityOption` juste au-dessus.
    private var positionLabel: String {
        guard let distanceMeters else {
            return String(localized: "Position inconnue — le signalement partira si vous avez déjà relevé du signal ici.")
        }
        guard let accuracyMeters else {
            return String(localized: "Vous êtes à \(distanceMeters) m du site.")
        }
        return String(localized: "Vous êtes à \(distanceMeters) m du site, à \(accuracyMeters) m près.")
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack {
                Spacer()
                if submitting {
                    ProgressView().tint(.white)
                } else {
                    Text("Signaler la panne")
                        .font(SQFont.body(15, .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .frame(minHeight: 50)
            .background(
                canSubmit ? tint : SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    // MARK: - Fragments

    /// ⚠️ `LocalizedStringKey` et non `String` : la surcharge `Text(String)` ne consulte JAMAIS le
    /// catalogue, si bien que les titres de section restaient français en anglais. Les appels
    /// passent des littéraux, donc le compilateur les verse au catalogue sans autre changement.
    private func module<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title)
                .font(SQFont.body(12.5, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
            content()
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private func severityOption(
        _ value: OutageSeverity,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        accent: Color
    ) -> some View {
        let selected = draft.severity == value
        // La cascade vit dans `OutageReportDraft.select` — un seul endroit, et il est testé.
        return Button {
            draft.select(value)
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? accent : SQColor.labelTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                    Text(detail)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(SQSpace.sm)
            .background(
                selected ? accent.opacity(0.12) : SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func serviceChip(_ label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        chip(label, selected: isOn.wrappedValue) { isOn.wrappedValue.toggle() }
    }

    /// Le jeton du contrat porté à l'écran en capitales : « 4g » → « 4G ». Aucune traduction —
    /// c'est un sigle, pas un mot.
    private func technologyChip(_ token: String) -> some View {
        chip(LocalizedStringKey(token.uppercased()), selected: draft.technologies.contains(token)) {
            draft.toggle(technology: token)
        }
    }

    /// Une seule puce pour les deux listes : services et technologies se cochent du même geste et
    /// doivent se ressembler à l'écran, sinon on laisse croire qu'elles ne s'utilisent pas pareil.
    private func chip(_ label: LocalizedStringKey, selected: Bool, toggle: @escaping () -> Void) -> some View {
        OutageChip(label: label, selected: selected, tint: tint, toggle: toggle)
    }

    // MARK: - Actions

    /// Annonce la distance que le serveur vérifiera, sans jamais bloquer dessus.
    private func measureDistance() async {
        guard
            let siteLatitude, let siteLongitude,
            let here = services.location.lastLocation
        else { return }
        let site = CLLocation(latitude: siteLatitude, longitude: siteLongitude)
        distanceMeters = Int(here.distance(from: site))
        if here.horizontalAccuracy > 0 { accuracyMeters = Int(here.horizontalAccuracy) }
    }

    private func submit() async {
        let here = services.location.lastLocation
        // Le brouillon refuse lui-même de produire un corps tant que la gravité n'est pas choisie :
        // le bouton désactivé ne couvre pas les chemins clavier et VoiceOver.
        guard let body = draft.request(
            targetKind: targetKind,
            targetId: siteId,
            marketCode: marketCode,
            operatorKey: operatorKey,
            latitude: here?.coordinate.latitude,
            longitude: here?.coordinate.longitude,
            accuracyMeters: here.flatMap { $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil },
            // Composée à l'ENVOI et non à l'ouverture : entre les deux, le réseau a pu tomber ou
            // revenir, et c'est justement ce que la capture décrit. `draft.request` l'écarte
            // d'elle-même si la personne a décoché.
            radioContext: OutageRadioCaptureBuilder.make(
                status: services.networkPath.status,
                isOnline: services.networkPath.isOnline,
                position: here.map {
                    (
                        latitude: $0.coordinate.latitude,
                        longitude: $0.coordinate.longitude,
                        accuracy: $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil
                    )
                }
            ),
            deviceId: InstallationIdentity().deviceID(),
            // L'heure du CONSTAT : elle vaut celle de l'envoi ici (iOS n'a pas de file hors
            // ligne pour les pannes), mais la poser explicitement évite qu'un futur envoi différé
            // date la panne de sa synchronisation.
            observedAt: ISO8601DateFormatter().string(from: Date())
        ) else { return }
        submitting = true
        errorMessage = nil
        do {
            let response = try await service.report(body)
            submitting = false
            onSubmitted?(response)
            dismiss()
        } catch {
            submitting = false
            // Le CODE du serveur, mis en mots ICI : sa phrase à lui n'existe qu'en français.
            errorMessage = OutageWriteError.message(for: error)
        }
    }
}

/// Une case à cocher du formulaire — un service, ou une génération radio.
///
/// Type à part entière et non un `@ViewBuilder` privé de la feuille : c'est la SEULE façon de la
/// rendre en image dans un test, et sa lisibilité à l'état coché est précisément ce qui s'était
/// perdu (cf. `OutageChipStyle`). La feuille, elle, est enveloppée d'un `NavigationStack`
/// qu'`ImageRenderer` ne sait pas peindre.
struct OutageChip: View {
    let label: LocalizedStringKey
    let selected: Bool
    /// La teinte de la feuille, NEUTRE tant que la gravité n'est pas choisie. C'est elle qui
    /// rendait les deux états identiques : rien ici ne doit dépendre d'elle seule.
    let tint: Color
    let toggle: () -> Void

    var body: some View {
        let style = OutageChipStyle.of(selected: selected)
        return Button(action: toggle) {
            HStack(spacing: SQSpace.xs + 1) {
                Image(systemName: style.symbol)
                    .font(.footnote)
                    .foregroundStyle(selected ? tint : SQColor.labelTertiary)
                    // Le pictogramme redit ce que le trait `.isSelected` annonce déjà ; le laisser
                    // parler ferait entendre « coche dans un cercle, Internet, sélectionné ».
                    .accessibilityHidden(true)
                Text(label)
                    .font(SQFont.body(13, style.isBold ? .semibold : .medium))
                    .foregroundStyle(style.labelIsPrimary ? SQColor.label : SQColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            // La teinte se pose PAR-DESSUS le fond commun, elle ne le remplace pas. Substituée,
            // un `tint.opacity(0.13)` neutre donnait un gris plus PÂLE que la crème de la puce
            // vide : la case cochée paraissait la moins active des deux.
            .background(
                selected ? tint.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
            )
            .background(
                SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .strokeBorder(
                        style.borderWidth > 0 ? tint.opacity(0.5) : .clear,
                        lineWidth: style.borderWidth
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Ce qui distingue une puce COCHÉE d'une puce décochée, hors couleur.
///
/// ⚠️ Correctif d'une régression réelle : la feuille reste NEUTRE tant que la gravité n'est pas
/// choisie — décision produit, teinter en rouge avant la réponse remettrait par la couleur la
/// pré-sélection qu'on venait de retirer. Or la puce ne se distinguait alors QUE par sa teinte,
/// laquelle valait `labelSecondary` dans les deux états : « Internet », cochée à l'ouverture,
/// s'affichait exactement comme une case vide. On déclarait un service sans le voir.
///
/// Trois marques non colorées, et c'est délibérément redondant : un pictogramme qui change de
/// FORME, un contour, et un libellé qui passe en encre primaire et en demi-gras. Chacune suffirait
/// ; ensemble elles survivent au daltonisme, au plein soleil et au mode contraste élevé.
///
/// Extrait de la vue pour la même raison qu'`OutageReportDraft` : laissé dans le corps du
/// `@ViewBuilder`, ce choix n'était démontrable que sur appareil, et c'est précisément comme cela
/// qu'il s'est perdu. Ici un test interdit qu'un seul des trois écarts disparaisse.
struct OutageChipStyle: Equatable {
    /// Nom SF Symbol. Famille « cercle », comme les options de gravité juste au-dessus : la
    /// feuille ne doit pas avoir deux vocabulaires de sélection.
    let symbol: String
    /// 0 quand rien n'est coché — un contour permanent ferait ressembler la puce vide à un champ.
    let borderWidth: Double
    /// Encre primaire une fois coché, secondaire sinon : l'écart de contraste se lit même en
    /// niveaux de gris.
    let labelIsPrimary: Bool
    let isBold: Bool

    static func of(selected: Bool) -> OutageChipStyle {
        selected
            ? OutageChipStyle(symbol: "checkmark.circle.fill", borderWidth: 1.5, labelIsPrimary: true, isBold: true)
            : OutageChipStyle(symbol: "circle", borderWidth: 0, labelIsPrimary: false, isBold: false)
    }
}
