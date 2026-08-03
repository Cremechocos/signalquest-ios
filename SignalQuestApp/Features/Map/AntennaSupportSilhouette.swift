import SwiftUI

/// Silhouettes des supports d'antenne, dessinées d'après la nature ANFR du site.
///
/// Un profil radio qui termine sur un trait vertical anonyme n'apprend rien : sur
/// le terrain, on cherche un objet précis — un pylône treillis, un château d'eau,
/// le toit d'un immeuble. Dessiner le bon support, à sa hauteur réelle et avec
/// ses antennes à la leur, transforme un graphe en repère visuel.
enum AntennaSupportSilhouette {
    enum Family {
        case lattice      // pylône treillis, autoportant, autostable, tour hertzienne
        case guyed        // pylône haubané
        case tube         // pylône tubulaire, mât, fût
        case building     // bâtiment, immeuble, HLM, dalle, local technique
        case waterTower   // château d'eau, silo, réservoir
        case steeple      // monument religieux ou historique
        case tree         // pylône arbre
        case turbine      // éolienne
        case indoor       // galerie, sous-terrain, tunnel : rien à dresser
    }

    /// Familles déduites du LIBELLÉ ANFR résolu par le backend
    /// (`ANFR_SUPPORT_NATURE_LABELS`). On compare sur des fragments minuscules et
    /// sans accent plutôt que sur des égalités strictes : les libellés varient
    /// d'un marché à l'autre, et un support mal reconnu doit retomber sur le
    /// pylône générique, pas disparaître.
    static func family(for label: String?) -> Family {
        guard let label = label?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil),
              !label.isEmpty else { return .lattice }
        if label.contains("galerie") || label.contains("terrain") || label.contains("tunnel") { return .indoor }
        if label.contains("chateau") || label.contains("reservoir") || label.contains("silo") { return .waterTower }
        if label.contains("religieux") || label.contains("historique") { return .steeple }
        if label.contains("arbre") { return .tree }
        if label.contains("eolienne") { return .turbine }
        if label.contains("haubane") { return .guyed }
        if label.contains("tubulaire") || label.contains("mat") || label.contains("fut") { return .tube }
        if label.contains("batiment") || label.contains("immeuble") || label.contains("local")
            || label.contains("dalle") || label.contains("ouvrage") || label.contains("mobilier") { return .building }
        return .lattice
    }

    /// Nom court affiché sous le support, quand le libellé ANFR est absent.
    static func fallbackLabel(for family: Family) -> String {
        switch family {
        case .lattice: return String(localized: "Pylône")
        case .guyed: return String(localized: "Pylône haubané")
        case .tube: return String(localized: "Mât")
        case .building: return String(localized: "Bâtiment")
        case .waterTower: return String(localized: "Château d'eau")
        case .steeple: return String(localized: "Clocher")
        case .tree: return String(localized: "Pylône arbre")
        case .turbine: return String(localized: "Éolienne")
        case .indoor: return String(localized: "Intérieur")
        }
    }

    /// Largeur de la structure à une hauteur donnée (`ratio` = 0 au sol, 1 au
    /// sommet). Sert à poser les antennes SUR le fût plutôt qu'à côté : un pylône
    /// s'affine en montant, un bâtiment non.
    static func width(family: Family, at ratio: CGFloat, baseWidth: CGFloat) -> CGFloat {
        let clamped = min(max(ratio, 0), 1)
        switch family {
        case .lattice:
            // Même interpolation que les montants : de `half` au sol à `0.3 · half`.
            return baseWidth * (1 + (0.3 - 1) * clamped)
        case .guyed, .tube, .tree, .turbine:
            return baseWidth * 0.5
        case .waterTower:
            return clamped > 0.6 ? baseWidth : baseWidth * 0.6
        case .steeple:
            return baseWidth * (clamped > 0.7 ? 0.5 : 1.2)
        case .building, .indoor:
            return baseWidth * 1.4
        }
    }

    /// Le support dessiné en TRAIT, du sol (`baseY`) à son sommet (`topY`).
    /// `width` est la largeur au sol. Les coordonnées sont en repère écran (Y vers
    /// le bas), prêtes à être tracées dans le `Canvas` du profil.
    static func strokePath(family: Family, baseX: CGFloat, baseY: CGFloat, topY: CGFloat, width: CGFloat) -> Path {
        var path = Path()
        let height = max(baseY - topY, 1)
        let half = max(width / 2, 2)

        switch family {
        case .indoor:
            // Pas de structure à dresser : un trait au sol et une flèche vers le bas.
            path.move(to: CGPoint(x: baseX - half, y: baseY))
            path.addLine(to: CGPoint(x: baseX + half, y: baseY))
            path.move(to: CGPoint(x: baseX, y: baseY - height * 0.25))
            path.addLine(to: CGPoint(x: baseX, y: baseY))
            return path

        case .lattice:
            let topHalf = max(half * 0.3, 1.5)
            path.move(to: CGPoint(x: baseX - half, y: baseY))
            path.addLine(to: CGPoint(x: baseX - topHalf, y: topY))
            path.move(to: CGPoint(x: baseX + half, y: baseY))
            path.addLine(to: CGPoint(x: baseX + topHalf, y: topY))
            // Traverses et croisillons : ce sont eux qui donnent la lecture
            // « treillis » plutôt que « poteau ».
            let levels = max(3, min(7, Int(height / 22)))
            for index in 0...levels {
                let ratio = CGFloat(index) / CGFloat(levels)
                let y = baseY - height * ratio
                let w = half + (topHalf - half) * ratio
                path.move(to: CGPoint(x: baseX - w, y: y))
                path.addLine(to: CGPoint(x: baseX + w, y: y))
                guard index < levels else { continue }
                let nextRatio = CGFloat(index + 1) / CGFloat(levels)
                let nextY = baseY - height * nextRatio
                let nextW = half + (topHalf - half) * nextRatio
                path.move(to: CGPoint(x: baseX - w, y: y))
                path.addLine(to: CGPoint(x: baseX + nextW, y: nextY))
                path.move(to: CGPoint(x: baseX + w, y: y))
                path.addLine(to: CGPoint(x: baseX - nextW, y: nextY))
            }

        case .guyed:
            path.move(to: CGPoint(x: baseX, y: baseY))
            path.addLine(to: CGPoint(x: baseX, y: topY))
            for side in [-1.0, 1.0] as [CGFloat] {
                path.move(to: CGPoint(x: baseX, y: topY + height * 0.12))
                path.addLine(to: CGPoint(x: baseX + side * half * 2.4, y: baseY))
                path.move(to: CGPoint(x: baseX, y: topY + height * 0.45))
                path.addLine(to: CGPoint(x: baseX + side * half * 1.7, y: baseY))
            }

        case .tube:
            path.move(to: CGPoint(x: baseX - half * 0.55, y: baseY))
            path.addLine(to: CGPoint(x: baseX - half * 0.3, y: topY))
            path.addLine(to: CGPoint(x: baseX + half * 0.3, y: topY))
            path.addLine(to: CGPoint(x: baseX + half * 0.55, y: baseY))

        case .building:
            let roofY = topY
            path.addRect(CGRect(x: baseX - half, y: roofY, width: half * 2, height: baseY - roofY))
            // Rangées de fenêtres, tant qu'il reste la place de les lire.
            let floors = max(1, min(6, Int((baseY - roofY) / 14)))
            for floor in 1...floors {
                let y = roofY + (baseY - roofY) * CGFloat(floor) / CGFloat(floors + 1)
                for column in 0..<3 {
                    let x = baseX - half + half * 0.4 + CGFloat(column) * half * 0.6
                    path.addRect(CGRect(x: x, y: y, width: max(half * 0.22, 1.5), height: max(half * 0.3, 2)))
                }
            }

        case .waterTower:
            let bowlHeight = height * 0.34
            let bowlY = topY + bowlHeight
            path.move(to: CGPoint(x: baseX - half * 0.35, y: baseY))
            path.addLine(to: CGPoint(x: baseX - half * 0.28, y: bowlY))
            path.move(to: CGPoint(x: baseX + half * 0.35, y: baseY))
            path.addLine(to: CGPoint(x: baseX + half * 0.28, y: bowlY))
            path.move(to: CGPoint(x: baseX - half, y: bowlY))
            path.addLine(to: CGPoint(x: baseX - half * 0.78, y: topY))
            path.addLine(to: CGPoint(x: baseX + half * 0.78, y: topY))
            path.addLine(to: CGPoint(x: baseX + half, y: bowlY))
            path.closeSubpath()

        case .steeple:
            let spireY = topY + height * 0.3
            path.move(to: CGPoint(x: baseX - half * 0.7, y: baseY))
            path.addLine(to: CGPoint(x: baseX - half * 0.7, y: spireY))
            path.addLine(to: CGPoint(x: baseX, y: topY))
            path.addLine(to: CGPoint(x: baseX + half * 0.7, y: spireY))
            path.addLine(to: CGPoint(x: baseX + half * 0.7, y: baseY))
            path.move(to: CGPoint(x: baseX - half * 0.35, y: spireY + height * 0.18))
            path.addLine(to: CGPoint(x: baseX + half * 0.35, y: spireY + height * 0.18))

        case .tree:
            path.move(to: CGPoint(x: baseX - half * 0.3, y: baseY))
            path.addLine(to: CGPoint(x: baseX - half * 0.16, y: topY + height * 0.2))
            path.move(to: CGPoint(x: baseX + half * 0.3, y: baseY))
            path.addLine(to: CGPoint(x: baseX + half * 0.16, y: topY + height * 0.2))
            for level in 0..<3 {
                let ratio = 0.2 + CGFloat(level) * 0.22
                let y = topY + height * ratio
                let w = half * (1.0 - CGFloat(level) * 0.22)
                path.move(to: CGPoint(x: baseX - w, y: y))
                path.addLine(to: CGPoint(x: baseX, y: y - height * 0.16))
                path.addLine(to: CGPoint(x: baseX + w, y: y))
            }

        case .turbine:
            path.move(to: CGPoint(x: baseX - half * 0.4, y: baseY))
            path.addLine(to: CGPoint(x: baseX - half * 0.16, y: topY))
            path.move(to: CGPoint(x: baseX + half * 0.4, y: baseY))
            path.addLine(to: CGPoint(x: baseX + half * 0.16, y: topY))
            for angle in [90.0, 210.0, 330.0] as [Double] {
                let radians = angle * .pi / 180
                path.move(to: CGPoint(x: baseX, y: topY))
                path.addLine(to: CGPoint(
                    x: baseX + cos(radians) * half * 1.8,
                    y: topY - sin(radians) * half * 1.8
                ))
            }
        }
        return path
    }

    /// Les antennes posées à `antennaY`. Panneaux par défaut ; une parabole est
    /// ajoutée quand le site en déclare une (`types_antennes` ANFR).
    static func antennaPath(
        antennaTypes: [String],
        centerX: CGFloat,
        antennaY: CGFloat,
        width: CGFloat
    ) -> (panels: Path, dish: Path?) {
        let half = max(width / 2, 3)
        let panelHeight = max(width * 0.75, 7)
        var panels = Path()
        for offset in [-1.15, 0.0, 1.15] as [CGFloat] {
            let x = centerX + offset * half * 0.9
            panels.addRoundedRect(
                in: CGRect(x: x - max(width * 0.09, 1.2), y: antennaY - panelHeight, width: max(width * 0.18, 2.4), height: panelHeight),
                cornerSize: CGSize(width: 1.2, height: 1.2)
            )
        }
        let normalized = antennaTypes
            .map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        let hasDish = normalized.contains { $0.contains("parabol") || $0.contains("cornet") }
        guard hasDish else { return (panels, nil) }
        var dish = Path()
        let radius = max(width * 0.34, 4)
        dish.addEllipse(in: CGRect(
            x: centerX - half * 1.5 - radius,
            y: antennaY + panelHeight * 0.25 - radius,
            width: radius * 2,
            height: radius * 2
        ))
        return (panels, dish)
    }
}
