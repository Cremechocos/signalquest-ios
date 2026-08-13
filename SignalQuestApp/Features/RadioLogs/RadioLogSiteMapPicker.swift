import CoreLocation
import MapKit
import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

extension AndroidCommunitySiteMarker {
    /// Fabrique un marqueur à partir d'un relevé du journal, pour pré-remplir la création d'un
    /// site communautaire.
    ///
    /// Le type porte un `init(from decoder:)` sur mesure, donc Swift ne synthétise aucun
    /// initialiseur mémberwise — d'où celui-ci. Il ne renseigne QUE ce que le journal sait, et
    /// laisse le reste vide : inventer des statistiques d'observation ou une cellule précise
    /// ferait passer une déduction pour une mesure.
    ///
    /// La cellule reste volontairement absente : un nœud du journal en porte plusieurs, en
    /// choisir une serait arbitraire. Le serveur vérifie de toute façon la cohérence sur le
    /// NŒUD (eNB/gNB), pas sur le secteur.
    init(fromRadioLog site: RadioLogSite, latitude: Double, longitude: Double, operatorKey: String?) {
        self.init(
            id: "radiolog:\(site.id)",
            candidateKey: nil,
            candidateKind: "observed_cell",
            marketCode: nil,
            operatorKey: operatorKey,
            networkGroupKey: nil,
            radioNodeType: site.kind == .gnb ? "gnb" : "enb",
            enb: site.kind == .enb ? site.node : nil,
            gnb: site.kind == .gnb ? site.node : nil,
            cellId: nil,
            ci: nil,
            pci: nil,
            tac: nil,
            earfcn: site.earfcn,
            nrarfcn: nil,
            band: site.band,
            mcc: site.mcc.flatMap(Int.init),
            mnc: site.mnc.flatMap(Int.init),
            firstObservedAt: site.firstSeenAt,
            lat: latitude,
            lng: longitude,
            radiusMeters: nil,
            confidenceScore: nil,
            confidenceLevel: nil,
            observationCount: site.logCount,
            distinctUserCount: nil,
            medianAccuracyMeters: nil,
            lastObservedAt: site.lastSeenAt
        )
    }
}

/// « Choisir une autre antenne sur la carte ».
///
/// Les propositions du serveur couvrent le cas courant, pas tous les cas : un
/// site relevé depuis une position bruitée, une antenne récente absente des
/// validations, un relevé fait en mouvement. Cet écran ouvre le choix à
/// n'importe quelle antenne du référentiel, en demandant confirmation — parce
/// qu'une identification manuelle engage la base communautaire.
struct RadioLogSiteMapPicker: View {
    let site: RadioLogSite
    @ObservedObject var picker: RadioLogIdentifyPicker
    let antennas: AntennasServicing
    /// Création d'un site communautaire — le seul geste possible quand le référentiel ne
    /// connaît rien ici. `nil` retire simplement le bouton.
    var customSites: CustomSitesServicing?
    @Environment(\.dismiss) private var dismiss

    @State private var region: MKCoordinateRegion
    @State private var visible: [AntennaSite] = []
    @State private var selected: AntennaSite?
    @State private var isLoading = false
    @State private var loadError: String?
    /// Clé de la zone déjà chargée, arrondie : évite de recharger à chaque
    /// micro-déplacement de la carte.
    @State private var loadedKey: String?
    @State private var showsConfirmation = false
    /// Ne montrer que les antennes compatibles avec les anneaux TA. Actif d'emblée : c'est
    /// l'état utile — sans lui, les cercles se noient sous des dizaines d'épingles.
    @State private var showOnlyPlausible = true
    /// Les candidats affichés viennent-ils de la communauté plutôt que d'un référentiel
    /// officiel ? Ça change ce qu'on peut promettre : ces sites ont été placés à la main.
    @State private var isCommunityFallback = false
    @State private var showsCreateSite = false
    /// Le recadrage sur les anneaux n'a lieu qu'une fois : après, la carte appartient à
    /// l'utilisateur et la lui reprendre en pleine exploration serait insupportable.
    @State private var didFrameOnRings = false
    /// Renseigné une fois l'écriture acceptée par le serveur.
    let onIdentified: (String) -> Void

    init(
        site: RadioLogSite,
        picker: RadioLogIdentifyPicker,
        antennas: AntennasServicing,
        customSites: CustomSitesServicing? = nil,
        onIdentified: @escaping (String) -> Void
    ) {
        self.site = site
        self.picker = picker
        self.antennas = antennas
        self.customSites = customSites
        self.onIdentified = onIdentified
        _region = State(
            initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: site.latitude ?? 46.6,
                    longitude: site.longitude ?? 2.5
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                plausibleToggle
                overlayCard
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle("Choisir l'antenne")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text(operatorLabel)
                        .font(SQFont.body(12.5, .semibold))
                        .foregroundStyle(P.accentInk)
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.xs + 1)
                        .background(P.accentSoft, in: Capsule(style: .continuous))
                        .accessibilityLabel("Antennes affichées : \(operatorLabel)")
                }
            }
            // Recadrage sur les anneaux, UNE FOIS. La fenêtre de départ tient 3 km autour du
            // RELEVÉ ; quand le TA annonce 5 km, le site est hors champ et l'écran cherche des
            // antennes là où il ne peut y en avoir. Les anneaux, eux, savent où regarder.
            .onChange(of: picker.taRings.count) { count in
                guard !didFrameOnRings, count >= 1 else { return }
                didFrameOnRings = true
                if let framed = Self.regionCovering(picker.taRings) { region = framed }
            }
            .task(id: regionKey) { await loadIfNeeded() }
            // Le site naît AU CENTRE DE LA CARTE, pas sur la position du relevé : les anneaux
            // sont sous les yeux, l'utilisateur a donc déjà cadré là où ils se croisent.
            .sheet(isPresented: $showsCreateSite) {
                if let customSites {
                    CreateSiteFromCellsView(
                        cells: [
                            AndroidCommunitySiteMarker(
                                fromRadioLog: site,
                                latitude: region.center.latitude,
                                longitude: region.center.longitude,
                                operatorKey: queriedOperatorKeys.first
                            )
                        ],
                        operatorLabel: { $0 },
                        service: customSites,
                        onCreated: {
                            showsCreateSite = false
                            // Forcer le rechargement : le site tout juste créé doit apparaître
                            // comme candidat, sinon on l'a posé sans pouvoir s'y rattacher.
                            loadedKey = nil
                        }
                    )
                }
            }
            .alert("Identifier ce site ?", isPresented: $showsConfirmation) {
                Button("Annuler", role: .cancel) {}
                Button("Identifier") { Task { await confirm() } }
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    // MARK: Carte

    /// Carte de choix du site.
    ///
    /// ⚠️ DEUX RENDUS, ET CE N'EST PAS UN CAPRICE. Les anneaux TA sont des OVERLAYS, or
    /// `Map(coordinateRegion:annotationItems:)` — la seule API disponible en iOS 16 — n'en
    /// accepte aucun. La carte moderne (iOS 17+) les trace ; en dessous, l'écran reste celui
    /// d'avant, avec ses antennes et sans cercles. Aucun appareil ne perd de fonction.
    @ViewBuilder
    private var map: some View {
        if #available(iOS 17.0, *) {
            modernMap
        } else {
            legacyMap
        }
    }

    /// Carte iOS 17+ : les antennes ET les anneaux TA.
    @available(iOS 17.0, *)
    private var modernMap: some View {
        Map(initialPosition: .region(region)) {
            // Les anneaux d'abord : ils sont un fond de raisonnement, les épingles se
            // lisent par-dessus.
            ForEach(picker.taRings) { ring in
                // La COURONNE dit l'incertitude — résolution du TA plus précision GPS. Un
                // trait seul prétendrait une précision qui n'existe pas.
                MapCircle(center: ring.coordinate, radius: ring.radiusMeters + ring.toleranceMeters)
                    .foregroundStyle(taRingTint.opacity(0.06))
                MapCircle(center: ring.coordinate, radius: ring.radiusMeters)
                    .foregroundStyle(.clear)
                    .stroke(taRingTint.opacity(0.85), lineWidth: 1.5)
            }
            ForEach(pins) { pin in
                Annotation("", coordinate: pin.coordinate) {
                    pinLabel(for: pin)
                }
            }
        }
        // ⚠️ SANS CECI, DÉPLACER LA CARTE NE CHARGE RIEN. `Map(initialPosition:)` ne renseigne
        // que la position de DÉPART : `region` restait donc figée sur la fenêtre initiale, et
        // comme le chargement est déclenché par `.task(id: regionKey)`, une seule requête
        // partait — sur une zone de 3 km autour du relevé. L'écran affichait « Aucune antenne
        // dans cette zone. Déplace la carte. », et déplacer la carte ne changeait rien.
        //
        // Le rendu iOS 16 (`legacyMap`) n'a jamais eu ce défaut : il reçoit `$region` en
        // liaison, donc il la met à jour lui-même.
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// Des anneaux qui ne se croisent nulle part APPRENNENT quelque chose — handover, TA
    /// périmé, deux sites sous un même identifiant — mais ne doivent pas se faire passer
    /// pour une localisation. D'où deux couleurs, jamais un masquage.
    private var taRingTint: Color {
        picker.taAssessment == .divergent ? SQColor.dangerInk : SQColor.accentInk
    }

    @ViewBuilder
    private func pinLabel(for pin: PickerPin) -> some View {
        Button {
            if pin.isOrigin { return }
            selected = pin.antenna
            Haptics.selection()
        } label: {
            if pin.isOrigin {
                Image(systemName: "dot.scope")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(P.ink)
                    .padding(6)
                    .background(P.card, in: Circle())
                    .sqShadowSoft()
            } else {
                SQAntennaMarker(
                    azimuths: pin.azimuths,
                    isSelected: pin.isSelected,
                    diameter: pin.isSelected ? 38 : 32
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pin.isOrigin ? "Position des relevés" : "Antenne \(pin.antenna?.siteId ?? "")")
    }

    private var legacyMap: some View {
        SQRegionMap(region: $region, items: pins) { pin in
            MapAnnotation(coordinate: pin.coordinate) {
                Button {
                    if pin.isOrigin { return }
                    selected = pin.antenna
                    Haptics.selection()
                } label: {
                    if pin.isOrigin {
                        Image(systemName: "dot.scope")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(P.ink)
                            .padding(6)
                            .background(P.card, in: Circle())
                            .sqShadowSoft()
                    } else {
                        SQAntennaMarker(
                            azimuths: pin.azimuths,
                            isSelected: pin.isSelected,
                            diameter: pin.isSelected ? 38 : 32
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pin.isOrigin ? "Position des relevés" : "Antenne \(pin.antenna?.siteId ?? "")")
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private struct PickerPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let isOrigin: Bool
        let isSelected: Bool
        let antenna: AntennaSite?
        /// Orientation des secteurs, pour lire d'un coup d'œil vers où l'antenne
        /// émet — l'information qu'on va justement chercher sur le terrain.
        let azimuths: [Double]
    }

    /// Bascule « antennes compatibles » / « toutes ».
    ///
    /// Le COMPTE est le libellé, parce que c'est lui l'information : « 3 sur 40 » dit d'un
    /// coup d'œil ce que la géométrie a éliminé. Le bouton n'apparaît que si le filtre a
    /// quelque chose à dire — un bouton qui ne changerait rien est pire qu'un bouton absent.
    @ViewBuilder
    private var plausibleToggle: some View {
        if let plausible, !plausible.isEmpty {
            let shown = showOnlyPlausible ? plausible.count : visible.count
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showOnlyPlausible.toggle() }
                    } label: {
                        HStack(spacing: SQSpace.xs) {
                            Image(systemName: showOnlyPlausible
                                ? "scope"
                                : "antenna.radiowaves.left.and.right")
                                .font(SQFont.body(12, .semibold))
                            Text("\(shown)")
                                .font(SQFont.body(13, .bold))
                            Text(showOnlyPlausible
                                ? (plausible.count > 1 ? "compatibles" : "compatible")
                                : "antennes")
                                .font(SQFont.body(12, .medium))
                        }
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.sm)
                        .foregroundStyle(showOnlyPlausible ? SQColor.bg : P.accentInk)
                        .background(
                            showOnlyPlausible ? AnyShapeStyle(P.accentInk) : AnyShapeStyle(P.card),
                            in: Capsule(style: .continuous)
                        )
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
                    }
                    // Le libellé complet dit le POURQUOI, que le compte seul ne porte pas.
                    .accessibilityLabel(showOnlyPlausible
                        ? "\(plausible.count) antennes compatibles avec vos anneaux TA. Toucher pour afficher les \(visible.count)."
                        : "\(visible.count) antennes affichées. Toucher pour ne garder que les \(plausible.count) compatibles avec vos anneaux TA.")
                    .accessibilityAddTraits(showOnlyPlausible ? [.isSelected] : [])
                    .padding(.trailing, SQSpace.md)
                    .padding(.top, SQSpace.md)
                }
                Spacer()
            }
        }
    }

    /// Fenêtre couvrant les points d'observation ET la zone où le site peut se trouver.
    ///
    /// On élargit du rayon MÉDIAN, pas du plus grand : un seul anneau lointain étirerait la
    /// vue sur des dizaines de kilomètres, où plus rien n'est lisible.
    private static func regionCovering(_ rings: [TaRingSelection.Ring]) -> MKCoordinateRegion? {
        guard !rings.isEmpty else { return nil }
        let lats = rings.map(\.latitude)
        let lons = rings.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }

        let radii = rings.map(\.radiusMeters).sorted()
        let medianRadius = radii[radii.count / 2]
        let padLat = medianRadius / 111_320
        let centerLat = (minLat + maxLat) / 2
        let padLon = medianRadius / (111_320 * max(cos(centerLat * .pi / 180), 0.2))

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                // Plancher : deux relevés au même endroit donneraient un span nul.
                latitudeDelta: max(maxLat - minLat + padLat * 2, 0.02),
                longitudeDelta: max(maxLon - minLon + padLon * 2, 0.02)
            )
        )
    }

    // MARK: Sites plausibles

    /// Sites que la géométrie des anneaux retient. `nil` = le filtre s'abstient.
    ///
    /// ⚠️ RÉSERVÉ AUX GÉOMÉTRIES QUI CONVERGENT. Quand les cercles ne se croisent nulle part,
    /// le « meilleur » candidat n'est que le moins mauvais d'un tirage bruité : masquer les
    /// autres au nom de la géométrie fabriquerait une certitude qui n'existe pas.
    ///
    /// Calculé à la demande — quelques milliers de distances plates pour 400 antennes et 24
    /// anneaux, négligeable devant le rendu de la carte qui parcourt déjà la même liste.
    private var plausible: [TaPlausibility.Scored<AntennaSite>]? {
        guard picker.taAssessment == .convergent else { return nil }
        return TaPlausibility.filterPlausible(visible, rings: picker.taRings) { antenna in
            guard let latitude = antenna.latitude, let longitude = antenna.longitude else {
                return nil
            }
            return (latitude, longitude)
        }
    }

    /// Antennes réellement posées sur la carte, filtre appliqué s'il a quelque chose à dire.
    private var shownAntennas: [AntennaSite] {
        guard showOnlyPlausible, let plausible else { return visible }
        let keep = Set(plausible.map(\.item.id))
        return visible.filter { keep.contains($0.id) }
    }

    private var pins: [PickerPin] {
        var pins: [PickerPin] = []
        if let latitude = site.latitude, let longitude = site.longitude {
            pins.append(
                PickerPin(
                    id: "origin",
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: true,
                    isSelected: false,
                    antenna: nil,
                    azimuths: []
                )
            )
        }
        for antenna in shownAntennas {
            guard let latitude = antenna.latitude, let longitude = antenna.longitude else { continue }
            pins.append(
                PickerPin(
                    id: antenna.id,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: false,
                    isSelected: selected?.id == antenna.id,
                    antenna: antenna,
                    azimuths: antenna.azimuths
                )
            )
        }
        return pins
    }

    // MARK: Carte d'information et action

    private var overlayCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SQSpace.sm) {
                Text(site.nodeLabel)
                    .font(.sqTechnical(M.siteIdSize, .semibold))
                    .foregroundStyle(P.ink)
                RadioLogTechBadge(label: site.techLabel)
                Spacer(minLength: 0)
                if isLoading { ProgressView().controlSize(.small) }
            }

            if let selected {
                Text("Site \(selected.siteId ?? selected.id)")
                    .font(.sqTechnical(13, .semibold))
                    .foregroundStyle(P.ink)
                    .padding(.top, M.siteNameTop)
                if let address = selected.address, !address.isEmpty {
                    Text(address)
                        .font(SQFont.body(M.siteNameSize))
                        .foregroundStyle(P.muted)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
                if let meta = selectedMeta {
                    Text(meta)
                        .font(SQFont.body(M.siteMetaSize))
                        .monospacedDigit()
                        .foregroundStyle(P.muted)
                        .padding(.top, M.siteMetaTop)
                }
            } else {
                Text(visible.isEmpty && !isLoading
                     ? (customSites != nil
                        ? "Aucune antenne connue ici. Crée le site à l'endroit désigné par tes anneaux."
                        : "Aucune antenne dans cette zone. Déplace la carte.")
                     : "Touche une antenne sur la carte pour la choisir.")
                    .font(SQFont.body(M.siteMetaSize))
                    .foregroundStyle(P.muted)
                    .padding(.top, M.siteMetaTop)
            }

            if let loadError {
                Text(loadError)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.warning)
                    .padding(.top, M.siteMetaTop)
            }

            // Ce que la géométrie permet de dire, et ce qu'on a écarté pour le dire. Des
            // anneaux qui divergent APPRENNENT quelque chose — handover, TA périmé, deux sites
            // sous un même identifiant — mais ne doivent pas passer pour une localisation. Et
            // sans la mention des écartés, l'élagage serait une décision invisible.
            if !picker.taRings.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    Image(systemName: picker.taAssessment == .divergent
                          ? "exclamationmark.triangle.fill"
                          : "scope")
                        .font(SQFont.body(11, .semibold))
                    Text(taGeometrySummary)
                        .font(SQFont.body(M.siteMetaSize))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(picker.taAssessment == .divergent ? SQColor.warning : P.muted)
                .padding(.top, M.siteMetaTop)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: M.ctaGap) {
                RadioLogActionButton(label: picker.isSubmitting ? "…" : "Identifier ici") {
                    showsConfirmation = true
                }
                .disabled(selected == nil || picker.isSubmitting)
                .opacity(selected == nil ? 0.5 : 1)
                RadioLogActionButton(label: "Annuler", ghost: true) { dismiss() }
            }
            .padding(.top, M.ctaTop)

            // Créer le site : la seule issue quand le référentiel ne connaît RIEN ici. Sans ce
            // geste, l'écran n'avait ni antenne à désigner, ni moyen d'en ajouter une — et les
            // anneaux TA, qui disent pourtant où elle se trouve, ne servaient à rien.
            if customSites != nil, visible.isEmpty, !isLoading {
                RadioLogActionButton(label: "Créer le site ici", ghost: true) {
                    showsCreateSite = true
                }
                .padding(.top, M.ctaGap)
            }
        }
        .padding(.horizontal, M.cardPaddingH)
        .padding(.vertical, M.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.card, in: RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
        .sqShadowCard()
        .padding(SQSpace.md)
    }

    /// Résumé de ce que les anneaux permettent de conclure — jamais un simple décompte.
    private var taGeometrySummary: String {
        let count = picker.taRings.count
        var text: String
        switch picker.taAssessment {
        case .convergent:
            text = "\(count) anneaux TA — leur intersection désigne le site"
        case .divergent:
            text = "\(count) anneaux TA — ils ne se croisent pas : relevés à vérifier"
        case .unusable:
            text = count > 1
                ? "\(count) anneaux TA — trop rapprochés pour désigner un point"
                : "1 anneau TA — il faut au moins deux passages écartés pour croiser"
        }
        if picker.taDiscardedCount > 0 {
            text += picker.taDiscardedCount > 1
                ? " · \(picker.taDiscardedCount) relevés écartés"
                : " · 1 relevé écarté"
        }
        return text
    }

    private var selectedMeta: String? {
        guard let selected else { return nil }
        var parts: [String] = []
        if let latitude = selected.latitude, let longitude = selected.longitude,
           let originLat = site.latitude, let originLng = site.longitude {
            let distance = CLLocation(latitude: originLat, longitude: originLng)
                .distance(from: CLLocation(latitude: latitude, longitude: longitude))
            parts.append(distance >= 1000
                ? String(format: "à %.1f km", distance / 1000)
                : "à \(Int(distance.rounded())) m")
        }
        let operators = selected.operators.filter { $0.uppercased() != "ALL" }
        if !operators.isEmpty { parts.append(operators.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var confirmationMessage: String {
        let siteId = selected.map { $0.siteId ?? $0.id } ?? "?"
        let place = selected?.address.flatMap { $0.isEmpty ? nil : $0 }
        let base = "\(site.nodeLabel) sera identifié sur le site \(siteId)"
        let located = place.map { "\(base) — \($0)" } ?? base
        return "\(located).\n\nCette identification est publique et attribuée à ton compte. Tu pourras la retirer depuis « Mes identifications »."
    }

    // MARK: Chargement

    /// Zone arrondie au centième de degré (~1 km) : la carte bouge en continu,
    /// pas la donnée. Sans cet arrondi, chaque image de l'animation de panoramique
    /// relancerait une requête.
    private var regionKey: String {
        String(
            format: "%.2f|%.2f|%.2f|%@",
            region.center.latitude,
            region.center.longitude,
            region.span.latitudeDelta,
            operatorKey
        )
    }

    private func loadIfNeeded() async {
        let key = regionKey
        guard loadedKey != key else { return }
        // Au-delà, la requête ramènerait des milliers d'antennes pour rien : on
        // demande plutôt de zoomer, plus honnête qu'une carte qui rame.
        guard region.span.latitudeDelta < 0.5 else {
            visible = []
            loadError = String(localized: "Zoome pour afficher les antennes.")
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let market = RadioLogOperatorResolver.marketCode(forOperator: site.operatorName, mcc: site.mcc) ?? "FR"
        let bbox = BoundingBox(
            north: region.center.latitude + region.span.latitudeDelta / 2,
            south: region.center.latitude - region.span.latitudeDelta / 2,
            east: region.center.longitude + region.span.longitudeDelta / 2,
            west: region.center.longitude - region.span.longitudeDelta / 2
        )
        do {
            var merged: [AntennaSite] = []
            var seen = Set<String>()
            // Éventail EXPLICITE, une requête par opérateur.
            //
            // ⚠️ Ne PAS passer `operatorName: "ALL"` : en France, `AntennasService`
            // le développe en `["SFR", "BOUYGUES", "ALL"]` — Orange et Free en sont
            // absents. C'est cohérent pour la carte, où « ALL » désigne les sites
            // mutualisés et où l'utilisateur a son propre filtre opérateur ; ici ça
            // masquerait silencieusement la moitié du référentiel, sur un journal
            // qui est à 40 % Orange.
            for operatorKey in queriedOperatorKeys {
                let batch = try await antennas.list(
                    bbox: bbox, market: market, operatorName: operatorKey, technologies: []
                )
                for antenna in batch where antenna.hasValidCoordinate {
                    if seen.insert(antenna.siteId ?? antenna.id).inserted { merged.append(antenna) }
                }
            }
            // REPLI COMMUNAUTAIRE. Dans les 40+ pays sans référentiel officiel, la boucle
            // ci-dessus ne peut RIEN ramener : le dataset de `/api/antennas` ne couvre que la
            // France, le Canada, les DROM et les pilotes européens. Là-bas, les antennes sont
            // les sites créés par la communauté — sans cet appel, l'écran restait vide pour
            // toujours, et le geste d'identification impossible.
            //
            // Déclenché sur le VIDE plutôt que sur une liste de marchés en dur : la règle
            // reste juste si un pays bascule un jour vers un référentiel officiel, et elle
            // rend service partout où l'officiel ne connaît rien.
            if merged.isEmpty {
                let community = try await antennas.listCommunitySites(
                    bbox: bbox, market: market, operatorName: queriedOperatorKeys.first
                )
                for site in community where site.hasValidCoordinate {
                    if seen.insert(site.siteId ?? site.id).inserted { merged.append(site) }
                }
                isCommunityFallback = !merged.isEmpty
            } else {
                isCommunityFallback = false
            }
            visible = merged
            loadedKey = key
            // Une zone vide n'est PAS une erreur : la carte d'information le dit déjà, et
            // l'écrire ici affichait deux phrases pour le même fait. `loadError` reste réservé
            // à ce qui a réellement échoué.
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
        }
    }

    /// Opérateur des antennes affichées — celui du LOG, et lui seul.
    ///
    /// Montrer les autres serait contre-productif : le serveur refuse un
    /// rattachement inter-opérateur (`IDENTIFY_OPERATOR_MISMATCH`), donc chaque
    /// antenne d'un autre réseau est un choix qui échouera.
    ///
    /// ⚠️ CAS « ZB » (zone blanche). Ce n'est pas un opérateur mais un
    /// dispositif : un site mutualisé du New Deal, exploité par plusieurs
    /// réseaux. Un log capté sur un site ZB porte le MNC de l'opérateur qui le
    /// dessert, alors que l'antenne est référencée « ZB » côté ANFR. Filtrer sur
    /// le seul opérateur du log masquerait donc précisément l'antenne cherchée :
    /// on interroge les deux.
    private var queriedOperatorKeys: [String] {
        let key = RadioLogOperatorResolver.operatorKey(forOperator: site.operatorName)
        switch key {
        case "ZB": return ["ZB"]
        case let resolved?: return [resolved, "ZB"]
        case nil: return ["ALL"]
        }
    }

    /// Clé stable de la sélection d'opérateur, pour le cache de zone.
    private var operatorKey: String { queriedOperatorKeys.joined(separator: "+") }

    private var operatorLabel: String {
        let keys = queriedOperatorKeys
        if keys == ["ALL"] { return String(localized: "Toutes") }
        if keys.first == "ZB" { return "Zone blanche" }
        return (site.operatorName ?? keys.first ?? "").capitalized
    }

    private func confirm() async {
        guard let selected else { return }
        picker.addManualChoice(selected, origin: site)
        guard let siteId = await picker.submit(site: site) else { return }
        // On se referme AVANT de prévenir : l'appelant peut avancer dans sa file
        // ou changer d'écran, et le faire pendant que la feuille est encore là
        // donnerait une transition qui se marche dessus.
        dismiss()
        onIdentified(siteId)
    }
}
