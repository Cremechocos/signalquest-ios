import SwiftUI
import MapKit
import UIKit

/// Keeps custom accessibility content outside MapKit's specialized AX tree.
/// The map still owns all drawing and gestures; both siblings fill this view.
@MainActor
final class SQMapKitContainerView: UIView {
    let mapView = SQViewportMapView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        installMap()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installMap()
    }

    let zoneCompareView = SQZoneCompareOverlayView(frame: .zero)

    private func installMap() {
        isAccessibilityElement = false
        for view in [mapView, zoneCompareView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        zoneCompareView.mapView = mapView
    }
}

/// Point et rayon de la comparaison d'opérateurs, tels que la carte doit les montrer.
struct MapZoneCompareOverlay {
    /// Ce que la feuille de comparaison cache en bas de la carte : le cercle se cadre au-dessus.
    enum SheetCover: Equatable {
        case none
        case height(CGFloat)
        case half
        case full
    }

    var coordinate: CLLocationCoordinate2D
    var radiusMeters: Double
    /// Change à chaque cadrage voulu (ouverture, rayon choisi) ; un déplacement du point ne recadre pas.
    var fitToken: Int
    var sheetCover: SheetCover
}

/// Épingle et cercle de la comparaison, en repère écran au-dessus de la carte plutôt qu'en
/// overlay MapKit : pendant un glissé, le cercle suit l'épingle à chaque image sans re-rendre
/// les tuiles. Seule l'épingle reçoit les touchers ; le reste passe à la carte.
@MainActor
final class SQZoneCompareOverlayView: UIView {
    weak var mapView: MKMapView?
    var onMoveEnd: ((CLLocationCoordinate2D) -> Void)?

    private let circleLayer = CAShapeLayer()
    private let radiusLabel = UILabel()
    private let radiusBadge = UIView()
    private let pin = UIView()
    private let pinDot = UIView()
    private var coordinate: CLLocationCoordinate2D?
    private var radiusMeters: Double = 0
    /// Centre de l'épingle pendant un glissé, en points de cette vue.
    private var dragCenter: CGPoint?
    private var grabOffset: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .clear
        isHidden = true
        circleLayer.lineWidth = 2
        circleLayer.lineDashPattern = [7, 5]
        layer.addSublayer(circleLayer)

        radiusBadge.layer.cornerRadius = 11
        radiusBadge.layer.shadowOpacity = 0.14
        radiusBadge.layer.shadowRadius = 4
        radiusBadge.layer.shadowOffset = CGSize(width: 0, height: 1)
        radiusBadge.isAccessibilityElement = false
        radiusLabel.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .systemFont(ofSize: 12, weight: .semibold), maximumPointSize: 17)
        radiusLabel.adjustsFontForContentSizeCategory = true
        radiusBadge.addSubview(radiusLabel)
        addSubview(radiusBadge)

        // Cible de 44 pt autour d'un point de 22 pt : le centre du cercle reste lisible.
        pin.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        pinDot.frame = CGRect(x: 11, y: 11, width: 22, height: 22)
        pinDot.layer.cornerRadius = 11
        pinDot.layer.borderWidth = 3
        pinDot.layer.shadowOpacity = 0.28
        pinDot.layer.shadowRadius = 4
        pinDot.layer.shadowOffset = CGSize(width: 0, height: 2)
        pinDot.isUserInteractionEnabled = false
        pin.addSubview(pinDot)
        pin.isAccessibilityElement = true
        pin.accessibilityLabel = String(localized: "Point de comparaison")
        pin.accessibilityHint = String(localized: "Glisse pour déplacer le point. Un appui long ailleurs sur la carte le déplace aussi.")
        pin.accessibilityIdentifier = "map.zoneCompare.pin"
        pin.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        addSubview(pin)
        applyColors()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, pin.frame.contains(point) else { return nil }
        return pin
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func applyColors() {
        let accent = (UIColor(named: "BrandRed") ?? .systemRed).resolvedColor(with: traitCollection)
        circleLayer.strokeColor = accent.cgColor
        circleLayer.fillColor = accent.withAlphaComponent(0.08).cgColor
        pinDot.backgroundColor = accent
        pinDot.layer.borderColor = UIColor.white.cgColor
        pinDot.layer.shadowColor = UIColor.black.cgColor
        radiusBadge.backgroundColor = UIColor.systemBackground.resolvedColor(with: traitCollection)
        radiusBadge.layer.shadowColor = UIColor.black.cgColor
        radiusLabel.textColor = accent
    }

    /// Nouvel état voulu par l'écran. Pendant un glissé, le doigt garde la main sur le point.
    func update(_ overlay: MapZoneCompareOverlay?) {
        guard let overlay else {
            coordinate = nil
            dragCenter = nil
            isHidden = true
            return
        }
        if dragCenter == nil { coordinate = overlay.coordinate }
        radiusMeters = overlay.radiusMeters
        radiusLabel.text = SQUnits.distanceCompact(meters: overlay.radiusMeters)
        isHidden = false
        relayout()
    }

    /// Repositionne l'épingle et le cercle sur la carte (déplacement, zoom, rotation).
    func relayout() {
        guard !isHidden, let map = mapView, let coordinate else { return }
        let center = dragCenter ?? map.convert(coordinate, toPointTo: self)
        let centerCoordinate = dragCenter.map { map.convert($0, toCoordinateFrom: self) } ?? coordinate
        let rect = Self.screenRect(center: centerCoordinate, radiusMeters: radiusMeters, map: map, in: self)
        // Le cercle se recentre sur le point écran exact, pour qu'il ne flotte pas sous le doigt.
        let circle = CGRect(x: center.x - rect.width / 2, y: center.y - rect.height / 2, width: rect.width, height: rect.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circleLayer.path = UIBezierPath(ovalIn: circle).cgPath
        CATransaction.commit()
        pin.center = center
        radiusLabel.sizeToFit()
        let badge = CGSize(width: radiusLabel.bounds.width + 16, height: max(22, radiusLabel.bounds.height + 6))
        radiusBadge.bounds = CGRect(origin: .zero, size: badge)
        radiusLabel.center = CGPoint(x: badge.width / 2, y: badge.height / 2)
        radiusBadge.center = CGPoint(x: circle.midX, y: circle.minY)
        // Un cercle plus petit que l'épingle n'a pas d'étiquette lisible.
        radiusBadge.isHidden = circle.width < 60
    }

    /// Rectangle écran d'un cercle géographique : même projection que `MKCircle`.
    static func screenRect(center: CLLocationCoordinate2D, radiusMeters: Double, map: MKMapView, in view: UIView) -> CGRect {
        let origin = MKMapPoint(center)
        let radius = radiusMeters * MKMapPointsPerMeterAtLatitude(center.latitude)
        let mapRect = MKMapRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        return map.convert(MKCoordinateRegion(mapRect), toRectTo: view)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let map = mapView else { return }
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            grabOffset = CGPoint(x: pin.center.x - location.x, y: pin.center.y - location.y)
            dragCenter = pin.center
            Haptics.light()
            if !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.15) { self.pinDot.transform = CGAffineTransform(scaleX: 1.25, y: 1.25) }
            }
        case .changed:
            dragCenter = CGPoint(x: location.x + grabOffset.x, y: location.y + grabOffset.y)
            relayout()
        case .ended, .cancelled, .failed:
            let end = dragCenter ?? pin.center
            dragCenter = nil
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) { self.pinDot.transform = .identity }
            let moved = map.convert(end, toCoordinateFrom: self)
            guard recognizer.state == .ended, CLLocationCoordinate2DIsValid(moved) else {
                relayout()
                return
            }
            coordinate = moved
            relayout()
            Haptics.medium()
            onMoveEnd?(moved)
        default:
            break
        }
    }

    private var pendingFit: DispatchWorkItem?

    /// Le cadrage attend la fin de l'arrivée de la feuille : pendant sa montée, MapKit
    /// interrompt l'animation et ne garde que le recentrage, pas le zoom. Deux demandes
    /// rapprochées (ouverture puis rayon) n'en font qu'une.
    func scheduleFit(_ overlay: MapZoneCompareOverlay) {
        pendingFit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fit(overlay, animated: !UIAccessibility.isReduceMotionEnabled)
        }
        pendingFit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Cadre le cercle dans la partie de carte que la feuille laisse visible.
    func fit(_ overlay: MapZoneCompareOverlay, animated: Bool) {
        guard let map = mapView, map.bounds.height > 0 else { return }
        let height = map.bounds.height
        let covered: CGFloat
        switch overlay.sheetCover {
        case .none: covered = 0
        case .height(let value): covered = value
        case .half: covered = height / 2
        case .full: return
        }
        // Sous la barre de recherche en haut, au-dessus de la feuille en bas, avec une marge.
        let top = map.safeAreaInsets.top + 76
        let bottom = covered + 24
        let side: CGFloat = 28
        let visibleHeight = height - top - bottom
        let visibleWidth = map.bounds.width - side * 2
        guard visibleHeight > 120, visibleWidth > 120 else { return }
        // Rectangle de carte complet calculé à la main : avec de grandes marges,
        // `setVisibleMapRect(_:edgePadding:)` recentrait sans zoomer.
        let origin = MKMapPoint(overlay.coordinate)
        let diameter = overlay.radiusMeters * 2 * MKMapPointsPerMeterAtLatitude(overlay.coordinate.latitude)
        let perPoint = diameter / Double(min(visibleHeight, visibleWidth))
        let width = Double(map.bounds.width) * perPoint
        let fullHeight = Double(height) * perPoint
        // Le centre du cercle tombe au milieu de la bande visible, pas au milieu de l'écran.
        let circleY = Double(top + visibleHeight / 2) * perPoint
        let rect = MKMapRect(x: origin.x - width / 2, y: origin.y - circleY, width: width, height: fullHeight)
        map.setVisibleMapRect(rect, animated: animated)
    }
}

/// Carte principale rendue avec MapKit (Apple Plan natif). Consomme les MÊMES
/// payloads que le moteur de rendu (`renderedAnnotations`, etc.).
struct MapKitMapView: UIViewRepresentable {
    let annotations: [MapAnnotationPayload]
    let coverageHeatFeatures: [CoverageHeatFeature]   // Phase 2
    let speedtestFeatures: [SpeedtestFeature]          // Phase 2
    /// Incrémenté à chaque reconstruction des couches `rendered*` (PERF-MAP-03).
    /// Permet à `updateUIView` de distinguer « les données ont changé » de « seule la
    /// caméra a bougé » et d'éviter le hash/compare O(n) des couches à chaque pan.
    let renderVersion: Int
    let viewportRefreshID: Int
    let colorScheme: ColorScheme
    /// Espace réservé aux ornements MapKit (logo Apple / mentions légales).
    /// La carte peut rester plein écran, mais ses mentions ne doivent pas passer
    /// sous le dock flottant de l'application.
    let ornamentBottomInset: CGFloat
    @Binding var center: CLLocationCoordinate2D
    @Binding var zoom: Double
    let onMoveEnd: (MapViewportSnapshot, MKCoordinateRegion) -> Void
    let onSelect: (MapAnnotationPayload) -> Void
    /// Appui long sur un fond de carte (hors marqueur) : le point touché.
    var onLongPress: ((CLLocationCoordinate2D) -> Void)? = nil
    /// Point et rayon de la comparaison d'opérateurs ouverte ; `nil` quand elle est fermée.
    var zoneCompare: MapZoneCompareOverlay? = nil
    /// Fin d'un glissé de l'épingle de comparaison.
    var onZoneCompareMove: ((CLLocationCoordinate2D) -> Void)? = nil
    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.applePlan.rawValue
    var backdrop: MapBackdrop { MapBackdrop.resolve(backdropRaw) }

    static let referenceWidth: CGFloat = 390

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(center: $center, zoom: $zoom, onMoveEnd: onMoveEnd, onSelect: onSelect)
        coordinator.onLongPress = onLongPress
        return coordinator
    }

    func makeUIView(context: Context) -> SQMapKitContainerView {
        let container = SQMapKitContainerView(frame: .zero)
        let map = container.mapView
        map.onViewportLayout = { [weak coordinator = context.coordinator, weak map] viewport in
            guard let map else { return }
            coordinator?.publishViewport(viewport, from: map)
        }
        map.delegate = context.coordinator
        applyOrnamentInsets(to: map)
        map.showsUserLocation = true
        // Boussole native désactivée puis re-ajoutée au MILIEU-DROIT : par défaut elle
        // apparaît en haut-droite (carte tournée) et entre en collision avec le bouton
        // « Calques & filtres ». `.adaptive` conserve le comportement natif (masquée
        // nord-up, visible carte tournée, tap = retour au nord).
        map.showsCompass = false
        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive
        compass.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(compass)
        NSLayoutConstraint.activate([
            compass.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -SQSpace.md),
            compass.centerYAnchor.constraint(equalTo: map.centerYAnchor)
        ])
        context.coordinator.applyBackdrop(backdrop, on: map)
        map.register(SQMapKitMarkerView.self, forAnnotationViewWithReuseIdentifier: SQMapKitMarkerView.reuseID)
        map.register(SQFriendMarkerView.self, forAnnotationViewWithReuseIdentifier: SQFriendMarkerView.reuseID)
        map.register(SQPhotoMarkerView.self, forAnnotationViewWithReuseIdentifier: SQPhotoMarkerView.reuseID)
        // Tap pour les points speedtest (overlay non-tappable nativement) → hit-test.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSpeedtestTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.delegate = context.coordinator
        longPress.minimumPressDuration = 0.6
        map.addGestureRecognizer(longPress)
        context.coordinator.installSpeedtestAccessibility(on: map, in: container)
        context.coordinator.zoneCompareView = container.zoneCompareView
        let region = MKCoordinateRegion(center: center, span: Coordinator.span(forZoom: zoom, width: Self.referenceWidth))
        map.setRegion(region, animated: false)
        context.coordinator.lastAppliedCenter = center
        context.coordinator.lastAppliedZoom = zoom
        return container
    }

    func updateUIView(_ container: SQMapKitContainerView, context: Context) {
        let map = container.mapView
        applyOrnamentInsets(to: map)
        context.coordinator.onLongPress = onLongPress
        context.coordinator.applyBackdrop(backdrop, on: map)
        // PERF-MAP-03 : ne resynchroniser les couches que si les données ont changé.
        // Un simple déplacement caméra (pan/zoom) réévalue `updateUIView` mais ne doit
        // plus re-hasher/comparer des milliers d'éléments — seule la caméra est appliquée.
        if context.coordinator.lastRenderVersion != renderVersion {
            context.coordinator.lastRenderVersion = renderVersion
            context.coordinator.setCoverage(coverageHeatFeatures, on: map)
            context.coordinator.setSpeedtest(speedtestFeatures, on: map)
            context.coordinator.apply(annotations: annotations, on: map)
        }
        context.coordinator.applyCameraIfNeeded(center: center, zoom: zoom, on: map)
        if context.coordinator.lastViewportRefreshID != viewportRefreshID {
            context.coordinator.lastViewportRefreshID = viewportRefreshID
            (map as? SQViewportMapView)?.requestViewportDelivery()
        }
        container.zoneCompareView.onMoveEnd = onZoneCompareMove
        container.zoneCompareView.update(zoneCompare)
        if let zoneCompare, context.coordinator.lastZoneCompareFitToken != zoneCompare.fitToken {
            context.coordinator.lastZoneCompareFitToken = zoneCompare.fitToken
            container.zoneCompareView.scheduleFit(zoneCompare)
        } else if zoneCompare == nil {
            context.coordinator.lastZoneCompareFitToken = nil
        }
    }

    private func applyOrnamentInsets(to map: MKMapView) {
        (map as? SQViewportMapView)?.setOrnamentBottomInset(ornamentBottomInset)
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        @Binding var center: CLLocationCoordinate2D
        @Binding var zoom: Double
        let onMoveEnd: (MapViewportSnapshot, MKCoordinateRegion) -> Void
        let onSelect: (MapAnnotationPayload) -> Void
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        var annotationsById: [String: SQMapKitAnnotation] = [:]
        var payloadsById: [String: MapAnnotationPayload] = [:]
        /// Horodatage du dernier déplacement reçu par ami : sert à caler la durée
        /// du glissement sur l'intervalle réel entre deux positions.
        var lastFriendMoveAt: [String: Date] = [:]
        var lastAppliedCenter: CLLocationCoordinate2D?
        var lastAppliedZoom: Double?
        var latestCoverageFeatures: [CoverageHeatFeature] = []
        var latestSpeedtestFeatures: [SpeedtestFeature] = []
        var coverageOverlay: SQMapKitDotsOverlay?
        var speedtestOverlay: SQMapKitDotsOverlay?
        weak var speedtestAccessibilityContainer: UIView?
        var appliedBackdrop: MapBackdrop?
        var tileOverlay: MKTileOverlay?
        var lastRenderVersion = -1
        var lastViewportRefreshID = -1
        weak var zoneCompareView: SQZoneCompareOverlayView?
        var lastZoneCompareFitToken: Int?
        private var isMovingCamera = false
        /// Dernier cap de carte propagé aux marqueurs. Les lobes d'azimut sont
        /// dessinés en repère écran : ils doivent contre-tourner quand la carte
        /// pivote, mais ne rien recalculer tant qu'elle ne pivote pas.
        var lastAppliedMapHeading: Double = 0

        init(center: Binding<CLLocationCoordinate2D>, zoom: Binding<Double>,
             onMoveEnd: @escaping (MapViewportSnapshot, MKCoordinateRegion) -> Void,
             onSelect: @escaping (MapAnnotationPayload) -> Void) {
            _center = center
            _zoom = zoom
            self.onMoveEnd = onMoveEnd
            self.onSelect = onSelect
        }

        // MARK: Zoom ↔ span (slippy-map, compatible avec le z des tuiles)
        // La formule vit dans `SQMapProjection` depuis que CarPlay dessine sa
        // propre carte : les deux surfaces DOIVENT cadrer identiquement, sinon
        // elles ne demandent pas les mêmes tuiles. Ces deux appels restent pour
        // ne pas toucher aux appelants internes.
        static func span(forZoom zoom: Double, width: CGFloat) -> MKCoordinateSpan {
            SQMapProjection.span(forZoom: zoom, width: width)
        }
        static func zoom(forRegion region: MKCoordinateRegion, width: CGFloat) -> Double {
            SQMapProjection.zoom(forRegion: region, width: width)
        }

        // MARK: Annotations — diff stable par id (add/remove delta)
        func apply(annotations payloads: [MapAnnotationPayload], on map: MKMapView) {
            var incoming: [String: MapAnnotationPayload] = [:]
            incoming.reserveCapacity(payloads.count)
            for p in payloads { incoming[p.id] = p }

            var toRemove: [SQMapKitAnnotation] = []
            for (id, ann) in annotationsById {
                guard let newPayload = incoming[id] else {
                    toRemove.append(ann)
                    annotationsById[id] = nil
                    payloadsById[id] = nil
                    lastFriendMoveAt[id] = nil
                    continue
                }
                guard newPayload != payloadsById[id] else { continue }
                // A cluster keeps its cell ID while its centroid and count change
                // during a pan. Replacing the annotation flashes or briefly drops
                // it; update its existing marker and accessibility instead.
                if newPayload.clusterCount != nil, ann.payload.clusterCount != nil,
                   newPayload.kind == ann.payload.kind {
                    updateClusterInPlace(ann, to: newPayload, on: map)
                    payloadsById[id] = newPayload
                } else if newPayload.kind == .friend, ann.payload.kind == .friend {
                    updateFriendInPlace(ann, to: newPayload, on: map)
                    payloadsById[id] = newPayload
                } else {
                    toRemove.append(ann)
                    annotationsById[id] = nil
                    payloadsById[id] = nil
                }
            }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }

            var toAdd: [SQMapKitAnnotation] = []
            for p in payloads where annotationsById[p.id] == nil {
                let ann = SQMapKitAnnotation(payload: p)
                annotationsById[p.id] = ann
                payloadsById[p.id] = p
                toAdd.append(ann)
            }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }
        }

        /// Cluster positions follow the current admitted points immediately.
        /// No movement animation: a pan already moves the map, and Reduce Motion
        /// must not see an extra marker transition.
        func updateClusterInPlace(_ ann: SQMapKitAnnotation, to payload: MapAnnotationPayload, on map: MKMapView) {
            ann.payload = payload
            if ann.coordinate.latitude != payload.coordinate.latitude
                || ann.coordinate.longitude != payload.coordinate.longitude {
                UIView.performWithoutAnimation { ann.coordinate = payload.coordinate }
            }
            (map.view(for: ann) as? SQMapKitMarkerView)?.apply(payload)
        }

        /// Met à jour un ami existant sans recréer l'annotation : ré-applique ses
        /// infos (présence, avatar, badge) à la vue visible et anime le déplacement
        /// de sa position — MapKit interpole la vue via KVO sur `coordinate`.
        /// Respecte Reduce Motion.
        func updateFriendInPlace(_ ann: SQMapKitAnnotation, to payload: MapAnnotationPayload, on map: MKMapView) {
            ann.payload = payload
            if let view = map.view(for: ann) as? SQFriendMarkerView, let info = payload.friend {
                view.apply(info, displayScale: max(map.traitCollection.displayScale, 2))
            }
            let moved = ann.coordinate.latitude != payload.coordinate.latitude
                || ann.coordinate.longitude != payload.coordinate.longitude
            guard moved else { return }
            if UIAccessibility.isReduceMotionEnabled {
                ann.coordinate = payload.coordinate
                return
            }
            // Glissement CONTINU façon Localiser : on étale l'animation sur la durée
            // réelle écoulée depuis le dernier fix de cet ami (bornée), en courbe
            // LINÉAIRE, pour que le marqueur avance sans à-coups d'une position à la
            // suivante plutôt qu'un saut bref suivi d'un temps mort. `.beginFromCurrentState`
            // reprend en douceur si un nouveau fix arrive avant la fin.
            let now = Date()
            let elapsed = lastFriendMoveAt[payload.id].map { now.timeIntervalSince($0) } ?? 4
            lastFriendMoveAt[payload.id] = now
            let duration = min(max(elapsed, 1), 8)
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.curveLinear, .allowUserInteraction, .beginFromCurrentState]) {
                ann.coordinate = payload.coordinate
            }
        }

        // MARK: Couches denses (couverture + speedtests) — overlay Core Graphics
        func setCoverage(_ features: [CoverageHeatFeature], on map: MKMapView) {
            guard features != latestCoverageFeatures else { return }
            latestCoverageFeatures = features
            if let old = coverageOverlay { map.removeOverlay(old); coverageOverlay = nil }
            guard !features.isEmpty else { return }
            let dots = features.map { f -> SQMapKitDotsOverlay.Dot in
                let alpha: CGFloat = f.dimmed ? 0.32 : 0.78
                return .init(point: MKMapPoint(f.coordinate), color: Self.uiColor(hex: f.colorHex).withAlphaComponent(alpha).cgColor,
                             hatched: f.hatched)
            }
            let overlay = SQMapKitDotsOverlay(dots: dots)
            coverageOverlay = overlay
            map.addOverlay(overlay, level: .aboveLabels)
        }

        func setSpeedtest(_ features: [SpeedtestFeature], on map: MKMapView) {
            guard features != latestSpeedtestFeatures else { return }
            latestSpeedtestFeatures = features
            if let old = speedtestOverlay { map.removeOverlay(old); speedtestOverlay = nil }
            guard !features.isEmpty else {
                updateSpeedtestAccessibility(on: map)
                return
            }
            let dots = features.map { f -> SQMapKitDotsOverlay.Dot in
                .init(point: MKMapPoint(f.coordinate), color: Self.speedColor(f.downloadMbps).withAlphaComponent(0.9).cgColor)
            }
            let overlay = SQMapKitDotsOverlay(dots: dots)
            speedtestOverlay = overlay
            map.addOverlay(overlay, level: .aboveLabels)
            updateSpeedtestAccessibility(on: map)
        }

        func installSpeedtestAccessibility(on map: MKMapView, in host: UIView) {
            let container = UIView(frame: host.bounds)
            container.backgroundColor = .clear
            container.isUserInteractionEnabled = false
            container.isAccessibilityElement = false
            container.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                container.topAnchor.constraint(equalTo: host.topAnchor),
                container.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            speedtestAccessibilityContainer = container
            updateSpeedtestAccessibility(on: map)
        }

        /// Les points visibles deviennent une liste de boutons VoiceOver sans
        /// ajouter de marqueur visuel ni modifier le hit-test tactile existant.
        func updateSpeedtestAccessibility(on map: MKMapView) {
            guard let container = speedtestAccessibilityContainer else { return }
            let centerPoint = MKMapPoint(map.centerCoordinate)
            let visible = latestSpeedtestFeatures
                .filter { map.bounds.contains(map.convert($0.coordinate, toPointTo: map)) }
                .sorted {
                    MKMapPoint($0.coordinate).distance(to: centerPoint)
                        < MKMapPoint($1.coordinate).distance(to: centerPoint)
                }
            let exposed = visible.prefix(100)
            var elements: [UIAccessibilityElement] = []
            if visible.count > exposed.count {
                let summary = UIAccessibilityElement(accessibilityContainer: container)
                summary.accessibilityLabel = String(
                    localized: "\(exposed.count) mesures de débit proches sur \(visible.count) visibles"
                )
                summary.accessibilityHint = String(localized: "Zoome pour réduire le nombre de mesures")
                summary.accessibilityTraits = .staticText
                summary.accessibilityFrameInContainerSpace = CGRect(
                    x: max(0, container.bounds.midX - 1),
                    y: max(0, container.bounds.midY - 1),
                    width: 2,
                    height: 2
                )
                elements.append(summary)
            }
            elements.append(contentsOf: exposed.map { feature in
                let payload = speedtestPayload(from: feature)
                let description = MapAccessibility.describe(payload)
                let element = SQMapOverlayAccessibilityElement(accessibilityContainer: container)
                element.accessibilityLabel = description.label
                element.accessibilityValue = description.value
                element.accessibilityHint = description.hint ?? String(localized: "Ouvre le détail du speedtest")
                element.accessibilityTraits = .button
                let point = map.convert(feature.coordinate, toPointTo: container)
                element.accessibilityFrameInContainerSpace = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
                element.activation = { [weak self] in self?.onSelect(payload) }
                return element
            })
            container.accessibilityElements = elements
        }

        // MARK: Fond de carte (Apple Plan natif / imagerie Apple / raster MKTileOverlay)
        func applyBackdrop(_ backdrop: MapBackdrop, on map: MKMapView) {
            guard backdrop != appliedBackdrop else { return }
            appliedBackdrop = backdrop
            if let old = tileOverlay { map.removeOverlay(old); tileOverlay = nil }
            map.showTileAttribution(backdrop.tileAttribution)
            switch backdrop.mapKitKind {
            case .applePlan:
                // Fond atténué : les couleurs restent aux couches (opérateurs, couverture).
                let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
            case .imagery:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .raster(let template, let maxZoom):
                let c = MKStandardMapConfiguration(elevationStyle: .flat)
                c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
                // Tuiles raster opaques (remplacent le fond Apple) sous toutes nos couches.
                let overlay = MKTileOverlay(urlTemplate: template)
                overlay.canReplaceMapContent = true
                overlay.maximumZ = maxZoom
                map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                tileOverlay = overlay
            }
        }

        /// Propage le cap de la carte aux marqueurs d'antenne, qui dessinent leurs
        /// lobes en repère écran. Sans cela, faire pivoter la carte ferait pointer
        /// tous les secteurs dans la mauvaise direction.
        ///
        /// Borné à ce qui est visible et gardé par un seuil : tant que la carte
        /// n'est pas pivotée — le cas courant — cette méthode ne fait rien, alors
        /// qu'elle est appelée à chaque frame de pan/zoom.
        func applyMapHeading(on map: MKMapView, force: Bool = false) {
            let heading = map.camera.heading
            guard force || abs(heading - lastAppliedMapHeading) > 0.5 else { return }
            lastAppliedMapHeading = heading
            for annotation in map.annotations(in: map.visibleMapRect) {
                guard let annotation = annotation as? MKAnnotation,
                      let view = map.view(for: annotation) as? SQMapKitMarkerView else { continue }
                view.applyMapHeading(heading)
            }
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let dots = overlay as? SQMapKitDotsOverlay {
                return SQMapKitDotsRenderer(overlay: dots)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        @objc func handleSpeedtestTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView,
                  !latestSpeedtestFeatures.isEmpty else { return }
            let tap = recognizer.location(in: map)
            // Un tap sur un marqueur (antenne, photo, ami) est déjà traité par
            // `didSelect` : ouvrir aussi le speedtest voisin demandait deux feuilles
            // à la fois, et une seule pouvait s'afficher (AF-CARTE-06).
            var hit = map.hitTest(tap, with: nil)
            while let view = hit {
                if view is MKAnnotationView { return }
                hit = view.superview
            }
            var best: SpeedtestFeature?
            var bestDist: CGFloat = 22
            for f in latestSpeedtestFeatures {
                let p = map.convert(f.coordinate, toPointTo: map)
                let d = hypot(p.x - tap.x, p.y - tap.y)
                if d < bestDist { bestDist = d; best = f }
            }
            if let best { onSelect(speedtestPayload(from: best)) }
        }

        /// Point retenu au début d'un appui long, remis au lever du doigt.
        private var longPressCoordinate: CLLocationCoordinate2D?

        /// Un appui long sur le fond de carte donne le point à comparer. Sur un marqueur, la
        /// sélection reste seule maîtresse : on ne répond qu'au fond. Le point part au lever du
        /// doigt : un doigt encore posé interrompt le cadrage animé de la carte sur le cercle.
        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView, let onLongPress else { return }
            switch recognizer.state {
            case .began:
                longPressCoordinate = nil
                let point = recognizer.location(in: map)
                var hit = map.hitTest(point, with: nil)
                while let view = hit {
                    if view is MKAnnotationView || view is MKCompassButton { return }
                    hit = view.superview
                }
                let coordinate = map.convert(point, toCoordinateFrom: map)
                guard CLLocationCoordinate2DIsValid(coordinate) else { return }
                Haptics.medium()
                longPressCoordinate = coordinate
            case .ended:
                guard let coordinate = longPressCoordinate else { return }
                longPressCoordinate = nil
                onLongPress(coordinate)
            case .cancelled, .failed:
                longPressCoordinate = nil
            default:
                break
            }
        }

        func speedtestPayload(from speedtest: SpeedtestFeature) -> MapAnnotationPayload {
            MapAnnotationPayload(
                id: "speed-\(speedtest.id)",
                kind: .speedtest,
                title: "\(Int(speedtest.downloadMbps.rounded())) Mbps",
                subtitle: speedtest.tech ?? String(localized: "Speedtest"),
                coordinate: speedtest.coordinate,
                metric: speedtest.uploadMbps.map { String(localized: "\(Int($0.rounded())) Mbps en envoi") },
                backendId: speedtest.id,
                details: MapItemDetails(
                    downloadMbps: speedtest.downloadMbps,
                    uploadMbps: speedtest.uploadMbps,
                    pingMs: speedtest.pingMs,
                    tech: speedtest.tech,
                    timestamp: speedtest.timestamp,
                    note: String(localized: "Données Speedtest")
                ),
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false
            )
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        static func uiColor(hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        static func speedColor(_ mbps: Double) -> UIColor {
            SQNetworkColors.speedUIColor(mbps)
        }

        // MARK: Caméra — n'applique QUE les changements programmatiques (GPS, cluster).
        func applyCameraIfNeeded(center: CLLocationCoordinate2D, zoom: Double, on map: MKMapView) {
            guard CLLocationCoordinate2DIsValid(center), zoom.isFinite else { return }
            let movedCenter = lastAppliedCenter.map {
                abs($0.latitude - center.latitude) > 0.00005 || abs($0.longitude - center.longitude) > 0.00005
            } ?? true
            let changedZoom = lastAppliedZoom.map { abs($0 - zoom) > 0.01 } ?? true
            guard movedCenter || changedZoom else { return }
            lastAppliedCenter = center
            lastAppliedZoom = zoom
            let width = map.bounds.width > 0 ? map.bounds.width : MapKitMapView.referenceWidth
            map.setRegion(MKCoordinateRegion(center: center, span: Self.span(forZoom: zoom, width: width)), animated: true)
        }

        func mapView(_ map: MKMapView, regionWillChangeAnimated animated: Bool) {
            isMovingCamera = true
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            isMovingCamera = false
            (map as? SQViewportMapView)?.requestViewportDelivery()
            updateSpeedtestAccessibility(on: map)
        }

        func publishViewport(_ viewport: MapViewportSnapshot, from map: MKMapView) {
            #if DEBUG
            (map as? SQViewportMapView)?.recordViewportForQA(event: isMovingCamera ? "candidate-moving" : "candidate-still", snapshot: viewport)
            #endif
            guard !isMovingCamera else { return }
            // Un binding peut déjà demander une nouvelle caméra, alors qu'une
            // livraison de layout de l'ancienne attend encore dans la main queue.
            if let lastAppliedCenter,
               abs(lastAppliedCenter.latitude - center.latitude) > 0.00005
                || abs(lastAppliedCenter.longitude - center.longitude) > 0.00005 { return }
            if let lastAppliedZoom, abs(lastAppliedZoom - zoom) > 0.01 { return }
            lastAppliedCenter = map.centerCoordinate
            lastAppliedZoom = viewport.zoom
            center = map.centerCoordinate
            zoom = viewport.zoom
            #if DEBUG
            (map as? SQViewportMapView)?.recordViewportForQA(event: "published", snapshot: viewport)
            #endif
            onMoveEnd(viewport, map.region)
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let sq = annotation as? SQMapKitAnnotation else { return nil } // position utilisateur → défaut
            // Ami vivant : marqueur « Find My » dédié (avatar + halo + cône de cap).
            if sq.payload.kind == .friend, let info = sq.payload.friend {
                let view = map.dequeueReusableAnnotationView(withIdentifier: SQFriendMarkerView.reuseID, for: annotation) as? SQFriendMarkerView
                    ?? SQFriendMarkerView(annotation: annotation, reuseIdentifier: SQFriendMarkerView.reuseID)
                view.annotation = annotation
                view.canShowCallout = false
                view.apply(info, displayScale: max(map.traitCollection.displayScale, 2))
                view.isAccessibilityElement = true
                view.accessibilityLabel = sq.payload.accessibilityLabel
                return view
            }
            // Photo géolocalisée (hors cluster) : vignette « polaroïd » sur la carte.
            if sq.payload.kind == .photo, sq.payload.clusterCount == nil, let thumbnail = sq.payload.thumbnailURL {
                let view = map.dequeueReusableAnnotationView(withIdentifier: SQPhotoMarkerView.reuseID, for: annotation) as? SQPhotoMarkerView
                    ?? SQPhotoMarkerView(annotation: annotation, reuseIdentifier: SQPhotoMarkerView.reuseID)
                view.annotation = annotation
                view.canShowCallout = false
                view.apply(url: thumbnail, displayScale: max(map.traitCollection.displayScale, 2))
                view.isAccessibilityElement = true
                view.accessibilityLabel = sq.payload.accessibilityLabel
                return view
            }
            let view = map.dequeueReusableAnnotationView(withIdentifier: SQMapKitMarkerView.reuseID, for: annotation) as? SQMapKitMarkerView
                ?? SQMapKitMarkerView(annotation: annotation, reuseIdentifier: SQMapKitMarkerView.reuseID)
            view.annotation = annotation
            view.canShowCallout = false
            // `apply` pose déjà l'accessibilité complète (label + value + hint) via
            // `MapAccessibility`. On ne réécrit surtout pas le label derrière avec
            // `payload.accessibilityLabel`, comme pour les deux marqueurs ci-dessus
            // qui, eux, n'ont pas de description : cette réécriture perdait la
            // NATURE de l'élément (« Antenne », « Panne confirmée »…) et laissait
            // VoiceOver annoncer un titre nu.
            view.apply(sq.payload)
            // Une vue créée (ou recyclée) alors que la carte est déjà pivotée doit
            // naître à la bonne orientation, pas attendre le prochain geste.
            view.applyMapHeading(map.camera.heading)
            return view
        }

        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            applyMapHeading(on: map)
            zoneCompareView?.relayout()
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let sq = view.annotation as? SQMapKitAnnotation {
                onSelect(sq.payload)
            }
            map.deselectAnnotation(view.annotation, animated: false)
        }
    }
}

extension MKMapView {
    private static let tileAttributionTag = 0x5141_7474

    /// Mention de licence des fonds raster (OSM, OpenTopoMap), en bas à droite :
    /// Apple garde sa propre mention en bas à gauche.
    func showTileAttribution(_ text: String?) {
        let existing = viewWithTag(Self.tileAttributionTag) as? UILabel
        guard let text else {
            existing?.removeFromSuperview()
            return
        }
        let label = existing ?? {
            let label = UILabel()
            label.tag = Self.tileAttributionTag
            label.font = .preferredFont(forTextStyle: .caption2)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.75)
            label.layer.cornerRadius = 4
            label.layer.masksToBounds = true
            label.numberOfLines = 0
            label.textAlignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
                label.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 80),
            ])
            return label
        }()
        label.text = " \(text) "
    }
}
