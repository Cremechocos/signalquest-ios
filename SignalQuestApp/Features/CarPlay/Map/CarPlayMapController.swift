import CarPlay
import MapKit
import UIKit

/// La carte affichée dans la fenêtre du véhicule.
///
/// C'est la SEULE surface CarPlay dont nous maîtrisons vraiment le rendu : le
/// `CPMapTemplate` se superpose à cette vue mais ne la dessine pas. D'où le soin
/// mis à réutiliser les composants de la carte iPhone — `SQMapKitAnnotation`,
/// `SQMapKitMarkerView`, `SQMapKitDotsOverlay`, `MapBackdrop` — plutôt que de
/// redessiner des marqueurs qui ressembleraient « à peu près » aux siens.
///
/// Volontairement plus simple que le `Coordinator` de `MapKitMapView` : pas
/// d'amis animés, pas de vignettes photo, pas de bindings SwiftUI. Ce sont
/// justement les parties qui portent l'essentiel de la complexité là-bas, et
/// elles n'ont pas de sens au volant.
@MainActor
final class CarPlayMapController: UIViewController, MKMapViewDelegate {
    let mapView = MKMapView()

    /// Appelé quand l'utilisateur (ou le suivi GPS) a fini de déplacer la carte.
    var onRegionChange: ((MapBounds, Double) -> Void)?

    /// Appelé au tap sur un marqueur. Ne se déclenche que sur les véhicules à
    /// écran tactile : ailleurs, la liste « Autour de toi » est le seul chemin
    /// vers les fiches.
    var onSelect: ((MapAnnotationPayload) -> Void)?

    private var annotationsById: [String: SQMapKitAnnotation] = [:]
    private var payloadsById: [String: MapAnnotationPayload] = [:]
    private var coverageOverlay: SQMapKitDotsOverlay?
    private var speedtestOverlay: SQMapKitDotsOverlay?
    private var appliedBackdrop: MapBackdrop?

    var currentZoom: Double {
        SQMapProjection.zoom(forRegion: mapView.region, width: effectiveWidth)
    }

    private var effectiveWidth: CGFloat {
        mapView.bounds.width > 0 ? mapView.bounds.width : SQMapProjection.referenceWidth
    }

    override func loadView() {
        view = mapView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        // Rotation et inclinaison désactivées : au volant, une carte qui pivote
        // sous les doigts fait perdre le nord — au sens propre — et les lobes
        // d'azimut ne se lisent plus par rapport à la route.
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        // À enregistrer explicitement : sans cela, `dequeueReusableAnnotationView`
        // lève au lieu de renvoyer nil, et la carte reste vide sans erreur claire.
        mapView.register(SQMapKitMarkerView.self,
                         forAnnotationViewWithReuseIdentifier: SQMapKitMarkerView.reuseID)
        applyBackdrop(MapBackdrop.current())
    }

    // MARK: - Fond de carte

    func applyBackdrop(_ backdrop: MapBackdrop) {
        guard backdrop != appliedBackdrop else { return }
        appliedBackdrop = backdrop
        switch backdrop.mapKitKind {
        case .imagery:
            mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        default:
            // Les fonds raster (Carto, OSM, topo) de l'iPhone ne sont pas repris :
            // au volant, on privilégie le fond Apple, lisible et déjà en cache.
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = configuration
        }
    }

    // MARK: - Annotations

    /// Applique un jeu de marqueurs par différence, pour ne pas recréer des
    /// annotations qui n'ont pas changé : recréer fait clignoter la carte et
    /// relance le chargement asynchrone des vues à chaque rafraîchissement.
    func apply(payloads: [MapAnnotationPayload]) {
        var incoming: [String: MapAnnotationPayload] = [:]
        incoming.reserveCapacity(payloads.count)
        for payload in payloads { incoming[payload.id] = payload }

        var toRemove: [SQMapKitAnnotation] = []
        for (id, annotation) in annotationsById {
            guard let updated = incoming[id] else {
                toRemove.append(annotation)
                annotationsById[id] = nil
                payloadsById[id] = nil
                continue
            }
            guard updated != payloadsById[id] else { continue }
            toRemove.append(annotation)
            annotationsById[id] = nil
            payloadsById[id] = nil
        }
        if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }

        var toAdd: [SQMapKitAnnotation] = []
        for payload in payloads where annotationsById[payload.id] == nil {
            let annotation = SQMapKitAnnotation(payload: payload)
            annotationsById[payload.id] = annotation
            payloadsById[payload.id] = payload
            toAdd.append(annotation)
        }
        if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }
    }

    func payload(for annotation: MKAnnotation) -> MapAnnotationPayload? {
        (annotation as? SQMapKitAnnotation)?.payload
    }

    // MARK: - Couches denses

    func setCoverage(_ features: [CoverageHeatFeature]) {
        if let existing = coverageOverlay { mapView.removeOverlay(existing); coverageOverlay = nil }
        guard !features.isEmpty else { return }
        let dots = features.map { feature -> SQMapKitDotsOverlay.Dot in
            let alpha: CGFloat = feature.dimmed ? 0.32 : 0.78
            return .init(point: MKMapPoint(feature.coordinate),
                         color: SQNetworkColors.uiColor(feature.colorHex).withAlphaComponent(alpha).cgColor)
        }
        let overlay = SQMapKitDotsOverlay(dots: dots)
        coverageOverlay = overlay
        mapView.addOverlay(overlay, level: .aboveLabels)
    }

    func setSpeedtests(_ features: [SpeedtestFeature]) {
        if let existing = speedtestOverlay { mapView.removeOverlay(existing); speedtestOverlay = nil }
        guard !features.isEmpty else { return }
        let dots = features.map { feature -> SQMapKitDotsOverlay.Dot in
            .init(point: MKMapPoint(feature.coordinate),
                  color: SQNetworkColors.speedUIColor(feature.downloadMbps).withAlphaComponent(0.9).cgColor)
        }
        let overlay = SQMapKitDotsOverlay(dots: dots)
        speedtestOverlay = overlay
        mapView.addOverlay(overlay, level: .aboveLabels)
    }

    // MARK: - Itinéraire

    private var routeOverlay: MKPolyline?

    /// Dessine l'itinéraire SOUS les marqueurs : c'est le seul intérêt de guider
    /// depuis notre carte plutôt que de passer la main à Plan — les antennes et
    /// leurs lobes restent visibles par-dessus la route.
    func showRoute(_ coordinates: [CLLocationCoordinate2D]) {
        clearRoute()
        guard coordinates.count > 1 else { return }
        let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        routeOverlay = overlay
        mapView.addOverlay(overlay, level: .aboveRoads)
    }

    func clearRoute() {
        if let routeOverlay { mapView.removeOverlay(routeOverlay) }
        routeOverlay = nil
    }

    // MARK: - Caméra

    func recenterOnUser() {
        mapView.userTrackingMode = .follow
    }

    /// Cadre sur un point précis. Coupe le suivi GPS au passage : sans cela, le
    /// prochain fix ramènerait aussitôt la carte sur le véhicule et le site
    /// qu'on voulait regarder disparaîtrait de l'écran.
    func center(on coordinate: CLLocationCoordinate2D) {
        mapView.userTrackingMode = .none
        mapView.setRegion(
            MKCoordinateRegion(center: coordinate,
                               span: SQMapProjection.span(forZoom: 15, width: effectiveWidth)),
            animated: true
        )
    }

    func setZoom(_ zoom: Double, animated: Bool = true) {
        let clamped = min(max(zoom, 3), 18)
        let region = MKCoordinateRegion(center: mapView.centerCoordinate,
                                        span: SQMapProjection.span(forZoom: clamped, width: effectiveWidth))
        mapView.setRegion(region, animated: animated)
    }

    func zoomIn() { setZoom(currentZoom + 1) }
    func zoomOut() { setZoom(currentZoom - 1) }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        onRegionChange?(SQMapProjection.bounds(of: mapView.region), currentZoom)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let dots = overlay as? SQMapKitDotsOverlay { return SQMapKitDotsRenderer(overlay: dots) }
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            // Épais et à la couleur de marque : le tracé doit se distinguer des
            // routes du fond de carte d'un seul coup d'œil.
            renderer.strokeColor = UIColor(SQColor.brandRed).withAlphaComponent(0.85)
            renderer.lineWidth = 7
            renderer.lineCap = .round
            return renderer
        }
        if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let sq = view.annotation as? SQMapKitAnnotation else { return }
        // Désélectionner tout de suite : sans cela, retoucher le même marqueur
        // après avoir fermé sa fiche ne redéclenche rien — il est resté
        // sélectionné et MapKit n'émet pas deux fois l'événement.
        mapView.deselectAnnotation(view.annotation, animated: false)
        onSelect?(sq.payload)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        // Position de l'utilisateur : on laisse MapKit poser son marqueur natif.
        guard let sq = annotation as? SQMapKitAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: SQMapKitMarkerView.reuseID, for: annotation) as? SQMapKitMarkerView
        view?.annotation = annotation
        view?.canShowCallout = false
        view?.apply(sq.payload)
        return view
    }
}
