import SwiftUI
import MapKit
import UIKit

/// Vue d'annotation native : pastille colorée (opérateur) ou pastille de cluster
/// numérotée.
///
/// Pour les antennes, la pastille est un POINT PLEIN, volontairement petit
/// (26 pt), sans pictogramme, et porte ses secteurs autour d'elle en points
/// d'écran. Les cônes géographiques de 320 m utilisés jusqu'ici se recouvraient
/// dès qu'une poignée de sites se trouvaient dans le même quartier : plus aucune
/// orientation n'était attribuable à un pylône. Un lobe attaché reste lisible
/// parce qu'il ne s'étale pas avec la carte — il grandit seulement quand le zoom
/// écarte les sites (`azimuthReachPoints`).
///
/// Trois signaux se lisent sur la pastille : la coche verte (eNB identifié par
/// la communauté), le badge appareil-photo (le site a des contributions), et
/// l'anneau fin des sites 5G — vert lui aussi lorsque le gNB est identifié.
final class SQMapKitMarkerView: MKAnnotationView, SQAccessibleAnnotationView {
    static let reuseID = "sq-mapkit-marker"
    let dot = UIView()
    let countLabel = UILabel()
    let glyph = UIImageView()

    /// Tous les lobes d'un même site dans UN seul calque : leur nombre est petit
    /// (2 à 6) et ils partagent couleur et transformation, un calque par secteur
    /// n'apporterait que du coût de composition.
    private let lobes = CAShapeLayer()
    private let ring = CAShapeLayer()
    /// Parts d'un site partagé. Un calque par part — `CAShapeLayer` n'a qu'une
    /// couleur de remplissage — mais recyclés d'un `apply` à l'autre : cette
    /// méthode est appelée pour CHAQUE annotation à chaque resynchronisation.
    private var pieSlices: [CAShapeLayer] = []
    /// Un calque par couleur d'opérateur pour les traits d'azimut. Les tirets de
    /// chacun sont décalés pour s'entrelacer sur une direction partagée.
    private var beamLayers: [CAShapeLayer] = []
    /// Arcs d'anneau 5G, un par opérateur concerné sur un support partagé.
    private var ringArcs: [CAShapeLayer] = []
    private let checkBadge = UIImageView()
    private let photoBadge = UIImageView()

    /// Diamètre de la pastille d'antenne. Les autres couches (speedtests, pannes,
    /// prévisionnels…) gardent l'ancien diamètre : elles n'ont ni lobes ni badges,
    /// et leur glyphe a besoin de la place.
    private static let antennaDotSize: CGFloat = 26
    private static let otherDotSize: CGFloat = 36
    private static let badgeSize: CGFloat = 14
    /// Rayon minimal de la vue, badges et anneau compris.
    private static let minRadius: CGFloat = 20

    /// Liseré crème du marqueur, CONSTANT dans les deux modes.
    ///
    /// Surtout pas `SQColor.onAccent` : ce jeton est du *texte sur aplat brique*
    /// et bascule au noir en mode sombre (l'accent y devient un saumon clair).
    /// Sur une carte, le liseré ne sert pas à lire du texte mais à détacher la
    /// pastille du fond — il doit rester clair quel que soit le thème, sinon le
    /// point se borde de noir la nuit.
    private static let outlineColor = UIColor(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xEF / 255, alpha: 1)

    /// Rayon tappable, indépendant de la taille de la vue. Sans lui, une vue de
    /// 88 pt de côté (lobes déployés à z16) capterait les taps destinés aux sites
    /// voisins — soit exactement l'imprécision que les lobes attachés évitent.
    private var hitRadius: CGFloat = SQMapKitMarkerView.otherDotSize / 2

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // Style « Crème & Terre cuite » : bord crème 2,5 pt + ombre noire 22 %.
        // Le glyphe/compteur reste crème sur la couleur (opérateur) du marqueur.
        dot.layer.borderColor = Self.outlineColor.cgColor
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
        lobes.fillColor = nil
        lobes.strokeColor = nil
        ring.fillColor = nil
        ring.lineWidth = 1.5
        checkBadge.contentMode = .scaleAspectFit
        photoBadge.contentMode = .scaleAspectFit
        layer.addSublayer(lobes)
        layer.addSublayer(ring)
        addSubview(dot)
        dot.addSubview(glyph)
        // Les parts sont rognées par le cercle du dot : `masksToBounds` ne peut
        // pas cohabiter avec l'ombre portée, donc c'est le TRACÉ de chaque part
        // qui reste dans le disque (cf. `applyPie`).
        dot.addSubview(countLabel)
        addSubview(checkBadge)
        addSubview(photoBadge)
    }
    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return hypot(point.x - center.x, point.y - center.y) <= hitRadius
    }

    func apply(_ payload: MapAnnotationPayload) {
        applyAccessibility(for: payload)
        let color = UIColor(payload.markerColor)
        if let count = payload.clusterCount {
            let size: CGFloat = count >= 100 ? 44 : 38
            resize(to: size, radius: size / 2)
            dot.backgroundColor = color
            dot.alpha = 1
            countLabel.frame = dot.bounds
            countLabel.text = count > 999 ? "999+" : "\(count)"
            countLabel.isHidden = false
            glyph.isHidden = true
            hidePie()
            hideBeams()
            hideRingArcs()
            lobes.path = nil
            ring.path = nil
            checkBadge.isHidden = true
            photoBadge.isHidden = true
        } else {
            let isAntenna = payload.kind == .antenna
            let size = isAntenna ? Self.antennaDotSize : Self.otherDotSize
            let reach = isAntenna ? payload.azimuthReachPoints : 0
            resize(to: size, radius: max(reach, Self.minRadius))
            dot.backgroundColor = color
            dot.alpha = payload.communityObserved ? 0.6 : 1
            countLabel.isHidden = true
            if isAntenna, payload.glyphOverride == nil {
                // Point plein, sans pictogramme : sur une carte où CHAQUE marqueur
                // est une antenne, un glyphe d'antenne ne distingue rien — il ne
                // fait que salir la pastille. L'information utile est portée par la
                // couleur (opérateur), les lobes (orientation) et les badges.
                glyph.image = nil
                glyph.isHidden = true
            } else {
                glyph.frame = dot.bounds.insetBy(dx: size * 0.24, dy: size * 0.24)
                glyph.image = UIImage(systemName: Self.glyphName(for: payload))?
                    .withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
                glyph.isHidden = false
            }
            applyPie(payload, size: size, fallback: color)
            applyLobes(payload, reach: reach, color: color)
            applyRing(payload, size: size, color: color)
            applyBadges(payload, size: size)
        }
    }

    /// Recentre pastille et badges dans une vue de `2 × radius` de côté. La vue
    /// s'agrandit avec les lobes, la pastille garde sa taille et le point ancré
    /// reste le centre (`centerOffset` nul).
    private func resize(to dotSize: CGFloat, radius: CGFloat) {
        let side = radius * 2
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        centerOffset = .zero
        hitRadius = max(dotSize / 2 + 4, Self.minRadius)
        dot.frame = CGRect(x: radius - dotSize / 2, y: radius - dotSize / 2, width: dotSize, height: dotSize)
        dot.layer.cornerRadius = dotSize / 2
        // `bounds` + `position`, jamais `frame` : le calque des lobes porte une
        // transform de rotation (cap de la carte), et `frame` n'a pas de sens sur
        // un calque transformé — une vue recyclée pendant que la carte est
        // pivotée verrait ses lobes décalés et redimensionnés.
        let box = CGRect(origin: .zero, size: bounds.size)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        lobes.bounds = box
        lobes.position = center
        ring.bounds = box
        ring.position = center
    }

    /// Azimuts, dans le style choisi par l'utilisateur.
    ///
    /// Les lobes disent l'ouverture du faisceau — juste physiquement, mais ils se
    /// recouvrent en centre-ville. Les traits ne disent que la direction et
    /// laissent la carte lisible. Aucun des deux n'est « meilleur » : ça dépend du
    /// terrain, d'où le réglage.
    private func applyLobes(_ payload: MapAnnotationPayload, reach: CGFloat, color: UIColor) {
        guard reach > 0, payload.showsAzimuths, !payload.azimuths.isEmpty,
              payload.azimuthStyle != .hidden else {
            lobes.path = nil
            hideBeams()
            return
        }
        // Traits + site partagé : chaque direction prend la ou les couleurs des
        // opérateurs qui la pointent, et le calque unique n'a plus rien à tracer.
        if payload.azimuthStyle == .lines, !payload.azimuthBeams.isEmpty {
            lobes.path = nil
            applyColoredBeams(payload.azimuthBeams, reach: reach)
            return
        }
        hideBeams()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath()
        let halfBeam = AntennaSectorGeometry.defaultHalfBeamDegrees
        for azimuth in payload.azimuths.prefix(8) {
            // Azimut 0° = nord = vers le haut de l'écran ; l'axe des Y de UIKit
            // descend, d'où le −90° pour passer du compas au repère de la vue.
            let screenAngle = (azimuth - 90) * .pi / 180
            switch payload.azimuthStyle {
            case .lobes:
                let start = screenAngle - halfBeam * .pi / 180
                let end = screenAngle + halfBeam * .pi / 180
                path.move(to: center)
                path.addArc(withCenter: center, radius: reach, startAngle: start, endAngle: end, clockwise: true)
                path.close()
            case .lines:
                path.move(to: center)
                path.addLine(to: CGPoint(
                    x: center.x + cos(screenAngle) * reach,
                    y: center.y + sin(screenAngle) * reach
                ))
            case .hidden:
                break
            }
        }
        lobes.path = path.cgPath
        switch payload.azimuthStyle {
        case .lobes:
            lobes.fillColor = color.withAlphaComponent(0.28).cgColor
            lobes.strokeColor = nil
            lobes.lineWidth = 0
        case .lines, .hidden:
            // Un trait part du CENTRE de la pastille : sans opacité il déborderait
            // visiblement dessus. 0,85 le garde net sans écraser le point.
            lobes.fillColor = nil
            lobes.strokeColor = color.withAlphaComponent(0.85).cgColor
            lobes.lineWidth = 2.5
            lobes.lineCap = .round
        }
    }

    /// Traits d'azimut colorés par opérateur.
    ///
    /// Une direction pointée par plusieurs opérateurs devient UN trait dont les
    /// tirets alternent leurs couleurs : deux traits superposés n'en laisseraient
    /// voir qu'un, et les écarter mentirait sur la direction — or c'est
    /// exactement ce qu'on regarde pour viser une antenne.
    ///
    /// Un calque par couleur, et non par direction : le nombre de calques reste
    /// borné par le nombre d'opérateurs du site (4 au plus en France), quel que
    /// soit le nombre de secteurs.
    private func applyColoredBeams(_ beams: [AzimuthBeam], reach: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Chaque couleur reçoit son propre chemin, et un décalage de tirets qui
        // dépend du nombre d'opérateurs SUR SA DIRECTION la plus partagée.
        var pathsByTint: [(tint: UIColor, path: UIBezierPath, slots: Int, slot: Int)] = []
        for beam in beams {
            let angle = (beam.azimuth - 90) * .pi / 180
            let end = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
            for (slot, tint) in beam.tints.enumerated() {
                let color = UIColor(tint)
                let index = pathsByTint.firstIndex {
                    $0.tint == color && $0.slots == beam.tints.count && $0.slot == slot
                }
                if let index {
                    pathsByTint[index].path.move(to: center)
                    pathsByTint[index].path.addLine(to: end)
                } else {
                    let path = UIBezierPath()
                    path.move(to: center)
                    path.addLine(to: end)
                    pathsByTint.append((color, path, beam.tints.count, slot))
                }
            }
        }

        for index in 0..<max(pathsByTint.count, beamLayers.count) {
            if index >= beamLayers.count {
                let beamLayer = CAShapeLayer()
                beamLayer.fillColor = nil
                beamLayer.lineWidth = 2.8
                layer.insertSublayer(beamLayer, above: lobes)
                beamLayers.append(beamLayer)
            }
            let beamLayer = beamLayers[index]
            guard index < pathsByTint.count else { beamLayer.isHidden = true; continue }
            let entry = pathsByTint[index]
            beamLayer.isHidden = false
            beamLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            beamLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            beamLayer.path = entry.path.cgPath
            beamLayer.strokeColor = entry.tint.withAlphaComponent(0.9).cgColor
            if entry.slots > 1 {
                // Un tiret « à moi », puis un vide de la longueur des autres :
                // les couleurs s'intercalent sans jamais se recouvrir.
                let dash: CGFloat = 5
                beamLayer.lineDashPattern = [NSNumber(value: Double(dash)),
                                             NSNumber(value: Double(dash * CGFloat(entry.slots - 1)))]
                beamLayer.lineDashPhase = -dash * CGFloat(entry.slot)
                beamLayer.lineCap = .butt
            } else {
                beamLayer.lineDashPattern = nil
                beamLayer.lineDashPhase = 0
                beamLayer.lineCap = .round
            }
        }
    }

    private func hideBeams() {
        for beamLayer in beamLayers { beamLayer.isHidden = true }
    }

    /// Camembert des opérateurs d'un site partagé.
    ///
    /// N'a de sens qu'en filtre « Tous » : dès qu'un opérateur est sélectionné, le
    /// backend ne renvoie que sa facette du site et il n'y a plus qu'une couleur.
    /// Le disque est libre — c'est l'ANNEAU qui est déjà pris par la 5G.
    private func applyPie(_ payload: MapAnnotationPayload, size: CGFloat, fallback: UIColor) {
        let tints = payload.operatorTints
        guard payload.kind == .antenna, tints.count > 1 else {
            hidePie()
            dot.backgroundColor = fallback
            return
        }
        // Le fond reste peint : il bouche les jointures entre parts au rendu.
        dot.backgroundColor = UIColor(tints[0])
        let center = CGPoint(x: size / 2, y: size / 2)
        // Le rayon mord de 0,5 pt sous le bord crème pour qu'aucune part ne
        // dépasse en anticrénelage.
        let radius = size / 2 - 0.5
        let step = (.pi * 2) / CGFloat(tints.count)
        for index in 0..<max(tints.count, pieSlices.count) {
            if index >= pieSlices.count {
                let slice = CAShapeLayer()
                slice.strokeColor = nil
                dot.layer.insertSublayer(slice, at: 0)
                pieSlices.append(slice)
            }
            let slice = pieSlices[index]
            guard index < tints.count else { slice.isHidden = true; continue }
            slice.isHidden = false
            slice.frame = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            // Première part au sommet (−90°), puis sens horaire : l'ordre suit
            // celui des opérateurs du site, stable d'un rendu à l'autre.
            let start = -CGFloat.pi / 2 + step * CGFloat(index)
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + step, clockwise: true)
            path.close()
            slice.path = path.cgPath
            slice.fillColor = UIColor(tints[index]).cgColor
        }
    }

    private func hidePie() {
        for slice in pieSlices { slice.isHidden = true }
    }

    private func applyRing(_ payload: MapAnnotationPayload, size: CGFloat, color: UIColor) {
        guard payload.kind == .antenna, payload.has5G else {
            ring.path = nil
            hideRingArcs()
            return
        }
        let radius = size / 2 + 4
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Support partagé dont on sait QUI émet en 5G : un arc par opérateur
        // concerné, découpé sur les mêmes secteurs que le camembert. L'arc coiffe
        // donc exactement la part de son opérateur — on lit d'un coup d'œil qui
        // a la 5G et qui ne l'a pas.
        if !payload.fiveGTintIndices.isEmpty, payload.operatorTints.count > 1 {
            ring.path = nil
            applyRingArcs(payload, radius: radius, center: center)
            return
        }
        hideRingArcs()
        ring.path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        ).cgPath
        // Vert = le gNB de ce site 5G est identifié. Couleur opérateur = il émet
        // en 5G mais personne n'a encore trouvé son gNB.
        ring.strokeColor = (payload.hasGnb ? UIColor(SQColor.success) : color).cgColor
    }

    /// Un arc d'anneau par opérateur 5G, aligné sur sa part de camembert.
    ///
    /// Les arcs sont RACCOURCIS de quelques degrés à chaque extrémité : deux arcs
    /// jointifs se toucheraient et se liraient comme un anneau continu, ce qui
    /// ferait croire que tous les opérateurs ont la 5G.
    private func applyRingArcs(_ payload: MapAnnotationPayload, radius: CGFloat, center: CGPoint) {
        let tints = payload.operatorTints
        let step = (.pi * 2) / CGFloat(tints.count)
        // 6° de respiration de chaque côté, un peu moins quand les parts sont
        // étroites — sinon un arc de 90° amputé de 12° paraît flotter.
        let gap: CGFloat = min(6 * .pi / 180, step * 0.12)
        let indices = payload.fiveGTintIndices.filter { $0 < tints.count }

        for index in 0..<max(indices.count, ringArcs.count) {
            if index >= ringArcs.count {
                let arc = CAShapeLayer()
                arc.fillColor = nil
                arc.lineWidth = 2.2
                arc.lineCap = .round
                layer.insertSublayer(arc, above: ring)
                ringArcs.append(arc)
            }
            let arc = ringArcs[index]
            guard index < indices.count else { arc.isHidden = true; continue }
            let slot = indices[index]
            arc.isHidden = false
            arc.bounds = CGRect(origin: .zero, size: bounds.size)
            arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // Même origine que le camembert : première part au sommet (−90°).
            let start = -CGFloat.pi / 2 + step * CGFloat(slot)
            arc.path = UIBezierPath(
                arcCenter: center,
                radius: radius,
                startAngle: start + gap,
                endAngle: start + step - gap,
                clockwise: true
            ).cgPath
            // Vert quand le gNB du SITE est identifié : la donnée n'est pas
            // ventilée par opérateur, on ne prétend donc pas qu'elle l'est.
            arc.strokeColor = (payload.hasGnb ? UIColor(SQColor.success) : UIColor(tints[slot])).cgColor
        }
    }

    private func hideRingArcs() {
        for arc in ringArcs { arc.isHidden = true }
    }

    private func applyBadges(_ payload: MapAnnotationPayload, size: CGFloat) {
        let isAntenna = payload.kind == .antenna
        let showsCheck = isAntenna && payload.hasEnb
        let showsPhoto = isAntenna && payload.contributionPhotos > 0
        checkBadge.isHidden = !showsCheck
        photoBadge.isHidden = !showsPhoto
        guard showsCheck || showsPhoto else { return }

        // Badges posés en diagonale, débordant de la pastille : leur centre est à
        // `rayon + moitié de badge − 3`, soit trois points de chevauchement — assez
        // pour qu'ils s'accrochent visuellement au marqueur, pas assez pour manger
        // le pylône ni l'anneau 5G.
        let badge = Self.badgeSize
        let distance = size / 2 + badge / 2 - 3
        let offset = distance * CGFloat(2).squareRoot() / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if showsCheck {
            checkBadge.image = Self.checkBadgeImage(size: badge)
            checkBadge.frame = CGRect(
                x: center.x + offset - badge / 2,
                y: center.y - offset - badge / 2,
                width: badge,
                height: badge
            )
        }
        if showsPhoto {
            photoBadge.image = Self.photoBadgeImage(size: badge)
            photoBadge.frame = CGRect(
                x: center.x - offset - badge / 2,
                y: center.y + offset - badge / 2,
                width: badge,
                height: badge
            )
        }
    }

    /// Oriente les lobes selon la rotation de la carte. Ils sont dessinés en
    /// repère écran : sans cette contre-rotation, un site pointerait le mauvais
    /// azimut dès que l'utilisateur fait pivoter la carte à la boussole.
    func applyMapHeading(_ headingDegrees: Double) {
        let angle = -headingDegrees * .pi / 180
        let transform = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
        // Les changements de `transform` sont animés par défaut sur un CALayer
        // hors hiérarchie UIView : pendant un geste de rotation continue, cela
        // ferait traîner les lobes derrière la carte.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lobes.transform = transform
        CATransaction.commit()
    }

    // MARK: Accès aux calques pour les tests
    //
    // Le marqueur n'affiche aucun texte : orientation, identification et photos
    // sont des formes. Sans ces accesseurs, aucun test ne peut vérifier ce qui
    // est réellement dessiné.

    var lobePathForTesting: CGPath? { lobes.path }
    var ringPathForTesting: CGPath? { ring.path }
    var ringColorForTesting: CGColor? { ring.strokeColor }
    var lobeTransformForTesting: CATransform3D { lobes.transform }
    var checkBadgeIsHiddenForTesting: Bool { checkBadge.isHidden }
    var photoBadgeIsHiddenForTesting: Bool { photoBadge.isHidden }

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
        case .customSite: return "mappin.and.ellipse"
        case .speedtest: return "speedometer"
        case .coverage: return "dot.radiowaves.left.and.right"
        }
    }

    // MARK: Images mises en cache

    /// `apply(_:)` est appelé pour CHAQUE annotation à chaque resynchronisation de
    /// couche : rendre ces images à la volée coûterait un `UIGraphicsImageRenderer`
    /// par marqueur et par rendu. Elles ne dépendent que de leur taille.
    private static var imageCache: [String: UIImage] = [:]

    private static func cachedImage(_ key: String, _ make: () -> UIImage) -> UIImage {
        if let hit = imageCache[key] { return hit }
        let image = make()
        imageCache[key] = image
        return image
    }

    /// Encre constante des badges — même raison que `outlineColor` : ce sont des
    /// objets posés sur la carte, pas du texte sur une surface de l'app, et ils
    /// doivent garder le même aspect en clair comme en sombre.
    private static let badgeInkColor = UIColor(red: 0x33 / 255, green: 0x28 / 255, blue: 0x18 / 255, alpha: 1)

    private static func checkBadgeImage(size: CGFloat) -> UIImage {
        cachedImage("check-\(Int(size.rounded()))") {
            badgeImage(
                size: size,
                fill: UIColor(SQColor.success),
                symbol: "checkmark",
                symbolColor: outlineColor
            )
        }
    }

    private static func photoBadgeImage(size: CGFloat) -> UIImage {
        cachedImage("photo-\(Int(size.rounded()))") {
            badgeImage(
                size: size,
                fill: outlineColor,
                symbol: "camera.fill",
                symbolColor: badgeInkColor
            )
        }
    }

    /// Pastille de badge : disque plein, liseré crème, symbole centré. Le liseré
    /// est ce qui garde le badge lisible quand il chevauche l'anneau 5G ou un
    /// lobe voisin.
    private static func badgeImage(size: CGFloat, fill: UIColor, symbol: String, symbolColor: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let border: CGFloat = 1.5
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let cg = context.cgContext
            cg.setFillColor(outlineColor.cgColor)
            cg.fillEllipse(in: rect)
            cg.setFillColor(fill.cgColor)
            cg.fillEllipse(in: rect.insetBy(dx: border, dy: border))
            let glyphSide = size * 0.52
            let configuration = UIImage.SymbolConfiguration(pointSize: glyphSide, weight: .heavy)
            guard let image = UIImage(systemName: symbol)?
                .withConfiguration(configuration)
                .withTintColor(symbolColor, renderingMode: .alwaysOriginal) else { return }
            let scale = min(glyphSide / image.size.width, glyphSide / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (size - drawSize.width) / 2,
                y: (size - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
        }
    }
}
