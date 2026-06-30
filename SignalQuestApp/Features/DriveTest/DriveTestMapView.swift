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
    /// Points de couverture capturés, affichés EN TEMPS RÉEL et colorés par génération.
    var coverageTrail: [DriveCoveragePoint] = []
    /// Points speedtest capturés, colorés par débit et tappables (→ détails).
    var speedtestTrail: [DriveSpeedtestPoint] = []
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
    /// Tap sur un point speedtest → ouvre la feuille de détails.
    var onSelectSpeedtest: (DriveSpeedtestPoint) -> Void = { _ in }

    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.carto.rawValue
    private var backdrop: MapBackdrop { MapBackdrop(rawValue: backdropRaw) ?? .carto }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectSite: onSelectSite, onSelectSpeedtest: onSelectSpeedtest) }

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
            coverageTrail: coverageTrail,
            speedtestTrail: speedtestTrail,
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
        /// Couverture temps réel : dernier état + ids des couches GPU (1 par génération).
        private var latestCoverageTrail: [DriveCoveragePoint] = []
        private var coverageTrailCount = -1
        private var coverageGenLayerIds: Set<String> = []
        private var speedtestAnnotations: [DriveSpeedtestAnnotation] = []
        private var lastSpeedtestCount = -1
        /// Statut « dans le lobe » par cône (clé = identité de l'objet polygone).
        private var coneInSector: [ObjectIdentifier: Bool] = [:]
        private let onSelectSite: (AntennaSite) -> Void
        private let onSelectSpeedtest: (DriveSpeedtestPoint) -> Void

        init(onSelectSite: @escaping (AntennaSite) -> Void,
             onSelectSpeedtest: @escaping (DriveSpeedtestPoint) -> Void) {
            self.onSelectSite = onSelectSite
            self.onSelectSpeedtest = onSelectSpeedtest
            super.init()
        }

        func sync(
            antennas: [AntennaSite],
            trace: [CLLocationCoordinate2D],
            coverageTrail: [DriveCoveragePoint],
            speedtestTrail: [DriveSpeedtestPoint],
            highlightedSiteId: String?,
            userLocation: CLLocationCoordinate2D?,
            operatorPalette: [String: UIColor],
            displayedKey: String?,
            on mapView: MLNMapView
        ) {
            latestCoverageTrail = coverageTrail
            syncSites(antennas, operatorPalette: operatorPalette, displayedKey: displayedKey, on: mapView)
            syncCones(antennas: antennas, highlightedSiteId: highlightedSiteId, userLocation: userLocation, on: mapView)
            syncTrace(trace, on: mapView)
            syncCoverageTrail(coverageTrail, on: mapView)
            syncSpeedtests(speedtestTrail, on: mapView)
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

        // MARK: Couverture temps réel (points colorés par génération)

        /// Affiche les points de couverture capturés, colorés par génération. Couche GPU
        /// (une source + une couche cercle par génération) → tient des centaines de
        /// points sans coût d'annotations. Diff par compte pour éviter les rebuilds.
        private func syncCoverageTrail(_ trail: [DriveCoveragePoint], on mapView: MLNMapView) {
            guard trail.count != coverageTrailCount else { return }
            coverageTrailCount = trail.count
            guard let style = mapView.style else { return }
            let byGen = Dictionary(grouping: trail, by: { Self.generationKey($0.generation) })
            var active = Set<String>()
            for (key, points) in byGen {
                let sourceId = "sq-dt-cov-source-\(key)"
                let layerId = "sq-dt-cov-layer-\(key)"
                active.insert(layerId)
                let features = points.map { p -> MLNPointFeature in
                    let f = MLNPointFeature(); f.coordinate = p.coordinate; return f
                }
                if let source = style.source(withIdentifier: sourceId) as? MLNShapeSource {
                    source.shape = MLNShapeCollectionFeature(shapes: features)
                } else {
                    let source = MLNShapeSource(identifier: sourceId, features: features, options: nil)
                    style.addSource(source)
                    let layer = MLNCircleStyleLayer(identifier: layerId, source: source)
                    layer.circleColor = NSExpression(forConstantValue: Self.generationColor(key))
                    layer.circleRadius = NSExpression(forConstantValue: 4)
                    layer.circleOpacity = NSExpression(forConstantValue: 0.85)
                    layer.circleStrokeWidth = NSExpression(forConstantValue: 1)
                    layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.7))
                    style.addLayer(layer)
                }
                style.layer(withIdentifier: layerId)?.isVisible = !features.isEmpty
                coverageGenLayerIds.insert(layerId)
            }
            for layerId in coverageGenLayerIds where !active.contains(layerId) {
                style.layer(withIdentifier: layerId)?.isVisible = false
            }
        }

        private static func generationKey(_ tech: String?) -> String {
            let t = (tech ?? "").uppercased()
            if t.contains("5G") || t.contains("NR") { return "5g" }
            if t.contains("4G") || t.contains("LTE") { return "4g" }
            if t.contains("3G") || t.contains("UMTS") || t.contains("HSPA") || t.contains("WCDMA") { return "3g" }
            if t.contains("2G") || t.contains("GSM") || t.contains("EDGE") || t.contains("GPRS") { return "2g" }
            return "none"
        }

        /// Couleur par génération (alignée carte principale / « Mes mesures »).
        private static func generationColor(_ key: String) -> UIColor {
            let hex: UInt32
            switch key {
            case "5g": hex = 0x8B5CF6
            case "4g": hex = 0x3B82F6
            case "3g": hex = 0x14B8A6
            case "2g": hex = 0xF59E0B
            default: hex = 0x94A3B8
            }
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }

        // MARK: Speedtests (annotations tappables colorées par débit)

        /// Peu nombreux (1 par test) → annotations natives, donc tappables (→ détails).
        private func syncSpeedtests(_ points: [DriveSpeedtestPoint], on mapView: MLNMapView) {
            guard points.count != lastSpeedtestCount else { return }
            lastSpeedtestCount = points.count
            if !speedtestAnnotations.isEmpty { mapView.removeAnnotations(speedtestAnnotations) }
            let annotations = points.map { point in
                DriveSpeedtestAnnotation(
                    point: point,
                    coordinate: point.coordinate,
                    color: Self.speedColor(point.result.downloadAverageMbps)
                )
            }
            speedtestAnnotations = annotations
            if !annotations.isEmpty { mapView.addAnnotations(annotations) }
        }

        /// Couleur par débit descendant (échelle alignée web/Android, 7 paliers).
        private static func speedColor(_ mbps: Double) -> UIColor {
            let hex: UInt32
            switch mbps {
            case 1000...: hex = 0x3B82F6
            case 600..<1000: hex = 0x06B6D4
            case 300..<600: hex = 0x22C55E
            case 100..<300: hex = 0x84CC16
            case 30..<100: hex = 0xEAB308
            case 10..<30: hex = 0xF97316
            default: hex = 0xEF4444
            }
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }

        // MARK: Délégué — style des overlays

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Un rechargement de style (clair/sombre) efface sources & couches GPU :
            // on force la ré-application au prochain sync et on re-pose la couverture.
            lastAntennaSignature = 0
            lastConeSignature = ""
            lastTraceCount = -1
            lastSpeedtestCount = -1
            coverageTrailCount = -1
            coverageGenLayerIds.removeAll()
            syncCoverageTrail(latestCoverageTrail, on: mapView)
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            // Point speedtest : losange coloré par débit (tappable → détails).
            if let speedtest = annotation as? DriveSpeedtestAnnotation {
                let id = "drivetest-speedtest"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DriveSpeedtestMarkerView
                    ?? DriveSpeedtestMarkerView(reuseIdentifier: id)
                view.apply(color: speedtest.color)
                return view
            }
            // Points antennes (la polyline/les polygones sont rendus natifs).
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

        // Tap → détails (la session speedtest continue en fond).
        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            if let speedtest = annotation as? DriveSpeedtestAnnotation {
                onSelectSpeedtest(speedtest.point)
            } else if let antenna = annotation as? DriveTestAntennaAnnotation {
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

/// Annotation d'un point speedtest portant son résultat (détails au tap).
final class DriveSpeedtestAnnotation: MLNPointAnnotation {
    let point: DriveSpeedtestPoint
    let color: UIColor

    init(point: DriveSpeedtestPoint, coordinate: CLLocationCoordinate2D, color: UIColor) {
        self.point = point
        self.color = color
        super.init()
        self.coordinate = coordinate
    }

    required init?(coder: NSCoder) { nil }
}

/// Marqueur speedtest : losange coloré par débit (distinct des pastilles antennes).
final class DriveSpeedtestMarkerView: MLNAnnotationView {
    private let diamond = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        isOpaque = false
        backgroundColor = .clear
        diamond.frame = bounds
        diamond.layer.cornerRadius = 3
        diamond.layer.borderWidth = 2
        diamond.layer.borderColor = UIColor.white.cgColor
        diamond.transform = CGAffineTransform(rotationAngle: .pi / 4)
        diamond.layer.shadowColor = UIColor.black.cgColor
        diamond.layer.shadowOpacity = 0.25
        diamond.layer.shadowRadius = 3
        diamond.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        addSubview(diamond)
    }

    func apply(color: UIColor) {
        diamond.backgroundColor = color
    }

    required init?(coder: NSCoder) { nil }
}
#endif
