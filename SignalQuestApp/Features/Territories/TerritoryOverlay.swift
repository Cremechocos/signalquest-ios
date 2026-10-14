import MapKit
import UIKit

/// Grille de territoires en **un seul** `MKOverlay`.
///
/// Surtout pas N `MKPolygon` : une bbox de ville produit ~1 500 cellules, et
/// MapKit crée un renderer par overlay. Le coût devient rédhibitoire bien avant
/// qu'on ait dézoomé sur une région. Même approche que `SQMapKitDotsOverlay` —
/// un overlay, une passe Core Graphics, culling au rectangle demandé.
final class TerritoryOverlay: NSObject, MKOverlay {
    struct Cell {
        let rect: MKMapRect
        let fill: CGColor
        let stroke: CGColor
        /// Cellule conquise par l'utilisateur : soulignée d'un liseré plus net.
        let mine: Bool
        /// Hachures d'une zone inexplorée : un aplat à 6 % ne se voyait pas.
        var hatch: CGColor?
        /// Carré touché : entouré de cette encre.
        var selection: CGColor?
    }

    let cells: [Cell]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(cells: [Cell]) {
        self.cells = cells
        var rect = MKMapRect.null
        for cell in cells { rect = rect.union(cell.rect) }
        boundingMapRect = rect.isNull ? .world : rect
        coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        super.init()
    }
}

final class TerritoryOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? TerritoryOverlay else { return }

        // Culling : MapKit appelle `draw` par tuile. Sans ce filtre, chaque
        // tuile parcourrait les milliers de cellules de la grille entière.
        let visible = mapRect.insetBy(dx: -mapRect.size.width * 0.1, dy: -mapRect.size.height * 0.1)
        // Le liseré est en points ÉCRAN : divisé par `zoomScale`, il garde la
        // même finesse à tous les niveaux au lieu de s'épaissir en dézoomant.
        let lineWidth = 1.0 / zoomScale
        context.setShouldAntialias(false)   // grille orthogonale : l'antialiasing ne fait que flouter
        context.setLineWidth(lineWidth)

        for cell in overlay.cells {
            guard visible.intersects(cell.rect) else { continue }
            let rect = self.rect(for: cell.rect)
            context.setFillColor(cell.fill)
            context.fill(rect)
            if let hatch = cell.hatch {
                drawHatch(in: rect, color: hatch, zoomScale: zoomScale, context: context)
            }
            context.setStrokeColor(cell.stroke)
            context.setLineWidth(cell.mine ? lineWidth * 2.5 : lineWidth)
            context.stroke(rect)
        }
        // Le carré touché en dernier, pour que ses voisins ne recouvrent pas son contour.
        if let selected = overlay.cells.first(where: { $0.selection != nil }), let ink = selected.selection,
           visible.intersects(selected.rect) {
            context.setShouldAntialias(true)
            context.setStrokeColor(ink)
            context.setLineWidth(lineWidth * 3)
            context.stroke(self.rect(for: selected.rect).insetBy(dx: lineWidth * 1.5, dy: lineWidth * 1.5))
        }
    }

    /// Diagonales espacées de 7 pt à l'écran, quelle que soit l'échelle.
    private func drawHatch(in rect: CGRect, color: CGColor, zoomScale: MKZoomScale, context: CGContext) {
        let step = 7.0 / zoomScale
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(color)
        context.setLineWidth(1.0 / zoomScale)
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

extension TerritoryCell {
    var mapRect: MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east))
        return MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    /// Couleur de remplissage.
    ///
    /// La zone inexplorée (`virgin`) est volontairement la plus DISCRÈTE : c'est
    /// l'état par défaut de la carte, la peindre vivement ferait un damier
    /// illisible. Ce sont les zones conquises qui doivent ressortir.
    var fillColor: UIColor {
        switch status {
        case .virgin: return UIColor(SQColor.labelTertiary).withAlphaComponent(0.06)
        case .observed: return UIColor(SQColor.warning).withAlphaComponent(0.18)
        case .reliable: return UIColor(SQColor.brandRed).withAlphaComponent(0.28)
        case .complete: return UIColor(SQColor.success).withAlphaComponent(0.38)
        case .stale: return UIColor(SQColor.labelSecondary).withAlphaComponent(0.14)
        }
    }

    /// Teinte pleine du statut, pour le liseré des pastilles de légende.
    var strokeTint: UIColor {
        switch status {
        case .virgin: return UIColor(SQColor.labelTertiary)
        case .observed: return UIColor(SQColor.warning)
        case .reliable: return UIColor(SQColor.brandRed)
        case .complete: return UIColor(SQColor.success)
        case .stale: return UIColor(SQColor.labelSecondary)
        }
    }

    /// Hachures des zones inexplorées.
    static var hatchColor: UIColor { UIColor(SQColor.labelTertiary).withAlphaComponent(0.35) }

    var strokeColor: UIColor {
        mine
            ? UIColor(SQColor.brandRed).withAlphaComponent(0.9)
            : UIColor(SQColor.label).withAlphaComponent(0.12)
    }

    /// « Zone blanche » veut dire « sans réseau » en France : une zone que
    /// personne n'a encore explorée est « inexplorée » (SOC-39).
    var statusLabel: String {
        switch status {
        case .virgin: return String(localized: "Zone inexplorée")
        case .observed: return String(localized: "Observée")
        case .reliable: return String(localized: "Fiable")
        case .complete: return String(localized: "Complète")
        case .stale: return String(localized: "À rafraîchir")
        }
    }
}
