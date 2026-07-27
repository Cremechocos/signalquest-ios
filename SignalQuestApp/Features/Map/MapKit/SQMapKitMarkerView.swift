import SwiftUI
import MapKit
import UIKit

/// Vue d'annotation native : pastille colorée (opérateur) ou pastille de cluster
/// numérotée. (Vignettes photos / cônes : phases ultérieures.)
final class SQMapKitMarkerView: MKAnnotationView {
    static let reuseID = "sq-mapkit-marker"
    let dot = UIView()
    let countLabel = UILabel()
    let glyph = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // Style « Crème & Terre cuite » : bord crème 2,5 pt + ombre noire 22 %.
        // Le glyphe/compteur reste crème sur la couleur (opérateur) du marqueur.
        dot.layer.borderColor = UIColor(SQColor.onAccent).cgColor
        dot.layer.borderWidth = 2.5
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.22
        dot.layer.shadowRadius = 5
        dot.layer.shadowOffset = CGSize(width: 0, height: 3)
        countLabel.textColor = UIColor(SQColor.onAccent)
        countLabel.font = .systemFont(ofSize: 12, weight: .bold)
        countLabel.textAlignment = .center
        glyph.tintColor = UIColor(SQColor.onAccent)
        glyph.contentMode = .scaleAspectFit
        addSubview(dot)
        dot.addSubview(glyph)
        dot.addSubview(countLabel)
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ payload: MapAnnotationPayload) {
        let color = UIColor(payload.markerColor)
        if let count = payload.clusterCount {
            let size: CGFloat = count >= 100 ? 44 : 38
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            dot.frame = bounds
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = color
            dot.alpha = 1
            countLabel.frame = dot.bounds
            countLabel.text = count > 999 ? "999+" : "\(count)"
            countLabel.isHidden = false
            glyph.isHidden = true
        } else {
            let size: CGFloat = 36
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            dot.frame = bounds
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = color
            dot.alpha = payload.communityObserved ? 0.6 : 1
            countLabel.isHidden = true
            glyph.frame = dot.bounds.insetBy(dx: 8, dy: 8)
            glyph.image = UIImage(systemName: Self.glyphName(for: payload))?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
            glyph.isHidden = false
        }
    }

    static func glyphName(for p: MapAnnotationPayload) -> String {
        if let g = p.glyphOverride { return g }
        switch p.kind {
        case .antenna: return "antenna.radiowaves.left.and.right"
        case .photo: return "camera.fill"
        case .friend: return "person.fill"
        case .validation: return "checkmark.seal.fill"
        case .session: return "figure.walk"
        case .outage: return "exclamationmark.triangle.fill"
        case .planned: return "calendar.badge.clock"
        case .communitySite: return "dot.radiowaves.up.forward"
        case .speedtest: return "speedometer"
        case .coverage: return "dot.radiowaves.left.and.right"
        }
    }
}
