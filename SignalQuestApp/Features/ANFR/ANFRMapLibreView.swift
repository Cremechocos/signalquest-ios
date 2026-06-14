#if canImport(MapLibre)
import SwiftUI
import MapLibre

// MARK: - Annotation

/// Annotation MapLibre portant un site ANFR + son style résolu.
final class ANFRSiteAnnotation: MLNPointAnnotation {
    let site: ANFRMapSite
    let style: ANFRMarkerStyle

    init(site: ANFRMapSite) {
        self.site = site
        self.style = ANFRMarkerStyle(site: site)
        super.init()
        coordinate = site.coordinate
        title = site.city
        subtitle = site.dominantOperator.label
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Cluster Annotation

/// Annotation MapLibre portant un cluster de sites ANFR + son agrégation.
final class ANFRClusterAnnotation: MLNPointAnnotation {
    let sites: [ANFRMapSite]
    let aggregate: ANFRClusterAggregate

    init(sites: [ANFRMapSite]) {
        self.sites = sites
        self.aggregate = ANFRClusterAggregator.aggregate(sites)
        super.init()
        let lat = sites.reduce(0.0) { $0 + $1.latitude } / Double(sites.count)
        let lon = sites.reduce(0.0) { $0 + $1.longitude } / Double(sites.count)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        title = "\(sites.count) sites"
        
        switch aggregate {
        case let .single(_, op, _):
            subtitle = "Opérateur dominant : \(op.label)"
        case let .multi(_, shares):
            let ops = shares.map { $0.operator.label }.joined(separator: ", ")
            subtitle = "Opérateurs : \(ops)"
        }
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Representable

/// Carte MapLibre dédiée ANFR — autonome et plus simple que `MapExplorerView`.
/// Réutilise le même pattern (MLNMapView + style CARTO bundlé en repli, vue
/// d'annotation custom) sans la machinerie marchés/couches.
struct ANFRMapLibreView: UIViewRepresentable {
    let sites: [ANFRMapSite]
    let colorScheme: ColorScheme
    @Binding var center: CLLocationCoordinate2D
    @Binding var zoom: Double
    let onSelectSite: (ANFRMapSite) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectSite: onSelectSite)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: Self.styleURL(for: colorScheme))
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = false
        mapView.attributionButton.isHidden = false
        mapView.setCenter(center, zoomLevel: zoom, animated: false)
        mapView.tintColor = UIColor(SQColor.brandRed)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let expected = Self.styleURL(for: colorScheme)
        if mapView.styleURL != expected {
            mapView.styleURL = expected
        }
        context.coordinator.zoom = $zoom
        context.coordinator.center = $center
        context.coordinator.sync(sites: sites, on: mapView)
    }

    private static func styleURL(for colorScheme: ColorScheme) -> URL {
        let style = colorScheme == .dark ? "dark-matter-gl-style" : "positron-gl-style"
        if let url = URL(string: "https://basemaps.cartocdn.com/gl/\(style)/style.json") { return url }
        if let bundled = Bundle.main.url(forResource: "MapLibreStyle", withExtension: "json") { return bundled }
        return URL(string: "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json") ?? URL(fileURLWithPath: "/")
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private let onSelectSite: (ANFRMapSite) -> Void
        
        /// Caching and tracking states
        private var lastSites: [ANFRMapSite] = []
        private var lastSitesKey: Int = 0
        private var lastSyncZoomBucket: Int = -1

        var zoom: Binding<Double>?
        var center: Binding<CLLocationCoordinate2D>?

        init(onSelectSite: @escaping (ANFRMapSite) -> Void) {
            self.onSelectSite = onSelectSite
        }

        func sync(sites: [ANFRMapSite], on mapView: MLNMapView) {
            self.lastSites = sites
            let key = Self.signature(of: sites)
            let bucket = zoomBucket(for: mapView.zoomLevel)
            
            guard key != lastSitesKey || bucket != lastSyncZoomBucket else { return }
            lastSitesKey = key
            lastSyncZoomBucket = bucket
            
            if let existing = mapView.annotations {
                mapView.removeAnnotations(existing)
            }
            
            let annotations = Self.cluster(sites: sites, zoom: mapView.zoomLevel)
            mapView.addAnnotations(annotations)
        }

        private func zoomBucket(for zoom: Double) -> Int {
            if zoom < 6 { return 0 }
            if zoom < 8 { return 1 }
            if zoom < 10 { return 2 }
            if zoom < 12 { return 3 }
            if zoom < 13 { return 4 }
            return 5
        }

        private static func cluster(sites: [ANFRMapSite], zoom: Double) -> [MLNAnnotation] {
            guard zoom < 13 else {
                return sites.map(ANFRSiteAnnotation.init(site:))
            }
            
            let cellSize: Double
            switch zoom {
            case ..<6:
                cellSize = 1.0
            case ..<8:
                cellSize = 0.5
            case ..<10:
                cellSize = 0.2
            case ..<12:
                cellSize = 0.08
            default:
                cellSize = 0.03
            }
            
            struct Cell: Hashable {
                let lat: Int
                let lng: Int
            }
            
            let groups = Dictionary(grouping: sites) { site in
                Cell(
                    lat: Int((site.latitude / cellSize).rounded(.down)),
                    lng: Int((site.longitude / cellSize).rounded(.down))
                )
            }
            
            var annotations: [MLNAnnotation] = []
            for group in groups.values {
                if group.count == 1 {
                    annotations.append(ANFRSiteAnnotation(site: group[0]))
                } else {
                    annotations.append(ANFRClusterAnnotation(sites: group))
                }
            }
            return annotations
        }

        private static func signature(of sites: [ANFRMapSite]) -> Int {
            var hasher = Hasher()
            hasher.combine(sites.count)
            for site in sites.prefix(400) {
                hasher.combine(site.supId)
            }
            return hasher.finalize()
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            zoom?.wrappedValue = mapView.zoomLevel
            center?.wrappedValue = mapView.centerCoordinate
            sync(sites: lastSites, on: mapView)
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let cluster = annotation as? ANFRClusterAnnotation {
                let identifier = "anfr-cluster"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? ANFRMarkerView)
                    ?? ANFRMarkerView(reuseIdentifier: identifier)
                view.configure(with: cluster)
                return view
            }
            guard let point = annotation as? ANFRSiteAnnotation else { return nil }
            let identifier = "anfr-site"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? ANFRMarkerView)
                ?? ANFRMarkerView(reuseIdentifier: identifier)
            view.configure(with: point.style)
            return view
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            if let cluster = annotation as? ANFRClusterAnnotation {
                let newZoom = min(mapView.zoomLevel + 1.7, 14.0)
                mapView.setCenter(cluster.coordinate, zoomLevel: newZoom, animated: true)
            } else if let point = annotation as? ANFRSiteAnnotation {
                onSelectSite(point.site)
            }
            mapView.deselectAnnotation(annotation, animated: true)
        }
    }
}

// MARK: - Marker view

/// Vue de marqueur ANFR : disque opérateur (ou anneau multi-opérateur en parts),
/// glyphe du type de modif ou nombre de sites au centre, petit badge génération en haut à droite.
/// Porte la logique visuelle d'`AnfrMarkerStyleResolver` / Android marker bitmaps.
final class ANFRMarkerView: MLNAnnotationView {
    private let pieLayer = CAShapeLayer()
    private let coreView = UIView()
    private let glyphView = UIImageView()
    private let badgeView = UILabel()
    private let countLabel = UILabel()

    private let markerSize: CGFloat = 30
    private let badgeSize: CGFloat = 14

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        let canvas = markerSize + badgeSize / 2
        frame = CGRect(x: 0, y: 0, width: canvas, height: canvas)
        isOpaque = false
        backgroundColor = .clear

        layer.addSublayer(pieLayer)
        addSubview(coreView)
        coreView.addSubview(glyphView)
        coreView.addSubview(countLabel)
        addSubview(badgeView)

        coreView.layer.shadowColor = UIColor.black.cgColor
        coreView.layer.shadowOpacity = 0.28
        coreView.layer.shadowRadius = 5
        coreView.layer.shadowOffset = CGSize(width: 0, height: 2.5)

        glyphView.contentMode = .scaleAspectFit
        glyphView.tintColor = .white

        countLabel.textAlignment = .center
        countLabel.font = .systemFont(ofSize: 11, weight: .bold)
        countLabel.textColor = .white

        badgeView.textAlignment = .center
        badgeView.font = .systemFont(ofSize: 8, weight: .heavy)
        badgeView.textColor = .white
        badgeView.layer.cornerRadius = badgeSize / 2
        badgeView.layer.masksToBounds = true
        badgeView.layer.borderWidth = 1.5
        badgeView.layer.borderColor = UIColor.white.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func configure(with style: ANFRMarkerStyle) {
        glyphView.isHidden = false
        countLabel.isHidden = true
        badgeView.isHidden = true // L'utilisateur a explicitement demandé de ne pas afficher les badges 5G/4G.

        let canvas = markerSize + badgeSize / 2
        // Le disque opérateur est centré dans le coin bas-gauche du canvas pour
        // laisser la place au badge génération en haut-droite.
        let markerFrame = CGRect(x: 0, y: badgeSize / 2, width: markerSize, height: markerSize)

        if style.isMultiOperator {
            // Camembert en parts égales (un secteur par opérateur) + disque
            // central neutre pour porter le glyphe.
            pieLayer.frame = bounds
            renderPieSlices(style.operators, frame: markerFrame)
            coreView.frame = markerFrame.insetBy(dx: markerSize * 0.26, dy: markerSize * 0.26)
            coreView.layer.cornerRadius = coreView.bounds.width / 2
            coreView.backgroundColor = UIColor(SQColor.label)
            coreView.layer.borderWidth = 2
            coreView.layer.borderColor = UIColor.white.cgColor
        } else {
            pieLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            coreView.frame = markerFrame
            coreView.layer.cornerRadius = markerSize / 2
            coreView.backgroundColor = UIColor(style.dominantOperator.color)
            coreView.layer.borderWidth = 2
            coreView.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        }

        // Glyphe central (type de modif).
        glyphView.frame = coreView.bounds.insetBy(dx: coreView.bounds.width * 0.26, dy: coreView.bounds.width * 0.26)
        glyphView.image = UIImage(systemName: style.modType.glyph, withConfiguration: UIImage.SymbolConfiguration(weight: .heavy))
        glyphView.tintColor = .white        
    }

    func configure(with cluster: ANFRClusterAnnotation) {
        glyphView.isHidden = true
        countLabel.isHidden = false
        badgeView.isHidden = true // Pas de badge de génération sur les clusters.

        let count = cluster.sites.count
        countLabel.text = count > 99 ? "99+" : "\(count)"

        let markerFrame = CGRect(x: 0, y: badgeSize / 2, width: markerSize, height: markerSize)

        switch cluster.aggregate {
        case let .single(_, op, _):
            pieLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            coreView.frame = markerFrame
            coreView.layer.cornerRadius = markerSize / 2
            coreView.backgroundColor = UIColor(op.color)
            coreView.layer.borderWidth = 2
            coreView.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor

        case let .multi(_, shares):
            pieLayer.frame = bounds
            renderPieSlices(shares: shares, frame: markerFrame)
            coreView.frame = markerFrame.insetBy(dx: markerSize * 0.16, dy: markerSize * 0.16)
            coreView.layer.cornerRadius = coreView.bounds.width / 2
            coreView.backgroundColor = UIColor(SQColor.label)
            coreView.layer.borderWidth = 1.5
            coreView.layer.borderColor = UIColor.white.cgColor
        }

        countLabel.frame = coreView.bounds
    }

    /// Trace N secteurs égaux colorés par opérateur (anneau multi-opérateur).
    private func renderPieSlices(_ operators: [ANFROperator], frame: CGRect) {
        pieLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radius = frame.width / 2
        let count = operators.count
        guard count > 0 else { return }
        let sweep = (CGFloat.pi * 2) / CGFloat(count)
        for (index, op) in operators.enumerated() {
            let start = -CGFloat.pi / 2 + CGFloat(index) * sweep
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: true)
            path.close()
            let slice = CAShapeLayer()
            slice.path = path.cgPath
            slice.fillColor = UIColor(op.color).cgColor
            pieLayer.addSublayer(slice)
        }
    }

    /// Trace N secteurs colorés proportionnellement par opérateur pour un cluster.
    private func renderPieSlices(shares: [ANFRClusterShare], frame: CGRect) {
        pieLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radius = frame.width / 2
        let validShares = shares.filter { $0.share > 0 }
        guard !validShares.isEmpty else { return }

        var startAngle = -CGFloat.pi / 2
        for share in validShares {
            let sweep = CGFloat.pi * 2 * CGFloat(share.share)
            let path = UIBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: startAngle + sweep, clockwise: true)
            path.close()

            let slice = CAShapeLayer()
            slice.path = path.cgPath
            slice.fillColor = UIColor(share.operator.color).cgColor
            pieLayer.addSublayer(slice)

            startAngle += sweep
        }
    }
}
#endif
