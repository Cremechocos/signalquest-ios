import SwiftUI
import MapKit
import UIKit

/// Marqueur d'un ami vivant, façon « Find My » : photo de profil circulaire,
/// halo coloré par la présence (olive = en ligne, ambre = absent, danger = ne pas
/// déranger, gris = hors ligne), cône de cap (heading — qu'Android ne rend pas) et
/// badge technologie. Position périmée → marqueur estompé. Style « Crème & Terre
/// cuite » : bord crème épais + ombre chaude.
final class SQFriendMarkerView: MKAnnotationView, SQAccessibleAnnotationView {
    static let reuseID = "sq-friend-marker"
    let coneLayer = CAShapeLayer()
    let halo = UIView()
    let avatarView = UIImageView()
    let initials = UILabel()
    let techBadge = SQInsetLabel()
    var imageTask: Task<Void, Never>?
    var currentAvatarURL: URL?

    let markerSize: CGFloat = 56
    let avatarSize: CGFloat = 42
    let haloSize: CGFloat = 50

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // L'ancre géographique reste au centre de l'avatar : le badge déborde
        // sous le frame sans le décaler.
        frame = CGRect(x: 0, y: 0, width: markerSize, height: markerSize)
        clipsToBounds = false
        let center = CGPoint(x: markerSize / 2, y: markerSize / 2)

        // Cône de cap, dessiné derrière l'avatar (rayon > halo), pointant au nord
        // par défaut ; orienté ensuite par le heading via une rotation de layer.
        let coneRadius: CGFloat = 30
        let coneHalf: CGFloat = 34 * .pi / 180
        let conePath = UIBezierPath()
        conePath.move(to: center)
        conePath.addArc(withCenter: center, radius: coneRadius,
                        startAngle: -.pi / 2 - coneHalf, endAngle: -.pi / 2 + coneHalf,
                        clockwise: true)
        conePath.close()
        coneLayer.path = conePath.cgPath
        coneLayer.fillColor = UIColor.clear.cgColor
        coneLayer.isHidden = true
        layer.addSublayer(coneLayer)

        halo.frame = CGRect(x: center.x - haloSize / 2, y: center.y - haloSize / 2, width: haloSize, height: haloSize)
        halo.layer.cornerRadius = haloSize / 2
        halo.layer.shadowColor = UIColor.black.cgColor
        halo.layer.shadowOpacity = 0.22
        halo.layer.shadowRadius = 5
        halo.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(halo)

        avatarView.frame = CGRect(x: center.x - avatarSize / 2, y: center.y - avatarSize / 2, width: avatarSize, height: avatarSize)
        avatarView.layer.cornerRadius = avatarSize / 2
        avatarView.clipsToBounds = true
        avatarView.contentMode = .scaleAspectFill
        avatarView.layer.borderColor = UIColor(SQColor.onAccent).cgColor
        avatarView.layer.borderWidth = 2.5
        avatarView.backgroundColor = UIColor(SQColor.brandRed)
        addSubview(avatarView)

        initials.frame = avatarView.bounds
        initials.textAlignment = .center
        initials.textColor = UIColor(SQColor.onAccent)
        initials.font = .systemFont(ofSize: 16, weight: .semibold)
        avatarView.addSubview(initials)

        techBadge.font = .systemFont(ofSize: 9, weight: .bold)
        techBadge.textColor = UIColor(SQColor.label)
        techBadge.backgroundColor = UIColor(SQColor.surface)
        techBadge.layer.cornerRadius = 7
        techBadge.clipsToBounds = true
        techBadge.layer.borderColor = UIColor(SQColor.onAccent).withAlphaComponent(0.6).cgColor
        techBadge.layer.borderWidth = 1
        techBadge.isHidden = true
        addSubview(techBadge)
    }
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        currentAvatarURL = nil
        avatarView.image = nil
        initials.isHidden = false
    }

    func apply(_ info: FriendAnnotationInfo, displayScale: CGFloat) {
        // Le payload vit sur l'annotation : la signature de `apply` diffère
        // d'une vue à l'autre, pas la source de vérité.
        if let payload = (annotation as? SQMapKitAnnotation)?.payload {
            applyAccessibility(for: payload)
        }
        let presence = Self.presenceColor(info.presence)
        halo.backgroundColor = presence

        if let heading = info.heading {
            coneLayer.isHidden = false
            coneLayer.fillColor = presence.withAlphaComponent(0.30).cgColor
            coneLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(heading) * .pi / 180))
        } else {
            coneLayer.isHidden = true
        }

        if let tech = info.technology?.trimmingCharacters(in: .whitespaces), !tech.isEmpty {
            techBadge.isHidden = false
            techBadge.text = tech.uppercased()
            techBadge.sizeToFit()
            let size = techBadge.intrinsicContentSize
            techBadge.frame = CGRect(x: (markerSize - size.width) / 2, y: markerSize - 6, width: size.width, height: size.height)
        } else {
            techBadge.isHidden = true
        }

        alpha = info.isStale ? 0.55 : 1.0

        initials.text = String(info.displayName.prefix(1)).uppercased()
        guard info.avatarURL != currentAvatarURL else { return }
        currentAvatarURL = info.avatarURL
        imageTask?.cancel()
        guard let url = info.avatarURL else {
            avatarView.image = nil
            initials.isHidden = false
            return
        }
        let maxPixel = avatarSize * displayScale
        // Cache chaud → affichage SYNCHRONE : les marqueurs sont recréés plus vite
        // qu'un chargement asynchrone n'aboutit, si bien que l'image se posait sur
        // une vue déjà remplacée et n'apparaissait jamais. Dès que le cache mémoire
        // est rempli (après le 1er téléchargement), chaque recréation ré-affiche
        // l'avatar instantanément.
        if let cached = ImagePipeline.shared.cachedImage(for: url, maxPixel: maxPixel) {
            avatarView.image = cached
            initials.isHidden = true
            return
        }
        avatarView.image = nil
        initials.isHidden = false
        imageTask = Task { @MainActor [weak self] in
            let image = try? await ImagePipeline.shared.image(for: url, maxPixel: maxPixel)
            guard let self, !Task.isCancelled, self.currentAvatarURL == url, let image else { return }
            self.avatarView.image = image
            self.initials.isHidden = true
        }
    }

    /// Couleur de présence, alignée sur les tokens DA (olive/ambre/danger/gris).
    static func presenceColor(_ status: SocialPresenceStatus) -> UIColor {
        switch status {
        case .online: return UIColor(SQColor.success)
        case .away: return UIColor(SQColor.warning)
        case .dnd: return UIColor(SQColor.danger)
        case .offline, .invisible: return UIColor(SQColor.labelTertiary)
        }
    }
}
