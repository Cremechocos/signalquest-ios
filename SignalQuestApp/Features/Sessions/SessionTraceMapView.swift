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
    var drawPath: Bool = false

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
            map.addOverlay(SessionPointsOverlay(points: validPoints), level: .aboveLabels)
        }
        // Antennes desservantes géolocalisées.
        let locatedAntennas = antennas.filter(\.hasValidCoordinate)
        map.addAnnotations(locatedAntennas.map(ServingAntennaAnnotation.init))

        var rect = MKMapRect.null
        for coord in coords {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coord), size: MKMapSize(width: 1, height: 1)))
        }
        for antenna in locatedAntennas {
            rect = rect.union(MKMapRect(origin: MKMapPoint(antenna.coordinate), size: MKMapSize(width: 1, height: 1)))
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
            guard let serving = annotation as? ServingAntennaAnnotation else { return nil }
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

    init(points: [CoverageSessionPoint]) {
        var rect = MKMapRect.null
        dots = points.map { p in
            let mp = MKMapPoint(p.coordinate)
            rect = rect.union(MKMapRect(origin: mp, size: MKMapSize(width: 0.5, height: 0.5)))
            return Dot(point: mp, color: SessionRSRPColor.cg(p.signalStrength))
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
        context.setLineWidth(radius * 0.35)
        let stroke = UIColor.black.withAlphaComponent(0.25).cgColor
        for dot in overlay.dots {
            guard cull.contains(dot.point) else { continue }
            let p = point(for: dot.point)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(dot.color)
            context.fillEllipse(in: rect)
            context.setStrokeColor(stroke)
            context.strokeEllipse(in: rect)
        }
    }
}

/// Couleurs RSRP — mêmes seuils que la couche couverture de la carte principale.
enum SessionRSRPColor {
    static func ui(_ rsrp: Double?) -> UIColor {
        guard let rsrp else { return hex(0x94A3B8) } // aucun signal
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
