import SwiftUI
import MapKit

/// Tracé d'une session sur MKMapView (API UIKit, non dépréciée, iOS 13→27) :
/// nuage de points de mesure colorés par RSRP (overlay Core Graphics, performant
/// même pour des milliers de points), tracé du parcours (drive-test) + antennes
/// desservantes colorées par état (vert identifiée / orange hypothèse / gris
/// proximité).
struct SessionTraceMapView: UIViewRepresentable {
    let points: [CoverageSessionPoint]
    let antennas: [ServingAntenna]
    var speedtests: [SessionSpeedtest] = []
    var drawPath: Bool = false
    /// Mode de coloration des points : par signal (RSRP) ou par génération (carte couverture).
    var coloring: SessionPointColoring = .rsrp

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        let validPoints = points.filter(\.hasValidCoordinate)
        let coords = validPoints.map(\.coordinate)

        // Tracé du parcours (drive-test uniquement, sinon nuage de points seul).
        if drawPath && coords.count >= 2 {
            map.addOverlay(MKPolyline(coordinates: coords, count: coords.count), level: .aboveRoads)
        }
        // Nuage de points coloré par RSRP.
        if !validPoints.isEmpty {
            map.addOverlay(SessionPointsOverlay(points: validPoints, coloring: coloring), level: .aboveLabels)
        }
        // Antennes desservantes géolocalisées.
        let locatedAntennas = antennas.filter(\.hasValidCoordinate)
        map.addAnnotations(locatedAntennas.map(ServingAntennaAnnotation.init))

        // Speedtests géolocalisés (marqueur « débit » tappable).
        let locatedSpeedtests = speedtests.compactMap { st -> SessionSpeedtestAnnotation? in
            st.coordinate == nil ? nil : SessionSpeedtestAnnotation(st)
        }
        map.addAnnotations(locatedSpeedtests)

        var rect = MKMapRect.null
        for coord in coords {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coord), size: MKMapSize(width: 1, height: 1)))
        }
        for antenna in locatedAntennas {
            rect = rect.union(MKMapRect(origin: MKMapPoint(antenna.coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        for st in locatedSpeedtests {
            rect = rect.union(MKMapRect(origin: MKMapPoint(st.coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        if !rect.isNull {
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 44, left: 44, bottom: 44, right: 44), animated: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let points = overlay as? SessionPointsOverlay {
                return SessionPointsRenderer(overlay: points)
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.55)
                renderer.lineWidth = 2.5
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let serving = annotation as? ServingAntennaAnnotation {
                let identifier = "serving-antenna"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.markerTintColor = serving.tintColor
                view.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            if let st = annotation as? SessionSpeedtestAnnotation {
                let identifier = "session-speedtest"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.markerTintColor = st.tintColor
                view.glyphImage = UIImage(systemName: "speedometer")
                view.displayPriority = .defaultHigh
                view.canShowCallout = true
                return view
            }
            return nil
        }
    }
}

/// Overlay « nuage de points » dessiné en une passe Core Graphics : chaque point
/// est un disque de taille écran constante, coloré par son RSRP. Bornage par
/// `boundingMapRect` + culling dans le renderer → fluide pour de gros volumes.
final class SessionPointsOverlay: NSObject, MKOverlay {
    struct Dot { let point: MKMapPoint; let color: CGColor }

    let dots: [Dot]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(points: [CoverageSessionPoint], coloring: SessionPointColoring = .rsrp) {
        var rect = MKMapRect.null
        dots = points.map { p in
            let mp = MKMapPoint(p.coordinate)
            rect = rect.union(MKMapRect(origin: mp, size: MKMapSize(width: 0.5, height: 0.5)))
            let color = coloring == .generation ? SessionGenerationColor.cg(p.tech) : SessionRSRPColor.cg(p.signalStrength)
            return Dot(point: mp, color: color)
        }
        let bounding = rect.isNull ? MKMapRect.world : rect.insetBy(dx: -rect.size.width * 0.1 - 50, dy: -rect.size.height * 0.1 - 50)
        boundingMapRect = bounding
        coordinate = MKMapPoint(x: bounding.midX, y: bounding.midY).coordinate
    }
}

final class SessionPointsRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? SessionPointsOverlay else { return }
        // Rayon en points-écran constant : on divise par le zoomScale (espace carte).
        let radius = max(2.0, 3.0 / zoomScale)
        let pad = radius * 3
        let cull = mapRect.insetBy(dx: -pad, dy: -pad)
        // Disques SANS bordure : la couleur vive reste pleinement lisible même
        // dézoomé (un contour mangeait le disque quand le rayon devient petit).
        for dot in overlay.dots {
            guard cull.contains(dot.point) else { continue }
            let p = point(for: dot.point)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(dot.color)
            context.fillEllipse(in: rect)
        }
    }
}

/// Couleurs RSRP — mêmes seuils que la couche couverture de la carte principale.
enum SessionRSRPColor {
    static func ui(_ rsrp: Double?) -> UIColor {
        // Sentinelle iOS (0) ou valeur non physique → « aucun signal » : le RSRP réel
        // est toujours négatif (≤ -40 dBm). Évite de colorer un point iOS en « excellent ».
        guard let rsrp, rsrp < -1 else { return hex(0x94A3B8) }
        switch rsrp {
        case (-80)...:      return hex(0x10B981) // excellent
        case -90..<(-80):   return hex(0x84CC16) // bon
        case -100..<(-90):  return hex(0xF59E0B) // moyen
        case -110..<(-100): return hex(0xF97316) // faible
        default:            return hex(0xEF4444) // très faible
        }
    }

    static func cg(_ rsrp: Double?) -> CGColor { ui(rsrp).cgColor }

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Mode de coloration du nuage de points : RSRP (signal) ou GÉNÉRATION.
/// IMPORTANT : carte RSRP et carte génération sont deux cartes DISTINCTES.
enum SessionPointColoring { case rsrp, generation }

/// Couleurs par GÉNÉRATION (carte de couverture génération, distincte du RSRP).
enum SessionGenerationColor {
    static func ui(_ tech: String?) -> UIColor {
        let t = (tech ?? "").uppercased()
        if t.contains("5G") { return hex(0x8B5CF6) }            // 5G — violet
        if t.contains("4G") || t == "LTE" { return hex(0x3B82F6) } // 4G — bleu
        if t.contains("3G") { return hex(0x14B8A6) }            // 3G — teal
        if t.contains("2G") { return hex(0xF59E0B) }            // 2G — ambre
        return hex(0x94A3B8)                                     // Aucun / inconnu — gris
    }

    static func cg(_ tech: String?) -> CGColor { ui(tech).cgColor }

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Annotation MapKit d'une antenne desservante.
final class ServingAntennaAnnotation: NSObject, MKAnnotation {
    let antenna: ServingAntenna
    init(_ antenna: ServingAntenna) { self.antenna = antenna }

    var coordinate: CLLocationCoordinate2D { antenna.coordinate }
    var title: String? { antenna.operatorName ?? antenna.displayName ?? "Antenne" }
    var subtitle: String? {
        var parts: [String] = [antenna.status.label]
        if let d = antenna.distanceKm, d > 0 {
            parts.append(d < 1 ? "\(Int((d * 1000).rounded())) m" : String(format: "%.1f km", d))
        }
        return parts.joined(separator: " · ")
    }

    var tintColor: UIColor {
        switch antenna.status {
        case .identified: return UIColor(SQColor.brandGreen)
        case .hypothesis: return UIColor(SQColor.brandOrange)
        case .proximity, .unknown: return .systemGray
        }
    }
}

/// Annotation MapKit d'un speedtest géolocalisé (marqueur « débit »).
final class SessionSpeedtestAnnotation: NSObject, MKAnnotation {
    let speedtest: SessionSpeedtest
    let coordinate: CLLocationCoordinate2D
    init?(_ st: SessionSpeedtest) {
        guard let coord = st.coordinate else { return nil }
        self.speedtest = st
        self.coordinate = coord
    }

    var title: String? {
        let down = speedtest.downloadMbps.map { "↓ \(Int($0.rounded())) Mb/s" } ?? "↓ —"
        let up = speedtest.uploadMbps.map { "↑ \(Int($0.rounded()))" } ?? "↑ —"
        return "\(down) · \(up)"
    }
    var subtitle: String? {
        var parts: [String] = []
        if let op = speedtest.mobileOperator, !op.isEmpty { parts.append(op) }
        if let net = speedtest.networkType, !net.isEmpty { parts.append(net) }
        if let ping = speedtest.pingMs { parts.append("\(Int(ping.rounded())) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var tintColor: UIColor { SessionSpeedColor.ui(speedtest.downloadMbps) }
}

/// Couleur d'un speedtest par débit descendant (Mb/s) — du rouge (lent) au vert (rapide).
enum SessionSpeedColor {
    static func ui(_ mbps: Double?) -> UIColor {
        guard let m = mbps, m > 0 else { return hex(0x94A3B8) }
        switch m {
        case 150...:      return hex(0x10B981) // très rapide
        case 75..<150:    return hex(0x84CC16) // rapide
        case 30..<75:     return hex(0xF59E0B) // moyen
        case 10..<30:     return hex(0xF97316) // lent
        default:          return hex(0xEF4444) // très lent
        }
    }

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
