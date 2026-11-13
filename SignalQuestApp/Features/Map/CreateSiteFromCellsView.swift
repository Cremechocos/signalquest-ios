import SwiftUI
import MapKit
import CoreLocation

/// Pose un site à partir de cellules observées.
///
/// Les cellules apportent l'identité radio — eNB, PCI, TAC, bande, PLMN — mais
/// leur position n'est qu'un centroïde de mesures. L'écran part donc de ce
/// centroïde, le donne comme point de départ, et laisse déplacer la carte
/// jusqu'au pylône réel. C'est le seul apport que la machine ne peut pas
/// fournir : quelqu'un qui l'a vu.
struct CreateSiteFromCellsView: View {
    let cells: [AndroidCommunitySiteMarker]
    let operatorLabel: (String) -> String
    let service: CustomSitesServicing
    /// Appelé après création réussie, pour rafraîchir la carte.
    let onCreated: () -> Void
    /// Contestation déjà ouverte par « Ce n'est pas le bon site » (DISPUTED-SITE r1).
    let initialDispute: CustomSiteDispute?
    /// « Voir ce site » : l'hôte ouvre le site désigné ; nil = pas de bouton.
    let onViewSite: ((CustomSiteRadioCheck) -> Void)?
    /// « Ce n'est pas le bon site » / « Corriger ton site » : l'hôte rouvre l'identification sur
    /// la carte avec la contestation (nil pour son propre site). Sans hôte, la contestation
    /// s'ouvre ici, dans le formulaire, et son propre site ne se corrige pas d'ici.
    let onWrongSite: ((CustomSiteDispute?) -> Void)?
    /// Message à montrer une fois la feuille fermée (position officielle proche du site créé).
    let onNotice: ((String) -> Void)?
    /// « Voir cette position » (OFFICIAL-NEARBY r1) : l'hôte ouvre la fiche officielle ; nil = pas de bouton.
    let onViewOfficial: ((OfficialNearbySite) -> Void)?

    @State private var name = ""
    @State private var type = "PYLONE"
    @State private var note = ""
    @State private var region: MKCoordinateRegion
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var pendingMessage: String?
    @State private var isQueued = false
    /// Contrôle du nœud en cours : le bouton attend sa réponse.
    @State private var isChecking = true
    /// Le nœud a déjà un site : la feuille du refus remplace le formulaire.
    @State private var linked: CustomSiteAlreadyLinked?
    @State private var dispute: CustomSiteDispute?
    /// Positions officielles BE/CH proches : la feuille passe avant la création.
    @State private var officialNearby: [OfficialNearbySite] = []
    /// « Aucune ne convient, créer le site » : on ne redemande plus pour ce formulaire.
    @State private var skipsOfficialNearby = false
    @Environment(\.dismiss) private var dismiss

    /// Types acceptés par le backend (`ALLOWED_TYPES`). Envoyer autre chose fait
    /// échouer la création en 400.
    private static let types: [(value: String, label: String)] = [
        ("PYLONE", String(localized: "Pylône")),
        ("TOIT", String(localized: "Toit-terrasse")),
        ("CHATEAU_EAU", String(localized: "Château d'eau")),
        ("INFRASTRUCTURE", String(localized: "Infrastructure")),
        ("LIEU_PUBLIC", String(localized: "Lieu public")),
        ("AUTRE", String(localized: "Autre"))
    ]

    init(
        cells: [AndroidCommunitySiteMarker],
        operatorLabel: @escaping (String) -> String,
        service: CustomSitesServicing,
        initialDispute: CustomSiteDispute? = nil,
        onViewSite: ((CustomSiteRadioCheck) -> Void)? = nil,
        onWrongSite: ((CustomSiteDispute?) -> Void)? = nil,
        onNotice: ((String) -> Void)? = nil,
        onViewOfficial: ((OfficialNearbySite) -> Void)? = nil,
        onCreated: @escaping () -> Void
    ) {
        self.cells = cells
        self.operatorLabel = operatorLabel
        self.service = service
        self.initialDispute = initialDispute
        self.onViewSite = onViewSite
        self.onWrongSite = onWrongSite
        self.onNotice = onNotice
        self.onViewOfficial = onViewOfficial
        self.onCreated = onCreated
        // Centroïde des cellules retenues : le meilleur point de départ dont on
        // dispose, même s'il n'est pas le bon.
        let lat = cells.map(\.lat).reduce(0, +) / Double(max(cells.count, 1))
        let lng = cells.map(\.lng).reduce(0, +) / Double(max(cells.count, 1))
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        ))
    }

    private var draft: CustomSiteDraft {
        var draft = CustomSiteDraft.fromObservedCells(
            cells,
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            name: name,
            type: type,
            description: note.isEmpty ? nil : note
        )
        draft.disputedSiteId = dispute?.siteId
        return draft
    }

    var body: some View {
        Group {
            if let linked {
                alreadyLinked(linked)
            } else if !officialNearby.isEmpty {
                officialNearbySheet
            } else {
                form
            }
        }
        .task { await checkNode() }
    }

    /// Le refus sous les yeux du membre : il choisit, la feuille ne se referme pas seule.
    private func alreadyLinked(_ linked: CustomSiteAlreadyLinked) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    Button("Fermer") { dismiss() }
                        .font(SQType.body(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("createSite.cancel")
                    Spacer()
                }
                CustomSiteAlreadyLinkedView(
                    linked: linked,
                    onViewSite: onViewSite.map { open in { open(linked.check) } },
                    onWrongSite: wrongSiteAction(for: linked),
                    opensMapIdentification: onWrongSite != nil
                )
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .sqSheet(background: SQColor.bg)
    }

    /// « Ton antenne est peut-être déjà là » : « Retour » rend le formulaire (pour déplacer le
    /// point), « Aucune ne convient » crée le site sans redemander.
    private var officialNearbySheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    Button("Retour") { officialNearby = [] }
                        .font(SQType.body(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("createSite.officialNearby.back")
                    Spacer()
                }
                CustomSiteOfficialNearbyView(
                    sites: officialNearby,
                    radio: draft.radio,
                    operatorLabel: operatorLabel,
                    onViewPosition: onViewOfficial,
                    onCreate: {
                        skipsOfficialNearby = true
                        Task {
                            await submit()
                            // Un refus ou un envoi en file s'affiche dans le formulaire.
                            officialNearby = []
                        }
                    },
                    isBusy: isSubmitting
                )
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .sqSheet(background: SQColor.bg)
    }

    private func wrongSiteAction(for linked: CustomSiteAlreadyLinked) -> (() -> Void)? {
        let dispute = CustomSiteDispute(check: linked.check, radio: linked.radio)
        if let onWrongSite {
            // Son propre site se corrige sur la carte, sans contestation (le serveur la refuserait).
            return { onWrongSite(linked.isOwn ? nil : dispute) }
        }
        guard !linked.isOwn, let dispute else { return nil }
        return {
            self.dispute = dispute
            self.linked = nil
        }
    }

    /// DISPUTED-SITE r1 : avant le formulaire, le serveur dit si le nœud a déjà un site. Un échec
    /// (hors ligne) laisse créer : la création, elle, contrôle toujours.
    private func checkNode() async {
        defer { isChecking = false }
        guard let radio = draft.radio, radio.hasNode else { return }
        guard let check = try? await service.check(radio), check.blocksCreation else { return }
        if let initialDispute, initialDispute.applies(to: radio, check: check) {
            dispute = initialDispute
            return
        }
        linked = CustomSiteAlreadyLinked(check: check, radio: radio, operatorLabel: radio.mobileOperator.map(operatorLabel))
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                positionPicker
                // Le bouton reste grisé tant que le nom n'a pas 2 caractères : on le dit sous le champ
                // plutôt que de laisser deviner, et la saisie est bornée comme le backend.
                field(
                    String(localized: "Nom du site"),
                    text: $name,
                    placeholder: String(localized: "Pylône rue des Lilas"),
                    help: String(localized: "Minimum 2 caractères."),
                    maxLength: CustomSiteDraft.nameLengthRange.upperBound
                )
                typePicker
                field(String(localized: "Note (facultatif)"), text: $note, placeholder: String(localized: "Ce qui aide à le reconnaître"))
                radioSummary
                if let dispute {
                    SQNotice(message: dispute.formNote, systemImage: "exclamationmark.circle", tone: .warning)
                        .accessibilityIdentifier("createSite.disputeNote")
                }
                if let errorMessage {
                    SQNotice(message: errorMessage, tone: .danger)
                }
                if let pendingMessage {
                    SQNotice(message: pendingMessage, systemImage: "clock.arrow.circlepath", tone: .success)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(SQColor.bg.ignoresSafeArea())
        // Le bouton reste en bas, au-dessus du clavier : on le valide sans
        // avoir à fermer la saisie ni à redescendre.
        .safeAreaInset(edge: .bottom) {
            submitButton
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQSpace.sm)
                .background(SQColor.bg.ignoresSafeArea())
        }
        .sqSheet(background: SQColor.bg)
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            Button(isQueued ? "Fermer" : "Annuler") { dismiss() }
                .font(SQType.body(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("createSite.cancel")
            Text("Nouveau site")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .frame(maxWidth: .infinity)
                .sqHeader()
            // Contrepoids du bouton de gauche, pour centrer le titre.
            Button(isQueued ? "Fermer" : "Annuler") {}
                .font(SQType.body(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Carte + réticule fixe : on déplace la CARTE sous la croix, pas un
    /// marqueur sur la carte. Le doigt ne masque donc jamais le point visé.
    private var positionPicker: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Où est l'antenne ?").sqKicker()
            ZStack {
                Map(coordinateRegion: $region)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(SQColor.brandRed)
                    .shadow(color: .black.opacity(0.25), radius: 3)
                    .allowsHitTesting(false)
            }
            (Text("Déplace la carte pour viser le pylône. Le point de départ est la moyenne des mesures, pas l'antenne.")
                + Text(verbatim: " · ")
                + Text(verbatim: String(format: "%.5f, %.5f", region.center.latitude, region.center.longitude))
                    .font(SQFont.body(12, .semibold).monospacedDigit()))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Pastilles plutôt qu'un menu : les six types se lisent d'un coup d'œil.
    private var typePicker: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Type de support")
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.label)
            FlowLayout(spacing: SQSpace.xs2) {
                ForEach(Self.types, id: \.value) { entry in
                    SQChip(label: entry.label, isSelected: type == entry.value) { type = entry.value }
                }
            }
        }
    }

    /// Ce que le site reprendra des cellules : l'utilisateur doit voir ce qu'il
    /// signe, d'autant qu'il n'a pas saisi ces valeurs lui-même.
    private var radioSummary: some View {
        let radios = draft.normalized().operatorRadios
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Identifiants repris").sqKicker()
            VStack(spacing: 0) {
                ForEach(radios, id: \.operator) { radio in
                    HStack(spacing: SQSpace.sm) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(SQBrand.operatorColor(operatorLabel(radio.operator)))
                            .frame(width: 4, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(operatorLabel(radio.operator))
                                .font(SQType.callout(.semibold))
                                .foregroundStyle(SQColor.label)
                            let identifiers = [
                                radio.enb.map { "eNB \($0)" },
                                radio.gnb.map { "gNB \($0)" },
                                radio.pci.map { "PCI \($0)" },
                                radio.band.map { SQUnits.band($0, technology: radio.technology ?? (radio.gnb != nil ? "NR" : nil)) }
                            ].compactMap { $0 }.joined(separator: " · ")
                            if !identifiers.isEmpty {
                                Text(identifiers)
                                    .font(SQType.caption.monospacedDigit())
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let tech = radio.technology, !tech.isEmpty {
                            MapTechTag(technology: tech, label: tech)
                        }
                    }
                    .frame(minHeight: 46)
                    if radio.operator != radios.last?.operator {
                        Divider().overlay(SQColor.separator)
                    }
                }
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
    }

    private var canSubmit: Bool { draft.isValid && !isSubmitting && !isQueued && !isChecking }

    private var submitButton: some View {
        GradientButton(
            isQueued ? String(localized: "En attente d'envoi") : String(localized: "Créer le site"),
            systemImage: isQueued ? "clock.arrow.circlepath" : nil,
            isBusy: isSubmitting
        ) {
            Task { await submit() }
        }
        .disabled(!canSubmit)
        .accessibilityIdentifier("createSite.submit")
    }

    private func submit() async {
        guard draft.isValid, !isSubmitting, !isQueued else { return }
        isSubmitting = true
        errorMessage = nil
        pendingMessage = nil
        defer { isSubmitting = false }
        // OFFICIAL-NEARBY r1 : en Belgique et en Suisse, les positions officielles proches d'abord.
        // Un échec, un délai dépassé ou hors ligne laisse créer : la réponse de création signale
        // encore une position proche, et le site en file attend la connexion comme avant.
        if !skipsOfficialNearby, let query = OfficialNearbyQuery(draft: draft) {
            let disputed = dispute?.siteId
            let sites = ((try? await service.officialNearby(query)) ?? [])
                // Le site que le membre conteste, il l'a déjà écarté.
                .filter { disputed == nil || ($0.siteKey != disputed && $0.supId != disputed) }
            if !sites.isEmpty {
                officialNearby = sites
                return
            }
        }
        do {
            let result = try await service.create(draft)
            Haptics.success()
            if result.isPending {
                isQueued = true
                pendingMessage = String(localized: "Proposition enregistrée. Elle sera envoyée automatiquement dès que la connexion le permettra.")
            } else {
                onCreated()
                dismiss()
                if let notice = result.nearbyOfficialNotice { onNotice?(notice) }
            }
        } catch let refusal as CustomSiteAlreadyLinkedError {
            Haptics.error()
            // Le site actuel a changé depuis le contrôle (ou c'est celui du membre) : la feuille
            // revient avec ce que le serveur dit maintenant. Sans site désigné, un message suffit.
            if let check = refusal.check, check.linkedSiteId != nil, let radio = draft.radio {
                dispute = nil
                linked = CustomSiteAlreadyLinked(check: check, radio: radio, operatorLabel: radio.mobileOperator.map(operatorLabel))
            } else {
                errorMessage = String(localized: "Ce nœud a déjà un site : le nouveau site n’a pas été ajouté.")
            }
        } catch {
            Haptics.error()
            errorMessage = error.userFacingMessage
        }
    }

    @ViewBuilder
    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        help: String? = nil,
        maxLength: Int? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(LocalizedStringKey(label))
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.label)
            TextField(placeholder, text: text)
                .font(SQFont.body(15))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm2)
                .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .onChangeCompat(of: text.wrappedValue) { _, newValue in
                    if let maxLength, newValue.count > maxLength {
                        text.wrappedValue = String(newValue.prefix(maxLength))
                    }
                }
            if let help {
                Text(verbatim: help)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }
}
