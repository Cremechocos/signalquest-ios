import SwiftUI
import MapKit
import UIKit

/// Overlay « nuage de points » dense (couverture / speedtests) dessiné en une passe
/// Core Graphics avec culling viewport — tient des milliers de points (pattern repris
/// de SessionTraceMapView, le moteur de « Mes mesures »).
final class SQMapKitDotsOverlay: NSObject, MKOverlay {
    struct Dot {
        let point: MKMapPoint
        let color: CGColor
        /// « Sans réseau constaté » : anneau et hachures plutôt qu'un disque plein.
        var hatched = false
    }
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
            if dot.hatched {
                Self.drawHatched(dot.color, in: r, context: context)
            } else {
                context.setFillColor(dot.color)
                context.fillEllipse(in: r)
            }
        }
    }

    /// Hachures du contrat pour « sans réseau constaté » : anneau et trois
    /// diagonales dans le disque, lisibles sans la couleur.
    static func drawHatched(_ color: CGColor, in rect: CGRect, context: CGContext) {
        let line = max(rect.width / 7, 0.4)
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(line)
        context.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
        context.addEllipse(in: rect)
        context.clip()
        let step = rect.width / 3
        var x = rect.minX - rect.height
        while x < rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        context.strokePath()
        context.restoreGState()
    }
}
