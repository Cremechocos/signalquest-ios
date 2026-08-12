import SwiftUI
import MapKit
import UIKit

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
    let colorScheme: ColorScheme
    @Binding var center: CLLocationCoordinate2D
    @Binding var zoom: Double
    let onMoveEnd: (MapBounds, Double) -> Void
    let onSelect: (MapAnnotationPayload) -> Void
    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.applePlan.rawValue
    var backdrop: MapBackdrop { MapBackdrop(rawValue: backdropRaw) ?? .applePlan }

    static let referenceWidth: CGFloat = 390

    func makeCoordinator() -> Coordinator {
        Coordinator(center: $center, zoom: $zoom, onMoveEnd: onMoveEnd, onSelect: onSelect)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
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
        let region = MKCoordinateRegion(center: center, span: Coordinator.span(forZoom: zoom, width: Self.referenceWidth))
        map.setRegion(region, animated: false)
        context.coordinator.lastAppliedCenter = center
        context.coordinator.lastAppliedZoom = zoom
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
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
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        @Binding var center: CLLocationCoordinate2D
        @Binding var zoom: Double
        let onMoveEnd: (MapBounds, Double) -> Void
        let onSelect: (MapAnnotationPayload) -> Void
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
        var appliedBackdrop: MapBackdrop?
        var tileOverlay: MKTileOverlay?
        var lastRenderVersion = -1
        /// Dernier cap de carte propagé aux marqueurs. Les lobes d'azimut sont
        /// dessinés en repère écran : ils doivent contre-tourner quand la carte
        /// pivote, mais ne rien recalculer tant qu'elle ne pivote pas.
        var lastAppliedMapHeading: Double = 0

        init(center: Binding<CLLocationCoordinate2D>, zoom: Binding<Double>,
             onMoveEnd: @escaping (MapBounds, Double) -> Void,
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
                // Un ami qui a bougé/changé est mis à jour EN PLACE : déplacement
                // animé + avatar conservé (pas de recréation, donc pas de
                // clignotement). Les autres types sont retirés puis rajoutés.
                if newPayload.kind == .friend, ann.payload.kind == .friend {
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
                return .init(point: MKMapPoint(f.coordinate), color: Self.uiColor(hex: f.colorHex).withAlphaComponent(alpha).cgColor)
            }
            let overlay = SQMapKitDotsOverlay(dots: dots)
            coverageOverlay = overlay
            map.addOverlay(overlay, level: .aboveLabels)
        }

        func setSpeedtest(_ features: [SpeedtestFeature], on map: MKMapView) {
            guard features != latestSpeedtestFeatures else { return }
            latestSpeedtestFeatures = features
            if let old = speedtestOverlay { map.removeOverlay(old); speedtestOverlay = nil }
            guard !features.isEmpty else { return }
            let dots = features.map { f -> SQMapKitDotsOverlay.Dot in
                .init(point: MKMapPoint(f.coordinate), color: Self.speedColor(f.downloadMbps).withAlphaComponent(0.9).cgColor)
            }
            let overlay = SQMapKitDotsOverlay(dots: dots)
            speedtestOverlay = overlay
            map.addOverlay(overlay, level: .aboveLabels)
        }

        // MARK: Fond de carte (Apple Plan natif / imagerie Apple / raster MKTileOverlay)
        func applyBackdrop(_ backdrop: MapBackdrop, on map: MKMapView) {
            guard backdrop != appliedBackdrop else { return }
            appliedBackdrop = backdrop
            if let old = tileOverlay { map.removeOverlay(old); tileOverlay = nil }
            switch backdrop.mapKitKind {
            case .applePlan:
                let c = MKStandardMapConfiguration(elevationStyle: .flat)
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
            var best: SpeedtestFeature?
            var bestDist: CGFloat = 22
            for f in latestSpeedtestFeatures {
                let p = map.convert(f.coordinate, toPointTo: map)
                let d = hypot(p.x - tap.x, p.y - tap.y)
                if d < bestDist { bestDist = d; best = f }
            }
            if let best { onSelect(speedtestPayload(from: best)) }
        }

        func speedtestPayload(from speedtest: SpeedtestFeature) -> MapAnnotationPayload {
            MapAnnotationPayload(
                id: "speed-\(speedtest.id)",
                kind: .speedtest,
                title: "\(Int(speedtest.downloadMbps.rounded())) Mbps",
                subtitle: speedtest.tech ?? "Speedtest",
                coordinate: speedtest.coordinate,
                metric: speedtest.uploadMbps.map { "\(Int($0.rounded())) Mbps up" },
                backendId: speedtest.id,
                details: MapItemDetails(
                    downloadMbps: speedtest.downloadMbps,
                    uploadMbps: speedtest.uploadMbps,
                    pingMs: speedtest.pingMs,
                    tech: speedtest.tech,
                    timestamp: speedtest.timestamp,
                    note: "Données Speedtest"
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
            let hex: UInt32
            switch mbps {
            case 1000...: hex = 0x3B82F6
            case 600..<1000: hex = 0x06B6D4
            case 300..<600: hex = 0x22C55E
            case 100..<300: hex = 0x84CC16
            case 30..<100: hex = 0xEAB308
            case 10..<30: hex = 0xF97316
            default: hex = 0xEF4444
            }
            return uiColor(hex: hex)
        }

        // MARK: Caméra — n'applique QUE les changements programmatiques (GPS, cluster).
        func applyCameraIfNeeded(center: CLLocationCoordinate2D, zoom: Double, on map: MKMapView) {
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

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            let width = map.bounds.width > 0 ? map.bounds.width : MapKitMapView.referenceWidth
            let z = Self.zoom(forRegion: map.region, width: width)
            // Reflète l'état réel dans les bindings (le guard ci-dessus évite la boucle).
            lastAppliedCenter = map.centerCoordinate
            lastAppliedZoom = z
            center = map.centerCoordinate
            zoom = z
            let r = map.region
            let bounds = MapBounds(
                north: r.center.latitude + r.span.latitudeDelta / 2,
                south: r.center.latitude - r.span.latitudeDelta / 2,
                east: r.center.longitude + r.span.longitudeDelta / 2,
                west: r.center.longitude - r.span.longitudeDelta / 2
            )
            onMoveEnd(bounds, z)
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
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let sq = view.annotation as? SQMapKitAnnotation {
                onSelect(sq.payload)
            }
            map.deselectAnnotation(view.annotation, animated: false)
        }
    }
}
