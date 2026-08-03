import SwiftUI

/// Les schémas du glossaire.
///
/// Une définition écrite explique ce qu'est une grandeur ; un schéma montre
/// *où* elle se situe. Pour le dégagement de Fresnel notamment, la question
/// n'est pas « qu'est-ce que c'est » mais « qu'est-ce qui gêne, et où » — et ça,
/// seul un dessin le dit. Quand la donnée du site est disponible, le schéma la
/// reprend plutôt que d'illustrer un cas générique.
enum AntennaGlossaryIllustration: Equatable {
    /// Le fuseau de Fresnel au-dessus du relief réel, avec le point le plus serré
    /// pointé du doigt.
    case fresnelClearance(profile: [AntennaSightGeometry.ProfilePoint])
    /// La droite entre l'observateur et l'antenne, coupée ou non.
    case lineOfSight(profile: [AntennaSightGeometry.ProfilePoint], blocked: Bool)
    /// Le fuseau seul : large au milieu, pincé aux extrémités, et l'effet de la
    /// fréquence sur sa taille.
    case fresnelShape(frequencyMhz: Double)
    /// Une antenne inclinée vers son point de couverture.
    case downtilt(degrees: Double)
    /// Deux sols d'altitudes différentes.
    case elevationGap(userMeters: Double, siteMeters: Double)
    /// Le support et ses antennes, cotés.
    case heights(supportMeters: Double?, antennaMeters: Double?, supportLabel: String?)
}

struct AntennaGlossaryIllustrationView: View {
    let illustration: AntennaGlossaryIllustration
    var tint: Color = SQColor.brandRed

    var body: some View {
        Canvas { context, size in
            switch illustration {
            case .fresnelClearance(let profile):
                drawFresnelClearance(context: context, size: size, profile: profile)
            case .lineOfSight(let profile, let blocked):
                drawLineOfSight(context: context, size: size, profile: profile, blocked: blocked)
            case .fresnelShape(let frequency):
                drawFresnelShape(context: context, size: size, frequencyMhz: frequency)
            case .downtilt(let degrees):
                drawDowntilt(context: context, size: size, degrees: degrees)
            case .elevationGap(let user, let site):
                drawElevationGap(context: context, size: size, userMeters: user, siteMeters: site)
            case .heights(let support, let antenna, let label):
                drawHeights(context: context, size: size, support: support, antenna: antenna, label: label)
            }
        }
        .frame(height: illustration.preferredHeight)
        .frame(maxWidth: .infinity)
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityLabel(illustration.accessibilityLabel)
    }

    // MARK: Fresnel sur le relief réel

    private func drawFresnelClearance(
        context: GraphicsContext,
        size: CGSize,
        profile: [AntennaSightGeometry.ProfilePoint]
    ) {
        guard profile.count > 2 else { return }
        let inset: CGFloat = 16
        let bottom = size.height - 26
        let values = profile.flatMap { [$0.obstacleMeters, $0.sightLineMeters + $0.fresnelRadiusMeters] }
        guard let low = values.min(), let high = values.max(), high > low else { return }
        let total = max(profile.last?.distanceMeters ?? 1, 1)

        func x(_ d: Double) -> CGFloat { inset + (size.width - inset * 2) * d / total }
        func y(_ v: Double) -> CGFloat { bottom - (v - low) / (high - low) * (bottom - 14) }

        // Fuseau complet, au-dessus ET au-dessous de la droite : c'est bien un
        // volume qui entoure la ligne, pas une marge posée dessous.
        var envelope = Path()
        envelope.move(to: CGPoint(x: x(profile[0].distanceMeters), y: y(profile[0].sightLineMeters)))
        for p in profile.dropFirst() {
            envelope.addLine(to: CGPoint(x: x(p.distanceMeters), y: y(p.sightLineMeters + p.fresnelRadiusMeters)))
        }
        for p in profile.reversed() {
            envelope.addLine(to: CGPoint(x: x(p.distanceMeters), y: y(p.sightLineMeters - p.fresnelRadiusMeters)))
        }
        envelope.closeSubpath()
        context.fill(envelope, with: .color(tint.opacity(0.14)))

        var ground = Path()
        ground.move(to: CGPoint(x: inset, y: bottom))
        for p in profile { ground.addLine(to: CGPoint(x: x(p.distanceMeters), y: y(p.obstacleMeters))) }
        ground.addLine(to: CGPoint(x: size.width - inset, y: bottom))
        ground.closeSubpath()
        context.fill(ground, with: .color(SQColor.labelSecondary.opacity(0.3)))

        var sight = Path()
        sight.move(to: CGPoint(x: x(profile[0].distanceMeters), y: y(profile[0].sightLineMeters)))
        for p in profile.dropFirst() {
            sight.addLine(to: CGPoint(x: x(p.distanceMeters), y: y(p.sightLineMeters)))
        }
        context.stroke(sight, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))

        // Le point le plus serré : celui qui décide du chiffre affiché.
        let interior = profile.dropFirst().dropLast().filter { $0.fresnelRadiusMeters > 0 }
        guard let worst = interior.min(by: {
            $0.clearanceMeters / $0.fresnelRadiusMeters < $1.clearanceMeters / $1.fresnelRadiusMeters
        }) else { return }
        let px = x(worst.distanceMeters)
        let ratio = worst.clearanceMeters / worst.fresnelRadiusMeters
        let color: Color = ratio < 0 ? SQColor.danger : (ratio < 0.6 ? SQColor.warning : SQColor.success)

        var bracket = Path()
        bracket.move(to: CGPoint(x: px, y: y(worst.obstacleMeters)))
        bracket.addLine(to: CGPoint(x: px, y: y(worst.sightLineMeters)))
        context.stroke(bracket, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.fill(
            Path(ellipseIn: CGRect(x: px - 3.5, y: y(worst.obstacleMeters) - 3.5, width: 7, height: 7)),
            with: .color(color)
        )
        context.draw(
            Text(ratio < 0 ? "coupé ici" : "au plus serré ici")
                .font(SQFont.archivo(9.5, .bold))
                .foregroundColor(color),
            at: CGPoint(x: min(max(px, 46), size.width - 46), y: bottom + 13)
        )
        context.draw(
            Text("toi").font(SQFont.archivo(9, .semibold)).foregroundColor(SQColor.labelSecondary),
            at: CGPoint(x: inset + 8, y: bottom + 13)
        )
        context.draw(
            Text("site").font(SQFont.archivo(9, .semibold)).foregroundColor(SQColor.labelSecondary),
            at: CGPoint(x: size.width - inset - 10, y: bottom + 13)
        )
    }

    // MARK: Ligne de visée

    private func drawLineOfSight(
        context: GraphicsContext,
        size: CGSize,
        profile: [AntennaSightGeometry.ProfilePoint],
        blocked: Bool
    ) {
        guard profile.count > 2 else { return }
        let inset: CGFloat = 16
        let bottom = size.height - 22
        let values = profile.flatMap { [$0.obstacleMeters, $0.sightLineMeters] }
        guard let low = values.min(), let high = values.max(), high > low else { return }
        let total = max(profile.last?.distanceMeters ?? 1, 1)
        func x(_ d: Double) -> CGFloat { inset + (size.width - inset * 2) * d / total }
        func y(_ v: Double) -> CGFloat { bottom - (v - low) / (high - low) * (bottom - 16) }

        var ground = Path()
        ground.move(to: CGPoint(x: inset, y: bottom))
        for p in profile { ground.addLine(to: CGPoint(x: x(p.distanceMeters), y: y(p.obstacleMeters))) }
        ground.addLine(to: CGPoint(x: size.width - inset, y: bottom))
        ground.closeSubpath()
        context.fill(ground, with: .color(SQColor.labelSecondary.opacity(0.3)))

        var sight = Path()
        sight.move(to: CGPoint(x: x(profile[0].distanceMeters), y: y(profile[0].sightLineMeters)))
        for p in profile.dropFirst() {
            sight.addLine(to: CGPoint(x: x(p.distanceMeters), y: y(p.sightLineMeters)))
        }
        context.stroke(
            sight,
            with: .color(blocked ? SQColor.danger : SQColor.success),
            style: StrokeStyle(lineWidth: 2, dash: blocked ? [3, 3] : [])
        )

        if blocked, let hit = profile.dropFirst().dropLast().min(by: { $0.clearanceMeters < $1.clearanceMeters }) {
            let px = x(hit.distanceMeters)
            let py = y(hit.obstacleMeters)
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: px - 7, y: py - 7))
                    p.addLine(to: CGPoint(x: px + 7, y: py + 7))
                    p.move(to: CGPoint(x: px + 7, y: py - 7))
                    p.addLine(to: CGPoint(x: px - 7, y: py + 7))
                },
                with: .color(SQColor.danger),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
            )
        }
        drawStickFigure(context: context, x: inset + 4, groundY: y(profile[0].groundMeters))
        drawMast(context: context, x: size.width - inset - 6, groundY: bottom, topY: y(profile.last?.sightLineMeters ?? 0))
    }

    // MARK: Forme du fuseau

    private func drawFresnelShape(context: GraphicsContext, size: CGSize, frequencyMhz: Double) {
        let inset: CGFloat = 20
        let midY = size.height / 2 - 6
        let left = CGPoint(x: inset, y: midY)
        let right = CGPoint(x: size.width - inset, y: midY)
        let maxRadius: CGFloat = min(size.height / 2 - 22, 34)

        // Le fuseau : nul aux extrémités, maximal au milieu — √(d1·d2) donne
        // cette forme de ballon de rugby.
        func radius(at t: CGFloat) -> CGFloat { maxRadius * sqrt(max(t * (1 - t), 0) * 4) }
        var envelope = Path()
        envelope.move(to: left)
        for step in 0...40 {
            let t = CGFloat(step) / 40
            envelope.addLine(to: CGPoint(x: left.x + (right.x - left.x) * t, y: midY - radius(at: t)))
        }
        for step in stride(from: 40, through: 0, by: -1) {
            let t = CGFloat(step) / 40
            envelope.addLine(to: CGPoint(x: left.x + (right.x - left.x) * t, y: midY + radius(at: t)))
        }
        envelope.closeSubpath()
        context.fill(envelope, with: .color(tint.opacity(0.16)))
        context.stroke(envelope, with: .color(tint.opacity(0.5)), lineWidth: 1)

        var line = Path()
        line.move(to: left)
        line.addLine(to: right)
        context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))

        // Cote du rayon maximal, à mi-parcours.
        let midX = (left.x + right.x) / 2
        var arrow = Path()
        arrow.move(to: CGPoint(x: midX, y: midY))
        arrow.addLine(to: CGPoint(x: midX, y: midY - maxRadius))
        arrow.move(to: CGPoint(x: midX - 4, y: midY - maxRadius))
        arrow.addLine(to: CGPoint(x: midX + 4, y: midY - maxRadius))
        context.stroke(arrow, with: .color(SQColor.label), lineWidth: 1.2)
        context.draw(
            Text("rayon max.").font(SQFont.archivo(9, .bold)).foregroundColor(SQColor.label),
            at: CGPoint(x: midX + 34, y: midY - maxRadius / 2)
        )

        drawStickFigure(context: context, x: left.x, groundY: midY + maxRadius + 16)
        drawMast(context: context, x: right.x, groundY: midY + maxRadius + 16, topY: midY)
        context.draw(
            Text("\(Int(frequencyMhz)) MHz — plus la fréquence monte, plus le fuseau s'affine")
                .font(SQFont.archivo(9, .semibold))
                .foregroundColor(SQColor.labelSecondary),
            at: CGPoint(x: size.width / 2, y: size.height - 8)
        )
    }

    // MARK: Tilt

    private func drawDowntilt(context: GraphicsContext, size: CGSize, degrees: Double) {
        let groundY = size.height - 24
        let mastX: CGFloat = size.width - 46
        let topY: CGFloat = 22
        drawMast(context: context, x: mastX, groundY: groundY, topY: topY)
        drawStickFigure(context: context, x: 30, groundY: groundY)

        // Horizontale de référence, puis faisceau incliné vers l'observateur.
        var horizon = Path()
        horizon.move(to: CGPoint(x: mastX, y: topY))
        horizon.addLine(to: CGPoint(x: 24, y: topY))
        context.stroke(horizon, with: .color(SQColor.separator), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        var beam = Path()
        beam.move(to: CGPoint(x: mastX, y: topY))
        beam.addLine(to: CGPoint(x: 30, y: groundY - 12))
        context.stroke(beam, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // Secteur d'angle entre l'horizontale et le faisceau.
        let angle = atan2(groundY - 12 - topY, mastX - 30)
        var wedge = Path()
        wedge.move(to: CGPoint(x: mastX, y: topY))
        wedge.addArc(
            center: CGPoint(x: mastX, y: topY), radius: 40,
            startAngle: .radians(.pi), endAngle: .radians(.pi + angle), clockwise: false
        )
        wedge.closeSubpath()
        context.fill(wedge, with: .color(tint.opacity(0.18)))

        let label = String(format: "%.1f", abs(degrees)).replacingOccurrences(of: ".", with: ",")
        context.draw(
            Text("\(label)°").font(SQFont.archivo(11, .bold)).foregroundColor(tint),
            at: CGPoint(x: mastX - 54, y: topY + 16)
        )
        context.draw(
            Text("l'antenne pique vers toi").font(SQFont.archivo(9, .semibold)).foregroundColor(SQColor.labelSecondary),
            at: CGPoint(x: size.width / 2, y: size.height - 8)
        )
    }

    // MARK: Dénivelé

    private func drawElevationGap(context: GraphicsContext, size: CGSize, userMeters: Double, siteMeters: Double) {
        let inset: CGFloat = 24
        let bottom = size.height - 22
        let delta = siteMeters - userMeters
        let magnitude = max(abs(delta), 1)
        let scale = min((bottom - 40) / magnitude, 3)
        let userY = delta >= 0 ? bottom : bottom - CGFloat(magnitude) * scale
        let siteY = delta >= 0 ? bottom - CGFloat(magnitude) * scale : bottom

        var terrain = Path()
        terrain.move(to: CGPoint(x: inset, y: size.height))
        terrain.addLine(to: CGPoint(x: inset, y: userY))
        terrain.addLine(to: CGPoint(x: size.width / 2 - 20, y: userY))
        terrain.addCurve(
            to: CGPoint(x: size.width / 2 + 20, y: siteY),
            control1: CGPoint(x: size.width / 2, y: userY),
            control2: CGPoint(x: size.width / 2, y: siteY)
        )
        terrain.addLine(to: CGPoint(x: size.width - inset, y: siteY))
        terrain.addLine(to: CGPoint(x: size.width - inset, y: size.height))
        terrain.closeSubpath()
        context.fill(terrain, with: .color(SQColor.labelSecondary.opacity(0.3)))

        drawStickFigure(context: context, x: inset + 16, groundY: userY)
        drawMast(context: context, x: size.width - inset - 18, groundY: siteY, topY: siteY - 34)

        var cote = Path()
        cote.move(to: CGPoint(x: size.width / 2, y: userY))
        cote.addLine(to: CGPoint(x: size.width / 2, y: siteY))
        context.stroke(cote, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
        let sign = delta >= 0 ? "+" : "−"
        context.draw(
            Text("\(sign)\(Int(abs(delta).rounded())) m").font(SQFont.archivo(10, .bold)).foregroundColor(tint),
            at: CGPoint(x: size.width / 2 + 24, y: (userY + siteY) / 2)
        )
    }

    // MARK: Hauteurs

    private func drawHeights(
        context: GraphicsContext,
        size: CGSize,
        support: Double?,
        antenna: Double?,
        label: String?
    ) {
        let groundY = size.height - 26
        let topY: CGFloat = 20
        let mastX = size.width / 2
        let structure = max(support ?? antenna ?? 1, 1)
        let antennaRatio = CGFloat(min((antenna ?? structure) / structure, 1))
        let antennaY = groundY - (groundY - topY) * antennaRatio

        var soil = Path()
        soil.move(to: CGPoint(x: 12, y: groundY))
        soil.addLine(to: CGPoint(x: size.width - 12, y: groundY))
        context.stroke(soil, with: .color(SQColor.labelSecondary.opacity(0.5)), lineWidth: 1.5)

        let family = AntennaSupportSilhouette.family(for: label)
        let width = max(min((groundY - topY) * 0.2, 40), 18)
        context.stroke(
            AntennaSupportSilhouette.strokePath(family: family, baseX: mastX, baseY: groundY, topY: topY, width: width),
            with: .color(tint),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
        let panels = AntennaSupportSilhouette.antennaPath(
            antennaTypes: [], centerX: mastX, antennaY: antennaY,
            width: AntennaSupportSilhouette.width(family: family, at: antennaRatio, baseWidth: width)
        )
        context.fill(panels.panels, with: .color(tint))

        // Deux cotes, de part et d'autre : la structure à droite, le point de
        // rayonnement à gauche. C'est ici qu'elles ont leur place, plutôt que
        // dans le profil où elles mangeaient la largeur du terrain.
        drawCote(context: context, x: mastX + width * 0.6 + 22, from: groundY, to: topY,
                 label: support.map { "\(Int($0.rounded())) m" } ?? "—", color: SQColor.labelSecondary)
        if let antenna, support == nil || abs((support ?? 0) - antenna) > 0.5 {
            drawCote(context: context, x: mastX - width * 0.6 - 22, from: groundY, to: antennaY,
                     label: "\(Int(antenna.rounded())) m", color: tint)
        }
        context.draw(
            Text("support").font(SQFont.archivo(9, .semibold)).foregroundColor(SQColor.labelSecondary),
            at: CGPoint(x: mastX + width * 0.6 + 22, y: size.height - 8)
        )
        context.draw(
            Text("antennes").font(SQFont.archivo(9, .semibold)).foregroundColor(tint),
            at: CGPoint(x: mastX - width * 0.6 - 22, y: size.height - 8)
        )
    }

    private func drawCote(context: GraphicsContext, x: CGFloat, from: CGFloat, to: CGFloat, label: String, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: from))
        path.addLine(to: CGPoint(x: x, y: to))
        for end in [from, to] {
            path.move(to: CGPoint(x: x - 3, y: end))
            path.addLine(to: CGPoint(x: x + 3, y: end))
        }
        context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1)
        let middle = CGPoint(x: x, y: (from + to) / 2)
        context.fill(
            Path(roundedRect: CGRect(x: middle.x - 17, y: middle.y - 7, width: 34, height: 14), cornerRadius: 4),
            with: .color(SQColor.surface)
        )
        context.draw(Text(label).font(SQFont.archivo(9.5, .bold)).foregroundColor(color), at: middle)
    }

    // MARK: Motifs partagés

    private func drawStickFigure(context: GraphicsContext, x: CGFloat, groundY: CGFloat) {
        var body = Path()
        let height: CGFloat = 16
        let head: CGFloat = 3
        let top = groundY - height
        body.addEllipse(in: CGRect(x: x - head, y: top, width: head * 2, height: head * 2))
        body.move(to: CGPoint(x: x, y: top + head * 2))
        body.addLine(to: CGPoint(x: x, y: groundY - height * 0.34))
        body.move(to: CGPoint(x: x - 4, y: top + height * 0.44))
        body.addLine(to: CGPoint(x: x + 4, y: top + height * 0.44))
        body.move(to: CGPoint(x: x, y: groundY - height * 0.34))
        body.addLine(to: CGPoint(x: x - 3.5, y: groundY))
        body.move(to: CGPoint(x: x, y: groundY - height * 0.34))
        body.addLine(to: CGPoint(x: x + 3.5, y: groundY))
        context.stroke(body, with: .color(SQColor.label), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func drawMast(context: GraphicsContext, x: CGFloat, groundY: CGFloat, topY: CGFloat) {
        let width = max(min((groundY - topY) * 0.24, 20), 9)
        context.stroke(
            AntennaSupportSilhouette.strokePath(family: .lattice, baseX: x, baseY: groundY, topY: topY, width: width),
            with: .color(tint),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )
        let panels = AntennaSupportSilhouette.antennaPath(
            antennaTypes: [], centerX: x, antennaY: topY + 3,
            width: AntennaSupportSilhouette.width(family: .lattice, at: 1, baseWidth: width)
        )
        context.fill(panels.panels, with: .color(tint))
    }
}

extension AntennaGlossaryIllustration {
    var preferredHeight: CGFloat {
        switch self {
        case .fresnelClearance: return 150
        case .lineOfSight: return 130
        case .fresnelShape: return 140
        case .downtilt: return 140
        case .elevationGap: return 130
        case .heights: return 160
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .fresnelClearance:
            return String(localized: "Schéma du fuseau de Fresnel au-dessus du relief, avec le point le plus serré du trajet")
        case .lineOfSight(_, let blocked):
            return blocked
                ? String(localized: "Schéma d'une ligne de visée coupée par un obstacle")
                : String(localized: "Schéma d'une ligne de visée dégagée")
        case .fresnelShape:
            return String(localized: "Schéma du fuseau de Fresnel, large au milieu et pincé aux extrémités")
        case .downtilt:
            return String(localized: "Schéma d'une antenne inclinée vers son point de couverture")
        case .elevationGap:
            return String(localized: "Schéma du dénivelé entre ta position et le site")
        case .heights:
            return String(localized: "Schéma du support et de la hauteur de ses antennes")
        }
    }
}
