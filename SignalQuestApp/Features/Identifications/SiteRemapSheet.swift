import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class SiteRemapViewModel: ObservableObject {
    @Published var sites: [AntennaSite] = []
    @Published var selected: AntennaSite?
    @Published var isLoading = false
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    @Published var initialCenter: CLLocationCoordinate2D?
    /// Hauteur de la vue initiale : assez pour montrer aussi le support du conflit.
    private(set) var initialSpanMeters: CLLocationDistance = 2200
    /// Position du support actuel, pour dire à quelle distance est le choix.
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    /// La cible du conflit n'est présélectionnée qu'une fois : un autre choix du membre reste.
    private var didPreselectConflictTarget = false
    @Published var done = false
    /// Support où le nœud se trouve après le déplacement (le même pour un `noop`).
    private(set) var movedTo: String?

    let item: MyIdentification
    private let antennas: AntennasServicing
    private let identify: IdentifyServicing
    private let location: LocationService
    private let markets: MarketRegistryServicing?
    private var loadTask: Task<Void, Never>?

    init(
        item: MyIdentification,
        antennas: AntennasServicing,
        identify: IdentifyServicing,
        location: LocationService,
        markets: MarketRegistryServicing? = nil
    ) {
        self.item = item
        self.antennas = antennas
        self.identify = identify
        self.location = location
        self.markets = markets
    }

    /// Le site touché est celui où le nœud se trouve déjà : le déplacer ici ne ferait rien.
    var selectedIsCurrentSite: Bool {
        guard let selected else { return false }
        return selected.siteId == item.siteId || selected.id == item.siteId || selected.writeSiteId == item.siteId
    }

    /// Le support où d'autres placent ce nœud (`conflictSiteId`), quand la ligne est en conflit.
    func isConflictTarget(_ site: AntennaSite) -> Bool {
        guard item.conflict, let target = item.conflictSiteId, !target.isEmpty else { return false }
        return site.siteId == target || site.id == target || site.writeSiteId == target
    }

    /// Distance entre le support actuel et le support choisi, quand les deux sont placés.
    func distanceFromCurrent(to site: AntennaSite) -> CLLocationDistance? {
        guard let current = currentCoordinate, let lat = site.latitude, let lng = site.longitude else { return nil }
        return CLLocation(latitude: current.latitude, longitude: current.longitude)
            .distance(from: CLLocation(latitude: lat, longitude: lng))
    }

    /// Centre de repli quand ni le site actuel ni la position ne répondent : celui du
    /// marché de l'identification, à défaut la France, jamais le golfe de Guinée.
    private func marketCenter() async -> CLLocationCoordinate2D {
        if let entry = await markets?.market(forCode: market),
           let latitude = entry.defaultCenterLatitude, let longitude = entry.defaultCenterLongitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return CLLocationCoordinate2D(latitude: 46.6, longitude: 2.5)
    }

    var operatorName: String { item.operatorName ?? "ALL" }
    var market: String? {
        let value = item.marketCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return value.isEmpty ? nil : value
    }

    /// Centre initial : coordonnées du site actuel (même mauvais, le bon est proche),
    /// sinon position de l'utilisateur, sinon centre mondial neutre.
    func prepareCenter() async {
        guard let market else {
            errorMessage = String(localized: "Le marché de cette identification n'est pas renseigné. Aucun pays ne sera déduit automatiquement.")
            if let coordinate = (await location.currentLocation(timeoutSeconds: 4))?.coordinate {
                initialCenter = coordinate
            } else {
                initialCenter = await marketCenter()
            }
            return
        }
        if let details = try? await antennas.details(id: item.siteId, market: market, operatorName: operatorName),
           let core = details.core, core.lat != 0 || core.lng != 0 {
            let current = CLLocationCoordinate2D(latitude: core.lat, longitude: core.lng)
            currentCoordinate = current
            initialCenter = current
            // En conflit, la vue englobe aussi le support des autres, dans la limite où la
            // carte charge encore les supports (0,5° de haut).
            if item.conflict, let lat = item.conflictSiteLat, let lng = item.conflictSiteLng, lat != 0 || lng != 0 {
                let distance = CLLocation(latitude: current.latitude, longitude: current.longitude)
                    .distance(from: CLLocation(latitude: lat, longitude: lng))
                if distance < 25_000 {
                    initialCenter = CLLocationCoordinate2D(latitude: (current.latitude + lat) / 2,
                                                           longitude: (current.longitude + lng) / 2)
                    initialSpanMeters = max(2200, distance * 1.6)
                }
            }
            return
        }
        if let loc = await location.currentLocation(timeoutSeconds: 4) {
            initialCenter = loc.coordinate
        } else {
            initialCenter = await marketCenter()
        }
    }

    func load(bbox: BoundingBox) {
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            defer { isLoading = false }
            guard let market else {
                sites = []
                errorMessage = String(localized: "Le marché doit être connu avant de rechercher un site.")
                return
            }
            // Au-delà de 0,5° de haut, on ne demande pas tous les sites de l'opérateur :
            // la carte invite à zoomer.
            guard bbox.north - bbox.south < 0.5 else {
                sites = []
                errorMessage = String(localized: "Zoome pour afficher les antennes.")
                return
            }
            do {
                let list = try await antennas.list(bbox: bbox, market: market, operatorName: operatorName, technologies: [])
                guard !Task.isCancelled else { return }
                sites = list.filter(\.hasValidCoordinate)
                errorMessage = nil
                if !didPreselectConflictTarget, selected == nil, let target = sites.first(where: isConflictTarget) {
                    didPreselectConflictTarget = true
                    selected = target
                }
            } catch {
                // Une carte vide sans explication passait pour « aucun site ici » (AF-RAD-17).
                guard !Task.isCancelled, !error.isCancellation else { return }
                sites = []
                errorMessage = error.userFacingMessage
            }
        }
    }

    func confirm() async {
        guard let selected else { return }
        let toSiteId = selected.writeSiteId
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await identify.editSite(
                fromSiteId: item.siteId, toSiteId: toSiteId,
                enb: item.enb, gnb: item.gnb, reason: nil
            )
            if result.changed {
                Haptics.success()
                movedTo = result.toSiteId ?? toSiteId
                done = true
            } else {
                errorMessage = result.success ? IdentificationCorrectionText.nothingChanged : String(localized: "Le déplacement n'a pas abouti.")
                Haptics.error()
            }
        } catch {
            errorMessage = IdentificationCorrectionText.failure(error)
            Haptics.error()
        }
    }
}

/// Ré-identifier un nœud eNB/gNB : l'utilisateur choisit le bon site sur la carte.
struct SiteRemapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SiteRemapViewModel
    /// « Recharger mes identifications » après un échec que seule une relecture règle.
    let onReload: (() -> Void)?
    let onDone: (String) -> Void
    /// Le déplacement est public et emporte toutes les cellules du nœud : il se
    /// confirme, comme le choix sur carte des Logs (AF-RAD-17).
    @State private var confirmsRemap = false

    init(
        item: MyIdentification,
        antennas: AntennasServicing,
        identify: IdentifyServicing,
        location: LocationService,
        markets: MarketRegistryServicing? = nil,
        onReload: (() -> Void)? = nil,
        onDone: @escaping (String) -> Void
    ) {
        _model = StateObject(wrappedValue: SiteRemapViewModel(
            item: item, antennas: antennas, identify: identify, location: location, markets: markets
        ))
        self.onReload = onReload
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            if let center = model.initialCenter {
                AntennaPickerMapView(
                    sites: model.sites,
                    selectedId: model.selected?.id,
                    currentSiteId: model.item.siteId,
                    initialCenter: center,
                    initialSpanMeters: model.initialSpanMeters,
                    onRegionChange: { bbox in model.load(bbox: bbox) },
                    onSelect: { site in
                        model.selected = site
                        Haptics.selection()
                    }
                )
                .ignoresSafeArea()
            } else {
                SQColor.bg.ignoresSafeArea()
                SQSpinner().tint(SQColor.brandRed)
            }

            VStack(alignment: .leading, spacing: SQSpace.sm) {
                MapFloatingIconButton(systemImage: "xmark", label: "Annuler", identifier: "remap.cancel") { dismiss() }
                instructionCard
                Spacer(minLength: 0)
                if let errorMessage = model.errorMessage {
                    SQNotice(message: errorMessage, tone: .danger)
                        .accessibilityIdentifier("remap.error")
                    if let onReload, IdentificationCorrectionText.needsReload(errorMessage) {
                        GradientButton(IdentificationCorrectionText.reload, systemImage: "arrow.clockwise", style: .secondary) {
                            onReload()
                            dismiss()
                        }
                        .accessibilityIdentifier("remap.reloadMine")
                    }
                }
                selectionCard
            }
            .padding(SQSpace.md)
        }
        .task {
            await model.prepareCenter()
        }
        .onChangeCompat(of: model.done) { _, done in
            if done, let movedTo = model.movedTo { onDone(movedTo); dismiss() }
        }
    }

    /// Consigne et légende des couleurs des repères.
    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Text("Touche le bon site pour y déplacer \(model.item.nodeLabel).")
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.isLoading { SQSpinner().controlSize(.mini) }
            }
            HStack(spacing: SQSpace.md) {
                legendItem(SQColor.danger, "Site actuel")
                legendItem(SQColor.brandGreen, "Ton choix")
                legendItem(SQColor.labelSecondary, "Autres sites")
            }
            .font(SQType.micro)
            .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(SQSpace.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remap.instructions")
    }

    private func legendItem(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).lineLimit(1)
        }
    }

    /// « À 640 m de l'actuel · 3 validations le placent ici » : ce qu'on sait du choix, sans deviner.
    private func selectionFacts(_ site: AntennaSite) -> String? {
        var facts: [String] = []
        if !model.selectedIsCurrentSite, let meters = model.distanceFromCurrent(to: site) {
            facts.append(String(localized: "À \(SQUnits.distance(meters: meters)) de l’actuel"))
        }
        if model.isConflictTarget(site) {
            // `validations` compte des validations, pas des personnes : règle commune aux trois apps.
            switch model.item.conflictSiteValidations {
            case .some(1): facts.append(String(localized: "1 validation le place ici"))
            case let .some(count): facts.append(String(localized: "\(count) validations le placent ici"))
            case .none: facts.append(String(localized: "Plus validé ici"))
            }
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    @ViewBuilder
    private var selectionCard: some View {
        if let selected = model.selected {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(alignment: .top, spacing: SQSpace.sm) {
                    Circle().fill(SQColor.brandGreen).frame(width: 10, height: 10)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Site \(selected.siteId ?? selected.id)")
                            .font(SQFont.body(15, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                            .sqSingleLine()
                        if let address = selected.address, !address.isEmpty {
                            Text(address).font(SQType.caption).foregroundStyle(SQColor.labelSecondary).lineLimit(2)
                        }
                        if let facts = selectionFacts(selected) {
                            Text(facts)
                                .font(SQType.caption)
                                .monospacedDigit()
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("remap.facts")
                        }
                    }
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Désélectionner", identifier: "remap.deselect") {
                        model.selected = nil
                    }
                }
                if model.selectedIsCurrentSite {
                    Text("Ce nœud est déjà sur ce site.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GradientButton(
                    "Déplacer ici",
                    systemImage: "arrow.triangle.swap",
                    isBusy: model.isSubmitting,
                    style: .primary
                ) {
                    confirmsRemap = true
                }
                .disabled(model.selectedIsCurrentSite)
                .accessibilityIdentifier("remap.move")
                .confirmationDialog(
                    "Déplacer ce nœud ?",
                    isPresented: $confirmsRemap,
                    titleVisibility: .visible
                ) {
                    Button("Déplacer vers \(selected.siteId ?? selected.id)") {
                        Task { await model.confirm() }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Le nœud et toutes ses cellules quittent \(model.item.siteId) pour ce site. Ce choix est visible par tous.")
                }
            }
            .padding(SQSpace.md)
            .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
            .accessibilityIdentifier("remap.selection")
        }
    }
}

/// Carte MapKit de sélection d'antenne : marqueurs des sites de l'opérateur,
/// re-fetch par zone (debounce), tap → callback. Le site ACTUEL (à corriger) est
/// rouge, le site sélectionné vert, les autres gris.
private struct AntennaPickerMapView: UIViewRepresentable {
    let sites: [AntennaSite]
    let selectedId: String?
    let currentSiteId: String
    let initialCenter: CLLocationCoordinate2D
    let initialSpanMeters: CLLocationDistance
    let onRegionChange: (BoundingBox) -> Void
    let onSelect: (AntennaSite) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = true
        let region = MKCoordinateRegion(center: initialCenter, latitudinalMeters: initialSpanMeters, longitudinalMeters: initialSpanMeters)
        map.setRegion(region, animated: false)
        context.coordinator.didSetInitialRegion = true
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(annotationsOn: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: AntennaPickerMapView
        var didSetInitialRegion = false
        private var annotationsById: [String: AntennaPin] = [:]
        private var regionDebounce: Task<Void, Never>?

        init(_ parent: AntennaPickerMapView) { self.parent = parent }

        func sync(annotationsOn map: MKMapView) {
            let desired = Dictionary(parent.sites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Retraits
            for (id, pin) in annotationsById where desired[id] == nil {
                map.removeAnnotation(pin)
                annotationsById[id] = nil
            }
            // Ajouts
            for (id, site) in desired where annotationsById[id] == nil {
                let pin = AntennaPin(site: site, isCurrent: site.siteId == parent.currentSiteId || id == parent.currentSiteId)
                annotationsById[id] = pin
                map.addAnnotation(pin)
            }
            // Rafraîchit les teintes (sélection/courant) sans recréer
            for (id, pin) in annotationsById {
                if let view = map.view(for: pin) as? MKMarkerAnnotationView {
                    view.markerTintColor = self.tint(for: id)
                    view.alpha = pin.isCurrent ? 0.55 : 1
                }
            }
        }

        private func tint(for id: String) -> UIColor {
            let site = annotationsById[id]?.site
            if site?.siteId == parent.currentSiteId || id == parent.currentSiteId { return UIColor(SQColor.danger) }
            if id == parent.selectedId { return UIColor(SQColor.brandGreen) }
            // Gris neutre : la teinte de marque se confondait avec le rouge du site actuel.
            return UIColor(SQColor.labelSecondary)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard didSetInitialRegion else { return }
            let r = mapView.region
            let bbox = BoundingBox(
                north: r.center.latitude + r.span.latitudeDelta / 2,
                south: r.center.latitude - r.span.latitudeDelta / 2,
                east: r.center.longitude + r.span.longitudeDelta / 2,
                west: r.center.longitude - r.span.longitudeDelta / 2
            )
            regionDebounce?.cancel()
            regionDebounce = Task { [parent] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                parent.onRegionChange(bbox)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? AntennaPin else { return nil }
            let id = "antenna-pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = tint(for: pin.site.id)
            // Le support actuel est estompé et nommé « Actuel » : on ne le choisit pas.
            view.alpha = pin.isCurrent ? 0.55 : 1
            view.titleVisibility = pin.isCurrent ? .visible : .adaptive
            view.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
            view.clusteringIdentifier = "antenna"
            view.displayPriority = .defaultHigh
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let pin = view.annotation as? AntennaPin {
                parent.onSelect(pin.site)
                mapView.deselectAnnotation(pin, animated: true)
                sync(annotationsOn: mapView)
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                // Zoom sur le cluster pour l'éclater.
                let region = MKCoordinateRegion(center: cluster.coordinate,
                                                latitudinalMeters: 900, longitudinalMeters: 900)
                mapView.setRegion(region, animated: true)
            }
        }
    }
}

private final class AntennaPin: NSObject, MKAnnotation {
    let site: AntennaSite
    let isCurrent: Bool
    init(site: AntennaSite, isCurrent: Bool) {
        self.site = site
        self.isCurrent = isCurrent
    }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: site.latitude ?? 0, longitude: site.longitude ?? 0)
    }
    var title: String? { isCurrent ? String(localized: "Actuel") : site.siteId ?? site.id }
    var subtitle: String? { isCurrent ? nil : site.address }
}
