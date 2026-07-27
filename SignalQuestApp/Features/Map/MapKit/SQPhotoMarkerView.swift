import SwiftUI
import MapKit
import UIKit

/// Marqueur photo « polaroïd » : la vignette géolocalisée est rendue directement
/// sur la carte dans un cadre crème arrondi (marge basse épaissie façon polaroïd)
/// plutôt qu'en pastille appareil-photo. Chargement async + downsampling via
/// `ImagePipeline`. Les CLUSTERS de photos gardent la pastille numérotée.
final class SQPhotoMarkerView: MKAnnotationView {
    static let reuseID = "sq-photo-marker"
    let card = UIView()
    let photo = UIImageView()
    let placeholder = UIImageView()
    var imageTask: Task<Void, Never>?
    var currentURL: URL?

    let cardWidth: CGFloat = 52
    let cardHeight: CGFloat = 60
    let inset: CGFloat = 4

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        frame = CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        clipsToBounds = false

        card.frame = bounds
        card.backgroundColor = UIColor(SQColor.surface)
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.22
        card.layer.shadowRadius = 5
        card.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(card)

        let side = cardWidth - inset * 2
        let imageRect = CGRect(x: inset, y: inset, width: side, height: side)
        photo.frame = imageRect
        photo.layer.cornerRadius = 8
        photo.layer.cornerCurve = .continuous
        photo.clipsToBounds = true
        photo.contentMode = .scaleAspectFill
        photo.backgroundColor = UIColor(SQColor.surfaceMuted)
        card.addSubview(photo)

        placeholder.frame = imageRect
        placeholder.contentMode = .center
        placeholder.tintColor = UIColor(SQColor.labelTertiary)
        placeholder.image = UIImage(systemName: "camera.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        card.addSubview(placeholder)
    }
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        currentURL = nil
        photo.image = nil
        placeholder.isHidden = false
    }

    func apply(url: URL?, displayScale: CGFloat) {
        guard url != currentURL else { return }
        currentURL = url
        photo.image = nil
        placeholder.isHidden = false
        imageTask?.cancel()
        guard let url else { return }
        let maxPixel = (cardWidth - inset * 2) * displayScale
        imageTask = Task { @MainActor [weak self] in
            let image = try? await ImagePipeline.shared.image(for: url, maxPixel: maxPixel)
            guard let self, !Task.isCancelled, self.currentURL == url, let image else { return }
            self.photo.image = image
            self.placeholder.isHidden = true
        }
    }
}
