import SwiftUI
import MapKit

/// Tracé d'une session sur MKMapView (API UIKit, non dépréciée, iOS 13→27) :
/// nuage de points de mesure colorés par RSRP (overlay Core Graphics, performant
/// même pour des milliers de points), tracé du parcours (drive-test) + antennes
/// desservantes colorées par état (vert identifiée / orange hypothèse / gris
/// proximité).
struct SessionTraceMapView: UIViewRepresentable {
    let points: [CoverageSessionPoint]
    let antennas: [ServingAntenna]
    var speedtests: [SessionSpeedtest] = []
    var drawPath: Bool = false
    /// Mode de coloration des points : par signal (RSRP) ou par génération (carte couverture).
    var coloring: SessionPointColoring = .rsrp
    /// Fourni par « Mes mesures » : évite de reconstruire 30 000 points quand
    /// seul un état d'interface change. Les autres appelants gardent leur rendu.
    var renderID: UUID? = nil
    /// Chargement progressif : la carte se cadre tant que l'utilisateur ne l'a
    /// pas déplacée, puis garde sa vue quand de nouveaux points arrivent.
    var keepsUserViewport: Bool = false
    /// Nom d'opérateur à afficher par id de speedtest (le registre arrive après la carte).
    var operatorLabels: [String: String] = [:]
    /// Plein écran : un toucher sur la carte lit le point le plus proche.
    var onPointTap: ((CoverageSessionPoint?) -> Void)? = nil
    /// Point entouré sur la carte (celui qu'on lit).
    var selectedPoint: CoverageSessionPoint? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        if onPointTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            map.addGestureRecognizer(tap)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let signature = renderID.map {
            SessionTraceRenderSignature(id: $0, coloring: coloring,
                colorScheme: context.environment.colorScheme,
                contrast: context.environment.colorSchemeContrast,
                operatorLabels: operatorLabels)
        }
        context.coordinator.onPointTap = onPointTap
        if context.coordinator.shouldRender(signature) {
            render(on: map, context: context)
        }
        context.coordinator.syncSelection(selectedPoint, on: map)
    }

    private func render(on map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        let validPoints = points.filter(\.hasValidCoordinate)
        let coords = validPoints.map(\.coordinate)
        context.coordinator.selection = nil
        if onPointTap != nil { context.coordinator.points = validPoints }

        // Drive Test : un ruban coloré point par point ; sinon un nuage de perles.
        if !validPoints.isEmpty {
            let isDark = context.environment.colorScheme == .dark
            map.addOverlay(SessionPointsOverlay(points: validPoints, coloring: coloring,
                                                connects: drawPath && coords.count >= 2,
                                                casing: (isDark ? UIColor(white: 0.1, alpha: 0.9) : UIColor.white).cgColor),
                           level: .aboveLabels)
        }
        // Antennes desservantes géolocalisées.
        let locatedAntennas = antennas.filter(\.hasValidCoordinate)
        map.addAnnotations(locatedAntennas.map(ServingAntennaAnnotation.init))

        // Speedtests géolocalisés (marqueur « débit » tappable).
        let locatedSpeedtests = speedtests.compactMap { st -> SessionSpeedtestAnnotation? in
            st.coordinate == nil ? nil : SessionSpeedtestAnnotation(st, operatorLabel: operatorLabels[st.id])
        }
        map.addAnnotations(locatedSpeedtests)

        var rect = MKMapRect.null
        for coord in coords {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coord), size: MKMapSize(width: 1, height: 1)))
        }
        for antenna in locatedAntennas {
            rect = rect.union(MKMapRect(origin: MKMapPoint(antenna.coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        for st in locatedSpeedtests {
            rect = rect.union(MKMapRect(origin: MKMapPoint(st.coordinate), size: MKMapSize(width: 1, height: 1)))
        }
        if !rect.isNull, !(keepsUserViewport && context.coordinator.userMovedMap) {
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 44, left: 44, bottom: 44, right: 44), animated: false)
            context.coordinator.didFit = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private var lastSignature: SessionTraceRenderSignature?
        private(set) var userMovedMap = false
        /// Un geste avant le premier cadrage ne doit pas figer la vue du monde entier.
        var didFit = false
        var onPointTap: ((CoverageSessionPoint?) -> Void)?
        var points: [CoverageSessionPoint] = []
        var selection: SessionSelectedPointAnnotation?

        /// Point le plus proche du doigt, à 28 pt au plus ; un toucher sur un
        /// repère (antenne, speedtest) garde sa bulle.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView, let onPointTap else { return }
            let location = gesture.location(in: map)
            if let hit = map.hitTest(location, with: nil), hit is MKAnnotationView || hit.superview is MKAnnotationView { return }
            var best: (point: CoverageSessionPoint, distance: CGFloat)?
            for point in points {
                let p = map.convert(point.coordinate, toPointTo: map)
                let d = hypot(p.x - location.x, p.y - location.y)
                if d <= 28, d < (best?.distance ?? .infinity) { best = (point, d) }
            }
            onPointTap(best?.point)
        }

        func syncSelection(_ point: CoverageSessionPoint?, on map: MKMapView) {
            guard selection?.point.id != point?.id else { return }
            if let selection { map.removeAnnotation(selection) }
            selection = point.map(SessionSelectedPointAnnotation.init)
            if let selection { map.addAnnotation(selection) }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Seul un geste de l'utilisateur fige le cadrage, pas nos propres recadrages.
            let gestures = mapView.subviews.first?.gestureRecognizers ?? []
            if didFit, gestures.contains(where: { $0.state == .began || $0.state == .changed || $0.state == .ended }) {
                userMovedMap = true
            }
        }

        func shouldRender(_ signature: SessionTraceRenderSignature?) -> Bool {
            guard let signature else {
                lastSignature = nil
                return true
            }
            guard signature != lastSignature else { return false }
            lastSignature = signature
            return true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let points = overlay as? SessionPointsOverlay {
                return SessionPointsRenderer(overlay: points)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let serving = annotation as? ServingAntennaAnnotation {
                let identifier = "serving-antenna-dot"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = serving.markerImage(traits: mapView.traitCollection)
                view.displayPriority = .required
                view.canShowCallout = true
                view.accessibilityLabel = [serving.title, serving.subtitle].compactMap { $0 }.joined(separator: ", ")
                return view
            }
            if annotation is SessionSelectedPointAnnotation {
                let identifier = "session-selected-point"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = SessionSelectedPointAnnotation.ring
                view.displayPriority = .required
                view.isEnabled = false
                return view
            }
            if let st = annotation as? SessionSpeedtestAnnotation {
                let identifier = "session-speedtest-pill"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                let pill = SessionSpeedtestAnnotation.pill(for: st.speedtest, traits: mapView.traitCollection)
                view.image = pill.image
                // La pointe de l'étiquette désigne l'endroit exact de la mesure.
                view.centerOffset = pill.centerOffset
                view.displayPriority = .defaultHigh
                view.canShowCallout = true
                view.accessibilityLabel = [st.title, st.subtitle].compactMap { $0 }.joined(separator: ", ")
                return view
            }
            return nil
        }
    }
}

struct SessionTraceRenderSignature: Equatable {
    let id: UUID
    let coloring: SessionPointColoring
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    var operatorLabels: [String: String] = [:]
}

/// Overlay des points dessiné en Core Graphics, à taille écran constante :
/// un ruban continu pour un Drive Test, des perles cerclées sinon. Bornage par
/// `boundingMapRect` + culling dans le renderer → fluide pour de gros volumes.
final class SessionPointsOverlay: NSObject, MKOverlay {
    struct Dot { let point: MKMapPoint; let color: CGColor }

    let dots: [Dot]
    /// Relie les points dans l'ordre (parcours d'un Drive Test).
    let connects: Bool
    /// Liseré clair (ou sombre) qui détache le tracé du fond de carte.
    let casing: CGColor
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(points: [CoverageSessionPoint], coloring: SessionPointColoring = .rsrp,
         connects: Bool = false, casing: CGColor = UIColor.white.cgColor) {
        var rect = MKMapRect.null
        dots = points.map { p in
            let mp = MKMapPoint(p.coordinate)
            rect = rect.union(MKMapRect(origin: mp, size: MKMapSize(width: 0.5, height: 0.5)))
            let color = coloring == .generation ? SessionGenerationColor.cg(p.tech) : SessionRSRPColor.cg(p.signalStrength)
            return Dot(point: mp, color: color)
        }
        self.connects = connects
        self.casing = casing
        let bounding = rect.isNull ? MKMapRect.world : rect.insetBy(dx: -rect.size.width * 0.1 - 50, dy: -rect.size.height * 0.1 - 50)
        boundingMapRect = bounding
        coordinate = MKMapPoint(x: bounding.midX, y: bounding.midY).coordinate
    }
}

final class SessionPointsRenderer: MKOverlayRenderer {
    /// Au-delà, deux points consécutifs ne sont pas reliés (trou de mesure).
    private static let maxGapMeters: Double = 1_500

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? SessionPointsOverlay else { return }
        // Un point écran, en unités carte.
        let screen = 1 / zoomScale
        let cull = mapRect.insetBy(dx: -12 * screen, dy: -12 * screen)
        if overlay.connects {
            drawRibbon(overlay, screen: screen, cull: cull, in: context)
        } else {
            drawPearls(overlay, screen: screen, cull: cull, in: context)
        }
    }

    /// Segments visibles du parcours, sans les trous de mesure.
    private func visibleSegments(_ dots: [SessionPointsOverlay.Dot], cull: MKMapRect) -> [Int] {
        guard dots.count >= 2 else { return [] }
        var indices: [Int] = []
        for i in 1..<dots.count {
            let a = dots[i - 1].point, b = dots[i].point
            let box = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 0.5, height: abs(a.y - b.y) + 0.5)
            guard box.intersects(cull), a.distance(to: b) <= Self.maxGapMeters else { continue }
            indices.append(i)
        }
        return indices
    }

    private func drawRibbon(_ overlay: SessionPointsOverlay, screen: Double, cull: MKMapRect, in context: CGContext) {
        let dots = overlay.dots
        let segments = visibleSegments(dots, cull: cull)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        guard !segments.isEmpty else {
            // Point isolé : une perle suffit.
            drawPearls(overlay, screen: screen, cull: cull, in: context)
            return
        }
        // 1. Liseré ombré sous tout le ruban.
        let casing = CGMutablePath()
        for i in segments {
            casing.move(to: point(for: dots[i - 1].point))
            casing.addLine(to: point(for: dots[i].point))
        }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 4, color: UIColor.black.withAlphaComponent(0.28).cgColor)
        context.addPath(casing)
        context.setStrokeColor(overlay.casing)
        context.setLineWidth(9 * screen)
        context.strokePath()
        context.restoreGState()
        // 2. Ruban coloré : les segments consécutifs de même couleur en un seul tracé.
        context.setLineWidth(5.5 * screen)
        var run = CGMutablePath()
        var runColor: CGColor?
        var lastIndex = -1
        func flush() {
            guard let runColor, !run.isEmpty else { return }
            context.addPath(run)
            context.setStrokeColor(runColor)
            context.strokePath()
        }
        for i in segments {
            let color = dots[i].color
            if color != runColor || i != lastIndex + 1 {
                flush()
                run = CGMutablePath()
                runColor = color
                run.move(to: point(for: dots[i - 1].point))
            }
            run.addLine(to: point(for: dots[i].point))
            lastIndex = i
        }
        flush()
    }

    /// Perles : un disque coloré cerclé du liseré, à taille écran constante.
    private func drawPearls(_ overlay: SessionPointsOverlay, screen: Double, cull: MKMapRect, in context: CGContext) {
        let radius = 4 * screen
        let ring = 1.5 * screen
        for dot in overlay.dots {
            guard cull.contains(dot.point) else { continue }
            let p = point(for: dot.point)
            let outer = CGRect(x: p.x - radius - ring, y: p.y - radius - ring,
                               width: (radius + ring) * 2, height: (radius + ring) * 2)
            context.setFillColor(overlay.casing)
            context.fillEllipse(in: outer)
            context.setFillColor(dot.color)
            context.fillEllipse(in: outer.insetBy(dx: ring, dy: ring))
        }
    }
}

/// Couleurs RSRP — délègue à l'échelle canonique unique (SQNetworkColors), la
/// même que la couche couverture de la carte principale et les fiches.
enum SessionRSRPColor {
    static func ui(_ rsrp: Double?) -> UIColor { SQNetworkColors.rsrpUIColor(rsrp) }
    static func cg(_ rsrp: Double?) -> CGColor { ui(rsrp).cgColor }
}

/// Mode de coloration du nuage de points : RSRP (signal) ou GÉNÉRATION.
/// IMPORTANT : carte RSRP et carte génération sont deux cartes DISTINCTES.
enum SessionPointColoring: Hashable { case rsrp, generation }

/// Couleurs par GÉNÉRATION (carte de couverture génération, distincte du RSRP).
/// Délègue à l'échelle canonique unique (SQNetworkColors).
enum SessionGenerationColor {
    static func ui(_ tech: String?) -> UIColor { SQNetworkColors.generationUIColor(tech) }
    static func cg(_ tech: String?) -> CGColor { ui(tech).cgColor }
}

/// Annotation MapKit d'une antenne desservante.
final class ServingAntennaAnnotation: NSObject, MKAnnotation {
    let antenna: ServingAntenna
    init(_ antenna: ServingAntenna) { self.antenna = antenna }

    var coordinate: CLLocationCoordinate2D { antenna.coordinate }
    var title: String? { antenna.operatorDisplayName ?? antenna.displayName ?? String(localized: "Antenne") }
    var subtitle: String? {
        var parts: [String] = [antenna.status.label]
        if let d = antenna.distanceKm, d > 0 {
            parts.append(SQUnits.distance(kilometers: d))
        }
        return parts.joined(separator: " · ")
    }

    /// Liseré crème des marqueurs de carte, constant dans les deux modes.
    private static let outline = UIColor(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xEF / 255, alpha: 1)
    @MainActor private static var imageCache: [String: UIImage] = [:]

    /// Point d'antenne Halo : la couleur de l'opérateur, et l'état sur un badge
    /// (coche verte si identifiée, « ? » ambre si hypothèse). Une antenne de
    /// proximité reste un point atténué, sans badge.
    @MainActor
    func markerImage(traits: UITraitCollection) -> UIImage {
        let fill = UIColor(SQBrand.operatorColor(antenna.operatorName)).resolvedColor(with: traits)
        let key = "\(fill.description)|\(antenna.status.rawValue)|\(traits.userInterfaceStyle.rawValue)"
        if let hit = Self.imageCache[key] { return hit }
        let dot: CGFloat = 26, border: CGFloat = 2.5, badge: CGFloat = 14, margin: CGFloat = 9
        let side = dot + margin * 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(x: margin, y: margin, width: dot, height: dot)
            let faded = antenna.status == .proximity || antenna.status == .unknown
            cg.setAlpha(faded ? 0.6 : 1)
            cg.setShadow(offset: CGSize(width: 0, height: 3), blur: 5, color: UIColor.black.withAlphaComponent(0.22).cgColor)
            Self.outline.setFill()
            cg.fillEllipse(in: rect)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            fill.setFill()
            cg.fillEllipse(in: rect.insetBy(dx: border, dy: border))
            cg.setAlpha(1)
            let badgeStyle: (fill: UIColor, symbol: String)?
            switch antenna.status {
            case .identified: badgeStyle = (UIColor(SQColor.success).resolvedColor(with: traits), "checkmark")
            case .hypothesis: badgeStyle = (UIColor(OutageTint.degraded).resolvedColor(with: traits), "questionmark")
            case .proximity, .unknown: badgeStyle = nil
            }
            guard let badgeStyle else { return }
            // En haut à droite, à cheval sur le liseré, comme sur la carte principale.
            let offset = (dot / 2 + badge / 2 - 3) * CGFloat(2).squareRoot() / 2
            let badgeRect = CGRect(x: rect.midX + offset - badge / 2, y: rect.midY - offset - badge / 2, width: badge, height: badge)
            Self.outline.setFill()
            cg.fillEllipse(in: badgeRect)
            badgeStyle.fill.setFill()
            cg.fillEllipse(in: badgeRect.insetBy(dx: 1.5, dy: 1.5))
            let config = UIImage.SymbolConfiguration(pointSize: 7, weight: .black)
            if let symbol = UIImage(systemName: badgeStyle.symbol, withConfiguration: config)?
                .withTintColor(Self.outline, renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: badgeRect.midX - symbol.size.width / 2, y: badgeRect.midY - symbol.size.height / 2))
            }
        }
        Self.imageCache[key] = image
        return image
    }
}

/// Anneau autour du point lu en plein écran.
final class SessionSelectedPointAnnotation: NSObject, MKAnnotation {
    let point: CoverageSessionPoint
    init(_ point: CoverageSessionPoint) { self.point = point }
    var coordinate: CLLocationCoordinate2D { point.coordinate }

    static let ring: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { context in
        let rect = CGRect(x: 2, y: 2, width: 22, height: 22)
        UIColor.white.setStroke()
        let outer = UIBezierPath(ovalIn: rect)
        outer.lineWidth = 5
        outer.stroke()
        UIColor.black.setStroke()
        let inner = UIBezierPath(ovalIn: rect)
        inner.lineWidth = 2.5
        inner.stroke()
    }
}

/// Annotation MapKit d'un speedtest géolocalisé (marqueur « débit »).
final class SessionSpeedtestAnnotation: NSObject, MKAnnotation {
    let speedtest: SessionSpeedtest
    let coordinate: CLLocationCoordinate2D
    let operatorLabel: String?
    init?(_ st: SessionSpeedtest, operatorLabel: String? = nil) {
        guard let coord = st.coordinate else { return nil }
        self.speedtest = st
        self.operatorLabel = operatorLabel
        self.coordinate = coord
    }

    var title: String? {
        func rate(_ arrow: String, _ mbps: Double?) -> String {
            guard let mbps, mbps > 0 else { return "\(arrow) —" }
            return "\(arrow) \(SQUnits.throughput(mbps: mbps))"
        }
        let down = rate("↓", speedtest.downloadMbps)
        let up = rate("↑", speedtest.uploadMbps)
        return "\(down) · \(up)"
    }
    var subtitle: String? {
        var parts: [String] = []
        if let op = operatorLabel ?? speedtest.networkOperatorLabel(in: nil), !op.isEmpty { parts.append(op) }
        if let mvno = speedtest.mvnoName, !mvno.isEmpty,
           mvno.caseInsensitiveCompare(speedtest.operatorKey ?? "") != .orderedSame {
            parts.append("SIM \(mvno)")
        }
        if let net = speedtest.networkType, !net.isEmpty { parts.append(net) }
        if let ping = speedtest.pingMs { parts.append("\(Int(ping.rounded())) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var tintColor: UIColor { SessionSpeedColor.ui(speedtest.downloadMbps) }

    /// Liseré crème des marqueurs de carte, constant dans les deux modes.
    private static let outline = UIColor(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xEF / 255, alpha: 1)
    @MainActor private static var pillCache: [String: (image: UIImage, centerOffset: CGPoint)] = [:]

    /// Étiquette « 242 Mbit/s » sur la couleur du débit, avec une pointe vers le
    /// point de mesure. Mise en cache par valeur, couleur et thème.
    @MainActor
    static func pill(for st: SessionSpeedtest, traits: UITraitCollection) -> (image: UIImage, centerOffset: CGPoint) {
        let measured = (st.downloadMbps ?? 0) > 0 ? st.downloadMbps : nil
        let value = measured.map { SQUnits.throughputValue(mbps: $0) } ?? "—"
        let unit = SQUnits.throughputUnit(mbps: measured ?? 0)
        let fill = SessionSpeedColor.ui(st.downloadMbps).resolvedColor(with: traits)
        let key = "\(value)|\(unit)|\(fill.description)|\(traits.userInterfaceStyle.rawValue)"
        if let hit = pillCache[key] { return hit }
        let ink = SQMapKitMarkerView.ink(on: fill).resolvedColor(with: traits)
        let valueText = NSAttributedString(string: value, attributes: [
            .font: SQShareFonts.display(size: 13, weight: 800), .foregroundColor: ink
        ])
        let unitText = NSAttributedString(string: " " + unit, attributes: [
            .font: SQShareFonts.display(size: 10, weight: 600), .foregroundColor: ink.withAlphaComponent(0.8)
        ])
        let label = NSMutableAttributedString(attributedString: valueText)
        label.append(unitText)
        let textSize = label.size()
        let height: CGFloat = 26, tail: CGFloat = 6, border: CGFloat = 2, margin: CGFloat = 6
        let body = CGRect(x: margin, y: margin, width: ceil(textSize.width) + 20, height: height)
        let size = CGSize(width: body.width + margin * 2, height: body.height + tail + margin * 2)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let path = UIBezierPath(roundedRect: body, cornerRadius: height / 2)
            path.move(to: CGPoint(x: body.midX - tail, y: body.maxY - 1))
            path.addLine(to: CGPoint(x: body.midX, y: body.maxY + tail))
            path.addLine(to: CGPoint(x: body.midX + tail, y: body.maxY - 1))
            path.close()
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 4,
                                    color: UIColor.black.withAlphaComponent(0.25).cgColor)
            outline.setFill()
            path.fill()
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            let inner = UIBezierPath(roundedRect: body.insetBy(dx: border, dy: border), cornerRadius: height / 2 - border)
            fill.setFill()
            inner.fill()
            label.draw(at: CGPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2))
        }
        // L'ancre d'une vue est son centre : on remonte l'image pour poser la pointe sur la mesure.
        let result = (image, CGPoint(x: 0, y: -(size.height / 2 - margin)))
        pillCache[key] = result
        return result
    }
}

/// Couleur d'un speedtest par débit descendant (Mb/s) — échelle canonique unique
/// (SQNetworkColors), identique à la carte. `nil`/0 → gris « pas de mesure ».
enum SessionSpeedColor {
    static func ui(_ mbps: Double?) -> UIColor {
        guard let m = mbps, m > 0 else { return SQNetworkColors.unknownUIColor }
        return SQNetworkColors.speedUIColor(m)
    }
}
