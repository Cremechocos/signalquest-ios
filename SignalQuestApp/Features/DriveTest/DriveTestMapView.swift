import SwiftUI
import MapKit
import CoreLocation

/// Mini-carte MapKit du mode Drive Test (Apple Plan natif) : puck utilisateur (suivi),
/// antennes proches, cônes de secteur de l'antenne la plus proche (vert = dans le lobe,
/// orange = hors lobe), trace du parcours, couverture temps réel (par génération) et
/// points speedtest tappables (par débit).
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

    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.applePlan.rawValue
    private var backdrop: MapBackdrop { MapBackdrop(rawValue: backdropRaw) ?? .applePlan }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectSite: onSelectSite, onSelectSpeedtest: onSelectSpeedtest) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        map.pointOfInterestFilter = .excludingAll
        context.coordinator.applyBackdrop(backdrop, on: map)
        map.register(DriveAntennaMarkerView.self, forAnnotationViewWithReuseIdentifier: DriveAntennaMarkerView.reuseID)
        map.register(DriveSpeedtestMarkerView.self, forAnnotationViewWithReuseIdentifier: DriveSpeedtestMarkerView.reuseID)
        if let userLocation {
            map.setRegion(MKCoordinateRegion(center: userLocation, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.applyBackdrop(backdrop, on: map)
        context.coordinator.sync(
            antennas: antennas, trace: trace, coverageTrail: coverageTrail, speedtestTrail: speedtestTrail,
            highlightedSiteId: highlightedSiteId, userLocation: userLocation,
            operatorPalette: operatorPalette, displayedKey: displayedOperatorKey, on: map
        )
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        private var siteAnnotations: [DriveAntennaAnnotation] = []
        private var speedtestAnnotations: [DriveSpeedtestAnnotation] = []
        private var conePolygons: [MKPolygon] = []
        private var coneInSector: [ObjectIdentifier: Bool] = [:]
        private var tracePolyline: MKPolyline?
        private var coverageOverlay: DriveDotsOverlay?
        private var lastAntennaSig = 0
        private var lastConeSig = ""
        private var lastTraceCount = -1
        private var lastSpeedtestCount = -1
        private var coverageCount = -1
        private var appliedBackdrop: MapBackdrop?
        private var tileOverlay: MKTileOverlay?
        private let onSelectSite: (AntennaSite) -> Void
        private let onSelectSpeedtest: (DriveSpeedtestPoint) -> Void

        init(onSelectSite: @escaping (AntennaSite) -> Void, onSelectSpeedtest: @escaping (DriveSpeedtestPoint) -> Void) {
            self.onSelectSite = onSelectSite
            self.onSelectSpeedtest = onSelectSpeedtest
            super.init()
        }

        func applyBackdrop(_ backdrop: MapBackdrop, on map: MKMapView) {
            guard backdrop != appliedBackdrop else { return }
            appliedBackdrop = backdrop
            if let old = tileOverlay { map.removeOverlay(old); tileOverlay = nil }
            switch backdrop.mapKitKind {
            case .applePlan:
                let c = MKStandardMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
            case .imagery:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .raster(let template, let maxZoom):
                let c = MKStandardMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
                let o = MKTileOverlay(urlTemplate: template); o.canReplaceMapContent = true; o.maximumZ = maxZoom
                map.insertOverlay(o, at: 0, level: .aboveLabels); tileOverlay = o
            }
        }

        func sync(antennas: [AntennaSite], trace: [CLLocationCoordinate2D], coverageTrail: [DriveCoveragePoint], speedtestTrail: [DriveSpeedtestPoint], highlightedSiteId: String?, userLocation: CLLocationCoordinate2D?, operatorPalette: [String: UIColor], displayedKey: String?, on map: MKMapView) {
            syncSites(antennas, operatorPalette: operatorPalette, displayedKey: displayedKey, on: map)
            syncCones(antennas: antennas, highlightedSiteId: highlightedSiteId, userLocation: userLocation, on: map)
            syncTrace(trace, on: map)
            syncCoverage(coverageTrail, on: map)
            syncSpeedtests(speedtestTrail, on: map)
        }

        // MARK: Antennes
        private func syncSites(_ antennas: [AntennaSite], operatorPalette: [String: UIColor], displayedKey: String?, on map: MKMapView) {
            var hasher = Hasher()
            hasher.combine(antennas.count); hasher.combine(displayedKey ?? "ALL")
            for s in antennas.prefix(400) { hasher.combine(s.id) }
            let sig = hasher.finalize()
            guard sig != lastAntennaSig else { return }
            lastAntennaSig = sig
            if !siteAnnotations.isEmpty { map.removeAnnotations(siteAnnotations) }
            siteAnnotations = antennas.compactMap { site -> DriveAntennaAnnotation? in
                guard site.hasValidCoordinate, let lat = site.latitude, let lon = site.longitude else { return nil }
                let key = (displayedKey ?? site.operators.first ?? "").uppercased()
                let color = operatorPalette[key] ?? UIColor(SQColor.brandRed)
                return DriveAntennaAnnotation(site: site, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), color: color)
            }
            if !siteAnnotations.isEmpty { map.addAnnotations(siteAnnotations) }
        }

        // MARK: Cônes de secteur de l'antenne la plus proche
        private func syncCones(antennas: [AntennaSite], highlightedSiteId: String?, userLocation: CLLocationCoordinate2D?, on map: MKMapView) {
            var sig = highlightedSiteId ?? "none"
            if let u = userLocation { sig += "@\(Int(u.latitude * 5000))/\(Int(u.longitude * 5000))" }
            guard sig != lastConeSig else { return }
            lastConeSig = sig
            if !conePolygons.isEmpty { map.removeOverlays(conePolygons); conePolygons.removeAll() }
            coneInSector.removeAll(keepingCapacity: true)
            guard let highlightedSiteId, let user = userLocation,
                  let site = antennas.first(where: { $0.id == highlightedSiteId }),
                  site.hasValidCoordinate, let lat = site.latitude, let lon = site.longitude, !site.azimuths.isEmpty else { return }
            let apex = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            for az in site.azimuths {
                var coords = AntennaSectorGeometry.sectorConeCoordinates(apex: apex, azimuth: az, lengthMeters: 320)
                guard coords.count >= 3 else { continue }
                let poly = MKPolygon(coordinates: &coords, count: coords.count)
                coneInSector[ObjectIdentifier(poly)] = AntennaSectorGeometry.isWithinSector(antenna: apex, user: user, azimuth: az)
                conePolygons.append(poly)
            }
            if !conePolygons.isEmpty { map.addOverlays(conePolygons, level: .aboveRoads) }
        }

        // MARK: Trace du parcours
        private func syncTrace(_ trace: [CLLocationCoordinate2D], on map: MKMapView) {
            guard trace.count != lastTraceCount else { return }
            lastTraceCount = trace.count
            if let t = tracePolyline { map.removeOverlay(t); tracePolyline = nil }
            guard trace.count >= 2 else { return }
            var coords = trace
            let line = MKPolyline(coordinates: &coords, count: coords.count)
            tracePolyline = line
            map.addOverlay(line, level: .aboveLabels)
        }

        // MARK: Couverture temps réel (overlay Core Graphics, coloré par génération)
        private func syncCoverage(_ trail: [DriveCoveragePoint], on map: MKMapView) {
            guard trail.count != coverageCount else { return }
            coverageCount = trail.count
            if let old = coverageOverlay { map.removeOverlay(old); coverageOverlay = nil }
            guard !trail.isEmpty else { return }
            let dots = trail.map { DriveDotsOverlay.Dot(point: MKMapPoint($0.coordinate), color: Self.generationColor(Self.generationKey($0.generation)).cgColor) }
            let o = DriveDotsOverlay(dots: dots)
            coverageOverlay = o
            map.addOverlay(o, level: .aboveRoads)
        }

        private static func generationKey(_ tech: String?) -> String {
            let t = (tech ?? "").uppercased()
            if t.contains("5G") || t.contains("NR") { return "5g" }
            if t.contains("4G") || t.contains("LTE") { return "4g" }
            if t.contains("3G") || t.contains("UMTS") || t.contains("HSPA") || t.contains("WCDMA") { return "3g" }
            if t.contains("2G") || t.contains("GSM") || t.contains("EDGE") || t.contains("GPRS") { return "2g" }
            return "none"
        }
        private static func generationColor(_ key: String) -> UIColor {
            let hex: UInt32
            switch key {
            case "5g": hex = 0x8B5CF6
            case "4g": hex = 0x3B82F6
            case "3g": hex = 0x14B8A6
            case "2g": hex = 0xF59E0B
            default: hex = 0x94A3B8
            }
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }

        // MARK: Speedtests (annotations tappables colorées par débit)
        private func syncSpeedtests(_ points: [DriveSpeedtestPoint], on map: MKMapView) {
            guard points.count != lastSpeedtestCount else { return }
            lastSpeedtestCount = points.count
            if !speedtestAnnotations.isEmpty { map.removeAnnotations(speedtestAnnotations) }
            speedtestAnnotations = points.map { DriveSpeedtestAnnotation(point: $0, coordinate: $0.coordinate, color: Self.speedColor($0.result.downloadAverageMbps)) }
            if !speedtestAnnotations.isEmpty { map.addAnnotations(speedtestAnnotations) }
        }
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
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }

        // MARK: Délégué
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
            if let dots = overlay as? DriveDotsOverlay { return DriveDotsRenderer(overlay: dots) }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor(SQColor.brandOrange).withAlphaComponent(0.95)
                r.lineWidth = 4; r.lineJoin = .round; r.lineCap = .round
                return r
            }
            if let poly = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                let color: UIColor = (coneInSector[ObjectIdentifier(poly)] ?? false) ? .systemGreen : .systemOrange
                r.fillColor = color.withAlphaComponent(0.20)
                r.strokeColor = color.withAlphaComponent(0.6)
                r.lineWidth = 1
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let st = annotation as? DriveSpeedtestAnnotation {
                let v = map.dequeueReusableAnnotationView(withIdentifier: DriveSpeedtestMarkerView.reuseID, for: annotation) as? DriveSpeedtestMarkerView
                    ?? DriveSpeedtestMarkerView(annotation: annotation, reuseIdentifier: DriveSpeedtestMarkerView.reuseID)
                v.annotation = annotation; v.canShowCallout = false; v.apply(color: st.color)
                return v
            }
            if let ant = annotation as? DriveAntennaAnnotation {
                let v = map.dequeueReusableAnnotationView(withIdentifier: DriveAntennaMarkerView.reuseID, for: annotation) as? DriveAntennaMarkerView
                    ?? DriveAntennaMarkerView(annotation: annotation, reuseIdentifier: DriveAntennaMarkerView.reuseID)
                v.annotation = annotation; v.canShowCallout = false; v.apply(color: ant.color)
                return v
            }
            return nil // position utilisateur → puck par défaut
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let st = view.annotation as? DriveSpeedtestAnnotation { onSelectSpeedtest(st.point) }
            else if let ant = view.annotation as? DriveAntennaAnnotation { onSelectSite(ant.site) }
            map.deselectAnnotation(view.annotation, animated: false)
        }
    }
}

/// Annotation antenne portant le `AntennaSite` (détails au tap).
final class DriveAntennaAnnotation: NSObject, MKAnnotation {
    let site: AntennaSite
    let coordinate: CLLocationCoordinate2D
    let color: UIColor
    init(site: AntennaSite, coordinate: CLLocationCoordinate2D, color: UIColor) {
        self.site = site; self.coordinate = coordinate; self.color = color
    }
}

/// Annotation d'un point speedtest portant son résultat (détails au tap).
final class DriveSpeedtestAnnotation: NSObject, MKAnnotation {
    let point: DriveSpeedtestPoint
    let coordinate: CLLocationCoordinate2D
    let color: UIColor
    init(point: DriveSpeedtestPoint, coordinate: CLLocationCoordinate2D, color: UIColor) {
        self.point = point; self.coordinate = coordinate; self.color = color
    }
}

/// Marqueur d'antenne minimal (petit disque coloré par opérateur).
final class DriveAntennaMarkerView: MKAnnotationView {
    static let reuseID = "drivetest-antenna"
    private let dot = UIView()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 14, height: 14)
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
    required init?(coder: NSCoder) { nil }
    func apply(color: UIColor) { dot.backgroundColor = color }
}

/// Marqueur speedtest : losange coloré par débit (distinct des pastilles antennes).
final class DriveSpeedtestMarkerView: MKAnnotationView {
    static let reuseID = "drivetest-speedtest"
    private let diamond = UIView()
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 16, height: 16)
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
    required init?(coder: NSCoder) { nil }
    func apply(color: UIColor) { diamond.backgroundColor = color }
}

/// Overlay « nuage de points » dense (couverture trail) — passe Core Graphics + culling.
final class DriveDotsOverlay: NSObject, MKOverlay {
    struct Dot { let point: MKMapPoint; let color: CGColor }
    let dots: [Dot]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    init(dots: [Dot]) {
        self.dots = dots
        var rect = MKMapRect.null
        for d in dots { rect = rect.union(MKMapRect(origin: d.point, size: MKMapSize(width: 0.5, height: 0.5))) }
        let bounding = rect.isNull ? MKMapRect.world : rect.insetBy(dx: -rect.size.width * 0.1 - 50, dy: -rect.size.height * 0.1 - 50)
        boundingMapRect = bounding
        coordinate = MKMapPoint(x: bounding.midX, y: bounding.midY).coordinate
    }
}

final class DriveDotsRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? DriveDotsOverlay else { return }
        let radius = max(2.0, 4.0 / zoomScale)
        let pad = radius * 3
        let cull = mapRect.insetBy(dx: -pad, dy: -pad)
        context.setLineWidth(radius * 0.4)
        let stroke = UIColor.white.withAlphaComponent(0.7).cgColor
        for dot in overlay.dots {
            guard cull.contains(dot.point) else { continue }
            let p = point(for: dot.point)
            let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(dot.color)
            context.fillEllipse(in: r)
            context.setStrokeColor(stroke)
            context.strokeEllipse(in: r)
        }
    }
}
