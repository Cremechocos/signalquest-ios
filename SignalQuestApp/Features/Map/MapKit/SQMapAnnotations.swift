import SwiftUI
import MapKit
import UIKit

/// Annotation MapKit portant le payload (pour le dispatch tap → fiche).
final class SQMapKitAnnotation: NSObject, MKAnnotation {
    var payload: MapAnnotationPayload
    /// `@objc dynamic` → MapKit observe (KVO) les changements de position et anime
    /// le déplacement de la vue lorsqu'on modifie `coordinate` dans un
    /// `UIView.animate`. Sert au déplacement fluide des amis vivants.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(payload: MapAnnotationPayload) {
        self.payload = payload
        self.coordinate = payload.coordinate
        super.init()
    }
}

/// Étiquette compacte avec marges internes (badge techno du marqueur ami).
final class SQInsetLabel: UILabel {
    var insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: base.width + insets.left + insets.right,
                      height: base.height + insets.top + insets.bottom)
    }
}
