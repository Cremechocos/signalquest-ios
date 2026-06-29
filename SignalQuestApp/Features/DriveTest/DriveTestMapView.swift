#if canImport(MapLibre)
import SwiftUI
import MapLibre
import CoreLocation

/// Mini-carte MapLibre du mode Drive Test — calquée sur `ANFRMapLibreView` mais
/// dédiée au temps réel : puck utilisateur (suivi), antennes proches en points,
/// cônes de secteur de l'antenne la plus proche (vert = on est dans le lobe,
/// orange = hors lobe) et polyline de la trace du parcours.
struct DriveTestMapView: UIViewRepresentable {
    let antennas: [AntennaSite]
    let trace: [CLLocationCoordinate2D]
    let highlightedSiteId: String?
    let userLocation: CLLocationCoordinate2D?
    let colorScheme: ColorScheme
    /// Couleur (UIKit) par clé d'opérateur EN MAJUSCULES, pour colorer les marqueurs.
    var operatorPalette: [String: UIColor] = [:]
    /// Opérateur affiché : s'il est défini, tous les marqueurs prennent SA couleur ;
    /// sinon chaque marqueur est coloré selon `site.operators.first` (cas « tous »).
    var displayedOperatorKey: String?
    /// Tap sur une antenne → ouvre ses détails (la session speedtest n'est pas interrompue).
    var onSelectSite: (AntennaSite) -> Void = { _ in }

    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.carto.rawValue
    private var backdrop: MapBackdrop { MapBackdrop(rawValue: backdropRaw) ?? .carto }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectSite: onSelectSite) }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: backdrop.styleURL(dark: colorScheme == .dark))
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.tintColor = UIColor(SQColor.brandRed)
        if let userLocation {
            mapView.setCenter(userLocation, zoomLevel: 15, animated: false)
        }
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let expected = backdrop.styleURL(dark: colorScheme == .dark)
        if mapView.styleURL != expected { mapView.styleURL = expected }
        context.coordinator.sync(
            antennas: antennas,
            trace: trace,
            highlightedSiteId: highlightedSiteId,
            userLocation: userLocation,
            operatorPalette: operatorPalette,
            displayedKey: displayedOperatorKey,
            on: mapView
        )
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private var siteAnnotations: [MLNAnnotation] = []
        private var coneAnnotations: [MLNPolygon] = []
        private var traceAnnotation: MLNPolyline?
        private var lastAntennaSignature = 0
        private var lastConeSignature = ""
        private var lastTraceCount = -1
        /// Statut « dans le lobe » par cône (clé = identité de l'objet polygone).
        private var coneInSector: [ObjectIdentifier: Bool] = [:]
        private let onSelectSite: (AntennaSite) -> Void

        init(onSelectSite: @escaping (AntennaSite) -> Void) {
            self.onSelectSite = onSelectSite
            super.init()
        }

        func sync(
            antennas: [AntennaSite],
            trace: [CLLocationCoordinate2D],
            highlightedSiteId: String?,
            userLocation: CLLocationCoordinate2D?,
            operatorPalette: [String: UIColor],
            displayedKey: String?,
            on mapView: MLNMapView
        ) {
            syncSites(antennas, operatorPalette: operatorPalette, displayedKey: displayedKey, on: mapView)
            syncCones(antennas: antennas, highlightedSiteId: highlightedSiteId, userLocation: userLocation, on: mapView)
            syncTrace(trace, on: mapView)
        }

        // MARK: Antennes (points)

        private func syncSites(_ antennas: [AntennaSite], operatorPalette: [String: UIColor], displayedKey: String?, on mapView: MLNMapView) {
            var hasher = Hasher()
            hasher.combine(antennas.count)
            // La palette/opérateur affiché fait partie de la signature : changer
            // d'opérateur recolore les marqueurs même si les sites sont identiques.
            hasher.combine(displayedKey ?? "ALL")
            for site in antennas.prefix(400) { hasher.combine(site.id) }
            let signature = hasher.finalize()
            guard signature != lastAntennaSignature else { return }
            lastAntennaSignature = signature

            if !siteAnnotations.isEmpty { mapView.removeAnnotations(siteAnnotations) }
            let points: [MLNAnnotation] = antennas.compactMap { site -> MLNAnnotation? in
                guard site.hasValidCoordinate, let lat = site.latitude, let lon = site.longitude else { return nil }
                let key = (displayedKey ?? site.operators.first ?? "").uppercased()
                let color = operatorPalette[key] ?? UIColor(SQColor.brandRed)
                return DriveTestAntennaAnnotation(
                    site: site,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    dotColor: color
                )
            }
            siteAnnotations = points
            if !points.isEmpty { mapView.addAnnotations(points) }
        }

        // MARK: Cônes de secteur de l'antenne la plus proche

        private func syncCones(
            antennas: [AntennaSite],
            highlightedSiteId: String?,
            userLocation: CLLocationCoordinate2D?,
            on mapView: MLNMapView
        ) {
            // Re-trace uniquement si l'antenne ciblée ou la position bougent assez.
            var signature = highlightedSiteId ?? "none"
            if let userLocation {
                signature += "@\(Int(userLocation.latitude * 5000))/\(Int(userLocation.longitude * 5000))"
            }
            guard signature != lastConeSignature else { return }
            lastConeSignature = signature

            if !coneAnnotations.isEmpty { mapView.removeAnnotations(coneAnnotations) }
            coneAnnotations = []
            coneInSector.removeAll(keepingCapacity: true)

            guard let highlightedSiteId,
                  let user = userLocation,
                  let site = antennas.first(where: { $0.id == highlightedSiteId }),
                  site.hasValidCoordinate, let lat = site.latitude, let lon = site.longitude,
                  !site.azimuths.isEmpty else { return }

            let apex = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            for azimuth in site.azimuths {
                var coordinates = AntennaSectorGeometry.sectorConeCoordinates(
                    apex: apex, azimuth: azimuth, lengthMeters: 320
                )
                let polygon = MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
                coneInSector[ObjectIdentifier(polygon)] = AntennaSectorGeometry.isWithinSector(
                    antenna: apex, user: user, azimuth: azimuth
                )
                coneAnnotations.append(polygon)
            }
            if !coneAnnotations.isEmpty { mapView.addAnnotations(coneAnnotations) }
        }

        // MARK: Trace du parcours

        private func syncTrace(_ trace: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            guard trace.count != lastTraceCount else { return }
            lastTraceCount = trace.count
            if let traceAnnotation { mapView.removeAnnotation(traceAnnotation) }
            guard trace.count >= 2 else { traceAnnotation = nil; return }
            var coordinates = trace
            let line = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
            traceAnnotation = line
            mapView.addAnnotation(line)
        }

        // MARK: Délégué — style des overlays

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            // Points antennes uniquement (la polyline/les polygones sont rendus natifs).
            guard annotation is MLNPointAnnotation else { return nil }
            let identifier = "drivetest-antenna"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? DriveTestMarkerView
                ?? DriveTestMarkerView(reuseIdentifier: identifier)
            // Vue réutilisée → on (ré)applique la couleur de CETTE annotation.
            if let antenna = annotation as? DriveTestAntennaAnnotation {
                view.apply(color: antenna.dotColor)
            }
            return view
        }

        func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
            (coneInSector[ObjectIdentifier(annotation)] ?? false) ? .systemGreen : .systemOrange
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation is MLNPolyline { return UIColor(SQColor.brandOrange) }
            return (coneInSector[ObjectIdentifier(annotation)] ?? false) ? .systemGreen : .systemOrange
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            annotation is MLNPolyline ? 0.95 : 0.20
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            4
        }

        // Pas de bulle native : on présente notre propre feuille de détails.
        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            false
        }

        // Tap sur une antenne → détails (la session speedtest continue en fond).
        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            if let antenna = annotation as? DriveTestAntennaAnnotation {
                onSelectSite(antenna.site)
            }
            mapView.deselectAnnotation(annotation, animated: false)
        }
    }
}

/// Annotation antenne portant le `AntennaSite` pour la sélection (détails au tap).
final class DriveTestAntennaAnnotation: MLNPointAnnotation {
    let site: AntennaSite
    let dotColor: UIColor

    init(site: AntennaSite, coordinate: CLLocationCoordinate2D, dotColor: UIColor) {
        self.site = site
        self.dotColor = dotColor
        super.init()
        self.coordinate = coordinate
    }

    required init?(coder: NSCoder) { nil }
}

/// Marqueur d'antenne minimal (petit disque) pour la mini-carte Drive Test.
final class DriveTestMarkerView: MLNAnnotationView {
    private let dot = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        isOpaque = false
        backgroundColor = .clear
        dot.frame = bounds
        dot.layer.cornerRadius = 7
        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.white.cgColor
        dot.backgroundColor = UIColor(SQColor.brandRed)
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.25
        dot.layer.shadowRadius = 3
        dot.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        addSubview(dot)
    }

    /// Recolore le disque selon l'opérateur de l'antenne (vue réutilisée).
    func apply(color: UIColor) {
        dot.backgroundColor = color
    }

    required init?(coder: NSCoder) { nil }
}
#endif
