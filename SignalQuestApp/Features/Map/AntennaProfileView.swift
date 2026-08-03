import SwiftUI

/// Le profil d'altitude en grand : le relief entre l'observateur et l'antenne,
/// le bâti, la ligne de visée, la première zone de Fresnel — et le support
/// dessiné à sa hauteur réelle, avec ses antennes à la leur.
///
/// Ce que le graphe permet de voir, et que le verdict d'une ligne ne dit pas :
/// *où* ça bloque. Une crête à 300 m et un immeuble à 30 m se corrigent
/// différemment — on se déplace pour l'une, on traverse la rue pour l'autre.
struct AntennaProfileView: View {
    let profile: [AntennaSightGeometry.ProfilePoint]
    let verdict: AntennaSightGeometry.SightVerdict?
    let siteLabel: String
    let distanceMeters: Double
    /// Hauteur de rayonnement des antennes (m au-dessus du sol du site).
    let antennaHeightMeters: Double?
    let heightIsEstimated: Bool
    /// Hauteur du support, quand elle diffère de celle des antennes.
    let supportHeightMeters: Double?
    /// Libellé ANFR de la nature du support (« Pylône treillis », « Château d'eau »…).
    let supportLabel: String?
    /// Types d'antennes ANFR déclarés sur le site (panneau, parabolique…).
    let antennaTypes: [String]
    let tint: Color
    /// Fréquence servant au calcul de Fresnel — la plus basse du site.
    var frequencyMhz: Double = 2100
    @State private var glossaryEntry: AntennaGlossaryEntry?
    @Environment(\.dismiss) private var dismiss

    private var userGround: Double? { profile.first?.groundMeters }
    private var antennaGround: Double? { profile.last?.groundMeters }
    private var family: AntennaSupportSilhouette.Family {
        AntennaSupportSilhouette.family(for: supportLabel)
    }
    /// Sommet du support : sa hauteur déclarée, ou à défaut celle des antennes.
    private var structureHeight: Double {
        max(supportHeightMeters ?? 0, antennaHeightMeters ?? 0, 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    chart
                        .frame(height: 330)
                        .frame(maxWidth: .infinity)
                        // Padding horizontal resserré : le graphe est déjà borné
                        // par ses propres marges internes, et deux niveaux de
                        // retrait laissaient une bande vide le long du cadre.
                        .padding(.vertical, SQSpace.md)
                        .padding(.horizontal, SQSpace.sm)
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                        .sqShadowCard()

                    legend
                    figures
                    caveat
                }
                .padding(SQSpace.lg + 2)
            }
            .signalQuestBackground()
            .navigationTitle("Profil d'altitude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $glossaryEntry) { entry in
            AntennaGlossarySheet(entry: entry)
        }
    }

    private var chart: some View {
        Canvas { context, size in
            guard profile.count > 1, let antennaGround, let userGround else { return }

            // L'échelle verticale doit contenir le relief, la ligne de visée ET
            // le sommet du support : un pylône qui sort du cadre serait pire que
            // pas de pylône du tout.
            var values = profile.flatMap { point in
                [point.obstacleMeters, point.sightLineMeters,
                 point.sightLineMeters - point.fresnelRadiusMeters * AntennaSightGeometry.fresnelClearanceRatio]
            }
            values.append(antennaGround + structureHeight)
            values.append(userGround)
            guard let rawMin = values.min(), let rawMax = values.max() else { return }
            // Juste ce qu'il faut au-dessus du sommet du support : au-delà, c'est
            // du vide qui écrase le relief en bas du cadre.
            let span = max(rawMax - rawMin, 1) * 1.02
            let minValue = rawMin
            let total = max(profile.last?.distanceMeters ?? 1, 1)

            // Juste de quoi loger la silhouette du support, dessinée à
            // l'extrémité du trajet. Ses hauteurs ne sont plus cotées ici : elles
            // figurent déjà dans les tuiles sous le graphe, et les cotes prenaient
            // une bande de largeur au détriment du profil lui-même.
            let leftInset: CGFloat = 40
            let rightInset: CGFloat = 26
            // Les deux étiquettes d'extrémité (nom puis altitude) et la ligne
            // d'échelle se superposaient : chacune a maintenant sa ligne.
            let bottomInset: CGFloat = 44
            let topInset: CGFloat = 6
            let plotWidth = size.width - leftInset - rightInset
            let plotHeight = size.height - bottomInset - topInset

            func x(_ distance: Double) -> CGFloat { leftInset + plotWidth * distance / total }
            func y(_ value: Double) -> CGFloat {
                size.height - bottomInset - (value - minValue) / span * plotHeight
            }
            func point(_ p: AntennaSightGeometry.ProfilePoint, _ value: Double) -> CGPoint {
                CGPoint(x: x(p.distanceMeters), y: y(value))
            }

            drawAltitudeAxis(context: context, size: size, minValue: minValue, span: span, leftInset: leftInset, y: y)

            // Relief. Il se prolonge jusqu'au bord droit du cadre en gardant
            // l'altitude du site : la marge réservée à la silhouette du support
            // laissait sinon un rectangle vide sous les antennes, comme si le sol
            // s'arrêtait au pied du pylône.
            var ground = Path()
            ground.move(to: CGPoint(x: leftInset, y: size.height - bottomInset))
            for p in profile { ground.addLine(to: point(p, p.groundMeters)) }
            if let last = profile.last {
                ground.addLine(to: CGPoint(x: size.width, y: y(last.groundMeters)))
            }
            ground.addLine(to: CGPoint(x: size.width, y: size.height - bottomInset))
            ground.closeSubpath()
            context.fill(ground, with: .color(SQColor.labelSecondary.opacity(0.26)))

            // Bâti par-dessus le relief, dessiné en blocs pour qu'on le lise comme
            // du bâti et pas comme une colline.
            drawBuildings(context: context, profile: profile, x: x, y: y, bottom: size.height - bottomInset)

            // Zone de Fresnel puis ligne de visée
            var fresnel = Path()
            fresnel.move(to: point(profile[0], profile[0].sightLineMeters))
            for p in profile.dropFirst() { fresnel.addLine(to: point(p, p.sightLineMeters)) }
            for p in profile.reversed() {
                fresnel.addLine(to: point(p, p.sightLineMeters - p.fresnelRadiusMeters * AntennaSightGeometry.fresnelClearanceRatio))
            }
            fresnel.closeSubpath()
            context.fill(fresnel, with: .color(tint.opacity(0.12)))

            var sight = Path()
            sight.move(to: point(profile[0], profile[0].sightLineMeters))
            for p in profile.dropFirst() { sight.addLine(to: point(p, p.sightLineMeters)) }
            context.stroke(sight, with: .color(tint), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

            // Repère au point visé — la BASE des antennes, pas le sommet du
            // support, qui le dépasse souvent de plusieurs mètres. Sans lui, la
            // ligne semblait s'arrêter à mi-pylône sans qu'on comprenne pourquoi.
            if let last = profile.last {
                let target = point(last, last.sightLineMeters)
                context.fill(
                    Path(ellipseIn: CGRect(x: target.x - 3.5, y: target.y - 3.5, width: 7, height: 7)),
                    with: .color(tint)
                )
                context.stroke(
                    Path(ellipseIn: CGRect(x: target.x - 6.5, y: target.y - 6.5, width: 13, height: 13)),
                    with: .color(tint.opacity(0.45)),
                    lineWidth: 1.2
                )
            }

            // Obstacle le plus pénalisant
            if let distance = verdict?.obstacleDistanceMeters,
               let hit = profile.min(by: { abs($0.distanceMeters - distance) < abs($1.distanceMeters - distance) }) {
                let anchor = point(hit, hit.obstacleMeters)
                let color = verdict?.level == .blocked ? SQColor.danger : SQColor.warning
                context.fill(
                    Path(ellipseIn: CGRect(x: anchor.x - 4.5, y: anchor.y - 4.5, width: 9, height: 9)),
                    with: .color(color)
                )
                context.stroke(
                    Path(ellipseIn: CGRect(x: anchor.x - 8, y: anchor.y - 8, width: 16, height: 16)),
                    with: .color(color.opacity(0.5)),
                    lineWidth: 1.4
                )
            }

            drawObserver(context: context, x: x(0), groundY: y(userGround), altitude: userGround, bottom: size.height - bottomInset)
            drawSupport(
                context: context,
                x: x(total),
                groundY: y(antennaGround),
                topY: y(antennaGround + structureHeight),
                antennaY: y(antennaGround + (antennaHeightMeters ?? structureHeight)),
                altitude: antennaGround,
                bottom: size.height - bottomInset
            )

            context.draw(
                Text("\(SQUnits.distance(meters: total)) · échelle verticale non proportionnelle")
                    .font(SQFont.archivo(9, .semibold))
                    .foregroundColor(SQColor.labelTertiary),
                at: CGPoint(x: size.width / 2, y: size.height - 5)
            )
        }
        .accessibilityLabel(accessibilitySummary)
    }

    /// Axe des altitudes : sans lui, « 274 m » n'a pas d'échelle à laquelle se
    /// rapporter, et le dénivelé entre les deux points reste invisible.
    private func drawAltitudeAxis(
        context: GraphicsContext,
        size: CGSize,
        minValue: Double,
        span: Double,
        leftInset: CGFloat,
        y: (Double) -> CGFloat
    ) {
        let step = niceStep(for: span)
        var value = (minValue / step).rounded(.up) * step
        while value < minValue + span {
            let lineY = y(value)
            var line = Path()
            line.move(to: CGPoint(x: leftInset, y: lineY))
            line.addLine(to: CGPoint(x: size.width - 8, y: lineY))
            context.stroke(line, with: .color(SQColor.separator.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            context.draw(
                Text("\(Int(value.rounded())) m")
                    .font(SQFont.archivo(9, .semibold))
                    .foregroundColor(SQColor.labelTertiary),
                at: CGPoint(x: leftInset - 6, y: lineY),
                anchor: .trailing
            )
            value += step
        }
    }

    /// Pas de graduation « rond » : 5, 10, 20, 50, 100 m selon l'amplitude.
    private func niceStep(for span: Double) -> Double {
        let target = span / 4
        for candidate in [5.0, 10, 20, 25, 50, 100, 200, 500] where candidate >= target {
            return candidate
        }
        return 1000
    }

    private func drawBuildings(
        context: GraphicsContext,
        profile: [AntennaSightGeometry.ProfilePoint],
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat,
        bottom: CGFloat
    ) {
        for (index, p) in profile.enumerated() where p.clutterMeters > 0.5 {
            let width = index + 1 < profile.count
                ? x(profile[index + 1].distanceMeters) - x(p.distanceMeters)
                : 6
            let roofY = y(p.obstacleMeters)
            let groundY = min(y(p.groundMeters), bottom)
            guard groundY > roofY else { continue }
            let rect = CGRect(x: x(p.distanceMeters) - width * 0.35, y: roofY, width: max(width * 0.7, 3), height: groundY - roofY)
            context.fill(Path(rect), with: .color(SQColor.labelSecondary.opacity(0.34)))
            // Fenêtres, dès que le bloc est assez grand pour les porter.
            guard rect.width > 7, rect.height > 12 else { continue }
            var windows = Path()
            let rows = min(4, Int(rect.height / 9))
            for row in 0..<rows {
                for column in 0..<2 {
                    windows.addRect(CGRect(
                        x: rect.minX + rect.width * (0.22 + Double(column) * 0.4),
                        y: rect.minY + 4 + CGFloat(row) * (rect.height - 6) / CGFloat(max(rows, 1)),
                        width: rect.width * 0.16,
                        height: 3
                    ))
                }
            }
            context.fill(windows, with: .color(SQColor.surface.opacity(0.6)))
        }
    }

    /// Silhouette de l'observateur : elle donne l'échelle humaine du départ, et
    /// rappelle que la ligne part des yeux, pas du sol.
    private func drawObserver(context: GraphicsContext, x: CGFloat, groundY: CGFloat, altitude: Double, bottom: CGFloat) {
        var body = Path()
        let height: CGFloat = 14
        let headRadius: CGFloat = 2.6
        let top = groundY - height
        body.addEllipse(in: CGRect(x: x - headRadius, y: top, width: headRadius * 2, height: headRadius * 2))
        body.move(to: CGPoint(x: x, y: top + headRadius * 2))
        body.addLine(to: CGPoint(x: x, y: groundY - height * 0.34))
        body.move(to: CGPoint(x: x - 3.4, y: top + height * 0.44))
        body.addLine(to: CGPoint(x: x + 3.4, y: top + height * 0.44))
        body.move(to: CGPoint(x: x, y: groundY - height * 0.34))
        body.addLine(to: CGPoint(x: x - 3, y: groundY))
        body.move(to: CGPoint(x: x, y: groundY - height * 0.34))
        body.addLine(to: CGPoint(x: x + 3, y: groundY))
        context.stroke(body, with: .color(SQColor.label), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        context.draw(
            Text("toi").font(SQFont.archivo(9.5, .bold)).foregroundColor(SQColor.label),
            at: CGPoint(x: x + 2, y: bottom + 11)
        )
        context.draw(
            Text("\(Int(altitude.rounded())) m").font(SQFont.archivo(9, .semibold)).foregroundColor(SQColor.labelSecondary),
            at: CGPoint(x: x + 2, y: bottom + 24)
        )
    }

    /// Le support et ses antennes, à l'échelle du graphe, avec les deux cotes qui
    /// intéressent : la hauteur de la structure et celle des antennes.
    private func drawSupport(
        context: GraphicsContext,
        x: CGFloat,
        groundY: CGFloat,
        topY: CGFloat,
        antennaY: CGFloat,
        altitude: Double,
        bottom: CGFloat
    ) {
        // Une structure de 350 px de haut pour 26 de large donnait une aiguille.
        // Un pylône réel tient dans un rapport de l'ordre de 1 pour 8 ; on s'en
        // approche, avec un plancher qui garde les traverses lisibles.
        let height = max(groundY - topY, 1)
        let width = max(min(height * 0.12, 36), 14)
        let structure = AntennaSupportSilhouette.strokePath(
            family: family, baseX: x, baseY: groundY, topY: topY, width: width
        )
        if family == .building || family == .waterTower {
            context.fill(structure, with: .color(tint.opacity(0.16)))
        }
        context.stroke(structure, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

        // Les antennes se posent SUR le fût : leur écartement suit la largeur de
        // la structure à leur hauteur, pas une constante — sinon elles flottaient
        // à côté du support au lieu d'y être accrochées.
        let antennaRatio = height > 0 ? (groundY - antennaY) / height : 0
        let widthAtAntenna = AntennaSupportSilhouette.width(family: family, at: antennaRatio, baseWidth: width)
        let antennas = AntennaSupportSilhouette.antennaPath(
            antennaTypes: antennaTypes, centerX: x, antennaY: antennaY, width: widthAtAntenna
        )
        context.fill(antennas.panels, with: .color(tint))
        if let dish = antennas.dish {
            context.stroke(dish, with: .color(tint), lineWidth: 1.4)
        }

        context.draw(
            Text(supportLabel ?? AntennaSupportSilhouette.fallbackLabel(for: family))
                .font(SQFont.archivo(9, .bold))
                .foregroundColor(SQColor.label),
            at: CGPoint(x: x + 4, y: bottom + 11), anchor: .trailing
        )
        context.draw(
            Text("\(Int(altitude.rounded())) m").font(SQFont.archivo(9, .semibold)).foregroundColor(SQColor.labelSecondary),
            at: CGPoint(x: x + 4, y: bottom + 24), anchor: .trailing
        )
    }

    private var legend: some View {
        FlowLayout(spacing: 10) {
            legendItem(color: SQColor.labelSecondary.opacity(0.26), label: String(localized: "Relief"))
            if profile.contains(where: { $0.clutterMeters > 0 }) {
                legendItem(color: SQColor.labelSecondary.opacity(0.34), label: String(localized: "Bâti"))
            }
            legendItem(color: tint, label: String(localized: "Ligne de visée"))
            legendItem(color: tint.opacity(0.12), label: String(localized: "Zone de Fresnel"))
        }
        .font(SQType.micro)
        .foregroundStyle(SQColor.labelSecondary)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 14, height: 8)
            Text(label)
        }
    }

    private var figures: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            AntennaMetricTile(
                label: "Distance", value: SQUnits.distance(meters: distanceMeters), highlight: true,
                entry: AntennaGlossary.distance(distanceMeters), selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Dénivelé", value: elevationDifference,
                entry: AntennaGlossary.elevationGap(user: userGround, site: antennaGround), selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Ton altitude", value: userGround.map { "\(Int($0.rounded())) m" } ?? "—",
                entry: AntennaGlossary.altitude(userGround, isSite: false), selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Altitude du site", value: antennaGround.map { "\(Int($0.rounded())) m" } ?? "—",
                entry: AntennaGlossary.altitude(antennaGround, isSite: true), selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Support", value: supportHeightMeters.map { "\(Int($0.rounded())) m" } ?? "—",
                entry: AntennaGlossary.supportHeight(supportHeightMeters, label: supportLabel, antennaMeters: antennaHeightMeters),
                selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: heightIsEstimated ? "Antennes (estim.)" : "Antennes",
                value: antennaHeightMeters.map { "\(Int($0.rounded())) m" } ?? "—",
                entry: AntennaGlossary.antennaHeight(antennaHeightMeters, isEstimated: heightIsEstimated,
                                                    supportMeters: supportHeightMeters, supportLabel: supportLabel),
                selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Tilt pour te viser", value: downtiltLabel,
                entry: AntennaGlossary.downtilt(downtiltDegrees), selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Ligne de visée", value: lineOfSightLabel,
                entry: AntennaGlossary.lineOfSight(verdict, profile: profile), selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Dégagement Fresnel", value: fresnelLabel,
                entry: AntennaGlossary.fresnelClearance(AntennaSightGeometry.minimumFresnelClearance(for: profile), profile: profile),
                selection: $glossaryEntry
            )
            AntennaMetricTile(
                label: "Rayon Fresnel max.", value: fresnelRadiusLabel,
                entry: AntennaGlossary.fresnelRadius(profile.map(\.fresnelRadiusMeters).max(), frequencyMhz: frequencyMhz),
                selection: $glossaryEntry
            )
        }
    }

    /// Tilt en degrés, avant mise en forme — partagé par la tuile et le glossaire.
    private var downtiltDegrees: Double? {
        guard let last = profile.last, let first = profile.first else { return nil }
        return AntennaSightGeometry.downtiltToward(
            distanceMeters: distanceMeters,
            antennaTopMeters: last.sightLineMeters,
            observerTopMeters: first.sightLineMeters
        )
    }

    /// Inclinaison géométrique qui pointerait l'antenne exactement sur toi.
    private var downtiltLabel: String {
        guard let tilt = downtiltDegrees else { return "—" }
        let rounded = (abs(tilt) * 10).rounded() / 10
        let value = String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
        // Un tilt négatif voudrait dire viser au-dessus de l'horizontale : c'est
        // le cas quand on domine l'antenne, et ça se dit « uptilt ».
        return tilt >= 0 ? "\(value)° bas" : "\(value)° haut"
    }

    private var lineOfSightLabel: String {
        switch verdict?.level {
        case .clear, .grazing: return String(localized: "dégagée")
        case .blocked: return String(localized: "coupée")
        case nil: return "—"
        }
    }

    /// Sous 60 %, une liaison s'atténue même sans obstacle franc : c'est le seuil
    /// que retient l'ITU, et celui que trace la bande du graphe.
    private var fresnelLabel: String {
        guard let clearance = AntennaSightGeometry.minimumFresnelClearance(for: profile) else { return "—" }
        let percent = Int((clearance * 100).rounded())
        return percent < 0 ? String(localized: "obstruée") : "\(percent) %"
    }

    private var fresnelRadiusLabel: String {
        guard let radius = profile.map(\.fresnelRadiusMeters).max(), radius > 0 else { return "—" }
        return "\(Int(radius.rounded())) m"
    }

    /// Différence d'altitude du SOL entre les deux points — ce qui explique
    /// souvent à lui seul qu'une antenne pourtant proche soit invisible.
    private var elevationDifference: String {
        guard let userGround, let antennaGround else { return "—" }
        let delta = antennaGround - userGround
        let sign = delta >= 0 ? "+" : "−"
        return "\(sign)\(Int(abs(delta).rounded())) m"
    }

    private var caveat: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text(verdictHeadline)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text(caveatText)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    private var verdictHeadline: String {
        switch verdict?.level {
        case .clear: return String(localized: "Rien ne masque le site")
        case .grazing: return String(localized: "La liaison frôle un obstacle")
        case .blocked: return String(localized: "Le site est masqué")
        case nil: return String(localized: "Profil du trajet")
        }
    }

    private var accessibilitySummary: String {
        let ground = [userGround, antennaGround].compactMap { $0 }
        guard ground.count == 2 else {
            return String(localized: "Profil du relief vers le site \(siteLabel)")
        }
        return String(localized: "Profil du relief : toi à \(Int(ground[0].rounded())) mètres d'altitude, site \(siteLabel) à \(Int(ground[1].rounded())) mètres, distants de \(SQUnits.distance(meters: distanceMeters))")
    }

    /// Dire ce que le calcul ignore vaut mieux qu'un verdict qui a l'air certain :
    /// un « dégagé » qui ne compte pas les arbres se démentira sur le terrain.
    private var caveatText: String {
        let base = verdict?.includesBuildings == true
            ? String(localized: "Calcul fait sur le relief (IGN) et sur la hauteur des bâtiments connue d'OpenStreetMap.")
            : String(localized: "Calcul fait sur le relief seul : aucun bâtiment n'est connu sur ce trajet.")
        let unknowns = String(localized: "La végétation, les bâtiments sans hauteur renseignée et les obstacles récents n'y figurent pas.")
        let height = antennaHeightMeters == nil
            ? String(localized: " La hauteur de l'antenne étant inconnue, 25 m ont été supposés.")
            : (heightIsEstimated ? String(localized: " La hauteur utilisée est celle du support, pas celle de l'antenne.") : "")
        let scale = String(localized: " Les hauteurs sont à l'échelle du graphe, dont l'axe vertical est dilaté pour rester lisible.")
        return base + " " + unknowns + height + scale
    }
}
