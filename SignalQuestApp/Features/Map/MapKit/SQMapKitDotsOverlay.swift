import SwiftUI
import MapKit
import UIKit

/// Overlay « nuage de points » dense (couverture / speedtests) dessiné en une passe
/// Core Graphics avec culling viewport — tient des milliers de points (pattern repris
/// de SessionTraceMapView, le moteur de « Mes mesures »).
final class SQMapKitDotsOverlay: NSObject, MKOverlay {
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

final class SQMapKitDotsRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? SQMapKitDotsOverlay else { return }
        // Points PLEINS : disque de couleur opaque, sans halo ni aucun contour. Taille
        // écran ~constante via `k / zoomScale` → nettement visibles à TOUS les zooms.
        let radius = max(2.6, 4.6 / zoomScale)
        let pad = radius * 3
        let cull = mapRect.insetBy(dx: -pad, dy: -pad)
        context.setShouldAntialias(true)
        for dot in overlay.dots {
            guard cull.contains(dot.point) else { continue }
            let p = point(for: dot.point)
            let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(dot.color)
            context.fillEllipse(in: r)
        }
    }
}
