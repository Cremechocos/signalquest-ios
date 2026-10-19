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
    @Published var done = false

    let item: MyIdentification
    private let antennas: AntennasServicing
    private let identify: IdentifyServicing
    private let location: LocationService
    private var loadTask: Task<Void, Never>?

    init(item: MyIdentification, antennas: AntennasServicing, identify: IdentifyServicing, location: LocationService) {
        self.item = item
        self.antennas = antennas
        self.identify = identify
        self.location = location
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
            initialCenter = (await location.currentLocation(timeoutSeconds: 4))?.coordinate
                ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
            return
        }
        if let details = try? await antennas.details(id: item.siteId, market: market, operatorName: operatorName),
           let core = details.core, core.lat != 0 || core.lng != 0 {
            initialCenter = CLLocationCoordinate2D(latitude: core.lat, longitude: core.lng)
            return
        }
        if let loc = await location.currentLocation(timeoutSeconds: 4) {
            initialCenter = loc.coordinate
        } else {
            initialCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
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
            do {
                let list = try await antennas.list(bbox: bbox, market: market, operatorName: operatorName, technologies: [])
                guard !Task.isCancelled else { return }
                sites = list.filter(\.hasValidCoordinate)
                errorMessage = nil
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
            if result.success {
                Haptics.success()
                done = true
            } else {
                errorMessage = String(localized: "Le déplacement n'a pas abouti.")
                Haptics.error()
            }
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}

/// Ré-identifier un nœud eNB/gNB : l'utilisateur choisit le bon site sur la carte.
struct SiteRemapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SiteRemapViewModel
    let onDone: () -> Void
    /// Le déplacement est public et emporte toutes les cellules du nœud : il se
    /// confirme, comme le choix sur carte des Logs (AF-RAD-17).
    @State private var confirmsRemap = false

    init(item: MyIdentification, antennas: AntennasServicing, identify: IdentifyServicing, location: LocationService, onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SiteRemapViewModel(item: item, antennas: antennas, identify: identify, location: location))
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
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption).foregroundStyle(SQColor.onAccent)
                        .padding(.horizontal, SQSpace.md).padding(.vertical, SQSpace.sm)
                        .background(SQColor.danger, in: Capsule(style: .continuous))
                        .frame(maxWidth: .infinity)
                }
                selectionCard
            }
            .padding(SQSpace.md)
        }
        .task {
            await model.prepareCenter()
        }
        .onChangeCompat(of: model.done) { _, done in
            if done { onDone(); dismiss() }
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
                    }
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Désélectionner", identifier: "remap.deselect") {
                        model.selected = nil
                    }
                }
                GradientButton(
                    "Déplacer ici",
                    systemImage: "arrow.triangle.swap",
                    isBusy: model.isSubmitting,
                    style: .primary
                ) {
                    confirmsRemap = true
                }
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
    let onRegionChange: (BoundingBox) -> Void
    let onSelect: (AntennaSite) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = true
        let region = MKCoordinateRegion(center: initialCenter, latitudinalMeters: 2200, longitudinalMeters: 2200)
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
                let pin = AntennaPin(site: site)
                annotationsById[id] = pin
                map.addAnnotation(pin)
            }
            // Rafraîchit les teintes (sélection/courant) sans recréer
            for (id, pin) in annotationsById {
                if let view = map.view(for: pin) as? MKMarkerAnnotationView {
                    view.markerTintColor = self.tint(for: id)
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
    init(site: AntennaSite) { self.site = site }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: site.latitude ?? 0, longitude: site.longitude ?? 0)
    }
    var title: String? { site.siteId ?? site.id }
    var subtitle: String? { site.address }
}
