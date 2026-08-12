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
    /// Panne communautaire signalée sur ce site, quand le filtre « Pannes » est
    /// éteint : l'antenne reste le sujet, la panne n'est qu'un indice posé à côté.
    private let outageBadge = UIImageView()
    /// Incident déclaré par l'OPÉRATEUR sur ce site, filtre « Pannes » éteint.
    ///
    /// Un badge à part, et pas une variante de couleur du précédent : les deux peuvent coexister
    /// sur le même pylône, et c'est justement le cas le plus parlant — l'opérateur reconnaît ce
    /// que la communauté a signalé. Sa forme est un TRIANGLE là où le communautaire est un
    /// disque, pour qu'on lise QUI affirme sans avoir à ouvrir quoi que ce soit.
    private let operatorBadge = UIImageView()

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

    /// Décalage du marqueur de panne par rapport au point d'antenne qu'il concerne.
    ///
    /// Sans lui, les 36 pt de la panne se posent EXACTEMENT sur les 26 pt de
    /// l'antenne : le point d'antenne est masqué et devient intappable, alors que
    /// « une cible = une destination » veut qu'on puisse ouvrir l'une ou l'autre.
    /// La longueur vaut la somme des deux rayons (13 + 18) : en deçà les pastilles
    /// se chevauchent encore, au-delà la panne se détacherait du site qu'elle
    /// désigne. Vers le haut à droite, comme Android (`circleTranslate(16, −16)`).
    ///
    /// `centerOffset` déplace la VUE, pas seulement son dessin : la zone tactile
    /// suit sans réglage supplémentaire, contrairement à MapLibre où le décalage
    /// est une propriété de couche appliquée au rendu.
    ///
    /// ⚠️ Les DISQUES deviennent tangents, mais les zones tactiles (gonflées à 20 et
    /// 22 pt par `resize`) se recouvrent encore sur une bande d'une dizaine de points
    /// entre les deux ; c'est la vue au-dessus qui y gagne, et MapKit n'ordonne pas
    /// deux annotations de même coordonnée. Taper ce qu'on VOIT reste juste : chaque
    /// centre visible est hors de la zone de l'autre. Les rendre disjointes
    /// demanderait 42 pt d'écart, où la panne ne se lirait plus comme celle de ce
    /// pylône-là.
    private static let communityOutageOffset: CGPoint = {
        let distance = antennaDotSize / 2 + otherDotSize / 2
        let axis = distance / CGFloat(2).squareRoot()
        return CGPoint(x: axis, y: -axis)
    }()

    /// Le même décalage pour l'incident déclaré par l'OPÉRATEUR, en miroir.
    ///
    /// Même raison que ci-dessus, et le trou était le même : posé pile sur le point d'antenne, le
    /// marqueur d'incident le masquait et le rendait intappable, alors que « une cible = une
    /// destination » vaut pour les deux sources — c'est même l'information la PLUS fiable qui
    /// s'effaçait.
    ///
    /// Vers le haut à GAUCHE, et non à droite comme le communautaire : les deux couches restent
    /// distinctes et un site peut très bien porter les deux à la fois (le CSV opérateur confirme
    /// un signalement, il ne le remplace pas). Superposées, elles se seraient à nouveau masquées
    /// l'une l'autre — cette fois entre elles.
    private static let operatorIncidentOffset = CGPoint(
        x: -communityOutageOffset.x,
        y: communityOutageOffset.y
    )

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // Style « Crème & Terre cuite » : bord crème 2,5 pt + ombre noire 22 %.
        // Glyphe et compteur prennent l'encre que leur remplissage supporte
        // (cf. `ink(on:)`), posée à chaque `apply` et re-résolue par UIKit au
        // basculement clair/sombre.
        dot.layer.borderColor = Self.outlineColor.cgColor
        dot.layer.borderWidth = 2.5
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.22
        dot.layer.shadowRadius = 5
        dot.layer.shadowOffset = CGSize(width: 0, height: 3)
        countLabel.font = .systemFont(ofSize: 12, weight: .bold)
        countLabel.textAlignment = .center
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
        outageBadge.contentMode = .scaleAspectFit
        addSubview(outageBadge)
        operatorBadge.contentMode = .scaleAspectFit
        addSubview(operatorBadge)
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
            dot.layer.borderColor = Self.outlineColor.cgColor
            dot.alpha = 1
            countLabel.frame = dot.bounds
            countLabel.textColor = Self.ink(on: color)
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
            outageBadge.isHidden = true
            operatorBadge.isHidden = true
        } else {
            let isAntenna = payload.kind == .antenna
            let size = isAntenna ? Self.antennaDotSize : Self.otherDotSize
            let reach = isAntenna ? payload.azimuthReachPoints : 0
            resize(to: size, radius: max(reach, Self.minRadius))
            // Un marqueur de panne est posé À CÔTÉ du point d'antenne, quelle que
            // soit la source (cf. `communityOutageOffset` / `operatorIncidentOffset`).
            // Un cluster, lui, siège au barycentre d'un groupe et ne désigne aucun
            // pylône : le décaler ne ferait que le détacher de ce qu'il résume.
            //
            // APRÈS `resize`, obligatoirement : celui-ci remet `centerOffset` à zéro
            // — ce qui est aussi ce qui purge le décalage d'une vue RECYCLÉE, toutes
            // ces pastilles partageant un unique `reuseID`.
            switch payload.kind {
            case .communityOutage: centerOffset = Self.communityOutageOffset
            case .outage: centerOffset = Self.operatorIncidentOffset
            default: centerOffset = .zero
            }
            // Panne seulement signalée : pastille ÉVIDÉE à liseré coloré. Le
            // remplissage plein est réservé à ce que la communauté a corroboré —
            // sinon une voix isolée se lirait comme un fait établi. Réservé au
            // marqueur de panne : sur une antenne, la même donnée n'est qu'un
            // badge et ne doit rien changer au point lui-même.
            let outageMark = payload.kind == .communityOutage ? payload.communityOutage : nil
            let hollow = outageMark.map { !$0.confirmed } ?? false
            let fill = hollow ? Self.outlineColor : color
            dot.backgroundColor = fill
            dot.layer.borderColor = (hollow ? color : Self.outlineColor).cgColor
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
                // Sur une pastille évidée, le glyphe reprend la couleur de gravité :
                // c'est elle qui porte le sens, et le liseré seul ne suffirait pas
                // à la lire à cette taille.
                glyph.tintColor = hollow ? color : Self.ink(on: fill)
                glyph.isHidden = false
            }
            applyPie(payload, size: size, fallback: fill)
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
        // Le badge de panne n'est PAS réservé aux antennes officielles : un site posé à la main
        // en porte un aussi, et dans les marchés sans référentiel public c'est le seul point qui
        // le puisse. Seul le marqueur de panne lui-même s'en exclut — il EST la panne.
        let outageMark = payload.kind == .communityOutage ? nil : payload.communityOutage
        let incidentMark = payload.kind == .outage ? nil : payload.operatorIncident
        checkBadge.isHidden = !showsCheck
        photoBadge.isHidden = !showsPhoto
        outageBadge.isHidden = outageMark == nil
        operatorBadge.isHidden = incidentMark == nil
        guard showsCheck || showsPhoto || outageMark != nil || incidentMark != nil else { return }

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
        if let outageMark {
            // En haut à GAUCHE : les deux autres diagonales sont prises (coche eNB
            // en haut à droite, photos en bas à gauche), et le haut se remarque plus
            // que le bas — ce qui convient à un incident en cours.
            outageBadge.image = Self.outageBadgeImage(size: badge, severity: outageMark.severity)
            outageBadge.frame = CGRect(
                x: center.x - offset - badge / 2,
                y: center.y - offset - badge / 2,
                width: badge,
                height: badge
            )
        }
        if let incidentMark {
            // En bas à DROITE : la dernière diagonale libre, et la seule qui laisse les deux
            // badges de panne coexister sans se recouvrir — ce qui arrive précisément dans le cas
            // le plus intéressant, quand l'opérateur reconnaît ce que la communauté a signalé.
            operatorBadge.image = Self.operatorBadgeImage(size: badge, issueType: incidentMark.issueType)
            operatorBadge.frame = CGRect(
                x: center.x + offset - badge / 2,
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
    var outageBadgeIsHiddenForTesting: Bool { outageBadge.isHidden }
    var operatorBadgeIsHiddenForTesting: Bool { operatorBadge.isHidden }
    /// Les deux badges de panne peuvent coexister : leurs cadres sont ce qui prouve qu'ils ne se
    /// recouvrent pas, et donc qu'aucune des deux sources n'en masque une autre.
    var outageBadgeFrameForTesting: CGRect { outageBadge.frame }
    var operatorBadgeFrameForTesting: CGRect { operatorBadge.frame }
    var glyphColorForTesting: UIColor? { glyph.tintColor }

    static func glyphName(for p: MapAnnotationPayload) -> String {
        if let g = p.glyphOverride { return g }
        switch p.kind {
        case .antenna: return "antenna.radiowaves.left.and.right"
        case .photo: return "camera.fill"
        case .friend: return "person.fill"
        case .validation: return "checkmark.seal.fill"
        case .session: return "figure.walk"
        case .outage: return "exclamationmark.triangle.fill"
        // Le triangle est celui de l'opérateur : le point d'exclamation cerclé
        // dit la même urgence sans laisser croire que c'est la même source.
        case .communityOutage: return "exclamationmark.circle.fill"
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

    /// L'encre qu'un remplissage donné supporte : crème sur un aplat sombre, encre
    /// sur un aplat clair.
    ///
    /// Le glyphe était peint en `SQColor.onAccent` quelle que soit la pastille. Sur
    /// le jaune « dégradé » d'alors (#EAB308) ce crème tombait à ~1,8:1 — le
    /// pictogramme disparaissait purement et simplement, et le même défaut touchait
    /// le compteur des clusters. Le contraste ne peut pas être choisi une fois pour
    /// toutes : il se calcule contre ce qu'on peint réellement. Le cas d'origine a
    /// depuis disparu (l'ambre est passé à #B45309, cf. `OutageTint`) mais la règle
    /// reste : les couleurs d'opérateurs claires, elles, sont toujours là.
    ///
    /// Le résultat est lui-même un `UIColor` DYNAMIQUE, et c'est indispensable :
    /// `dot.backgroundColor` reçoit souvent une couleur à deux variantes
    /// (`SQColor.brand*`), qu'UIKit re-résout tout seul au basculement clair/sombre
    /// sans que la vue soit ré-appliquée. Une encre figée à l'instant d'`apply(_:)`
    /// resterait alors celle de l'ancien thème sur un fond qui, lui, a changé — le
    /// glyphe et le compteur de cluster viraient à l'illisible la nuit. Ici la
    /// DÉCISION se rejoue à chaque résolution, contre le remplissage réellement
    /// peint : la bascule du jaune reste acquise, en clair comme en sombre.
    static func ink(on fill: UIColor) -> UIColor {
        UIColor { traits in
            let painted = fill.resolvedColor(with: traits)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard painted.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return outlineColor }
            // Luminance relative WCAG : la moyenne naïve des canaux mettrait le jaune
            // et le bleu au même niveau, alors qu'ils n'ont rien à voir à l'œil.
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            // Le point d'égalité stricte des deux contrastes est vers 0,21, mais y
            // placer la bascule ferait passer à l'encre sombre des couleurs qui vont
            // très bien en crème (brique, rouge #EF4444) pour trois dixièmes de
            // rapport, et redessinerait le langage des marqueurs. Le seuil est donc le
            // point où le crème CESSE de tenir 3:1 : le crème a une luminance de
            // 0,933, donc (0,933 + 0,05) / 3 − 0,05.
            //
            // ⚠️ 3:1 est le plancher de WCAG 1.4.11, qui vise les objets graphiques.
            // Il vaut pour le pictogramme ; il ne vaut PAS pour le compteur de
            // cluster, qui est du texte de 12 pt gras — donc soumis au 4,5:1 de
            // WCAG 1.4.3. Sur les remplissages sombres qui frôlent le seuil, le
            // compteur crème reste en dessous : rouge #EF4444 le donne à 3,52:1.
            // C'est un manque assumé ici et pas ailleurs, parce que le corriger
            // demanderait un second seuil pour le texte, donc deux encres possibles
            // sur une même pastille selon qu'elle porte un chiffre ou un glyphe.
            //
            // Mesuré sur les couleurs réellement peintes : le seuil ne fait basculer
            // que TELUS #00A67E (2,91:1 en crème), Regional #D97706 (2,98) et la
            // brique/orange sombres #D97A66 (2,84) — soit exactement celles qui
            // échouaient. Orange #FF6B35, SRR et Zeop basculaient déjà. Tout le reste
            // (SFR, Bouygues, Free, Bell, Rogers, #EF4444, l'ambre #B45309…) garde
            // le crème.
            return luminance > 0.2775 ? badgeInkColor : outlineColor
        }
    }

    /// Pastille de panne communautaire accrochée au point d'antenne.
    ///
    /// Toujours pleine, même pour une panne non confirmée : à 14 pt, un disque évidé
    /// n'est plus qu'un anneau illisible. La nuance signalée / confirmée se lit sur
    /// le marqueur de plein droit et dans la feuille, où il y a la place de le dire.
    private static func outageBadgeImage(size: CGFloat, severity: OutageSeverity) -> UIImage {
        let fill = UIColor(OutageTint.of(severity))
        return cachedImage("outage-\(severity.rawValue)-\(Int(size.rounded()))") {
            badgeImage(
                size: size,
                fill: fill,
                symbol: "exclamationmark",
                symbolColor: ink(on: fill)
            )
        }
    }

    /// Badge d'incident DÉCLARÉ PAR L'OPÉRATEUR, accroché au point d'antenne.
    ///
    /// Un TRIANGLE, là où le signalement communautaire est un disque. C'est la seule chose qui
    /// distingue les deux à 14 pt, et c'est la distinction que toute la fonctionnalité cherche à
    /// établir : la couleur dit la gravité, la forme dit qui l'affirme. Sans glyphe à l'intérieur
    /// — à cette taille, un pictogramme dans un triangle n'est plus qu'une tache, alors que la
    /// silhouette, elle, reste lisible.
    private static func operatorBadgeImage(size: CGFloat, issueType: String) -> UIImage {
        let fill = UIColor(OperatorIncidentCard.tint(for: issueType))
        return cachedImage("operator-incident-\(issueType)-\(Int(size.rounded()))") {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            return renderer.image { context in
                let cg = context.cgContext
                // Deux triangles concentriques plutôt qu'un tracé bordé : un `stroke` déborde de
                // moitié hors du chemin et rognerait les pointes au bord de l'image.
                func triangle(inset: CGFloat) -> UIBezierPath {
                    let path = UIBezierPath()
                    let side = size - inset * 2
                    // Le triangle est recentré verticalement sur son barycentre : posé sur sa
                    // base, il paraît glisser vers le bas du badge.
                    let top = inset + side * 0.06
                    let bottom = inset + side * 0.94
                    path.move(to: CGPoint(x: size / 2, y: top))
                    path.addLine(to: CGPoint(x: inset + side, y: bottom))
                    path.addLine(to: CGPoint(x: inset, y: bottom))
                    path.close()
                    return path
                }
                cg.setFillColor(outlineColor.cgColor)
                triangle(inset: 0).fill()
                cg.setFillColor(fill.cgColor)
                triangle(inset: 2).fill()
            }
        }
    }

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
