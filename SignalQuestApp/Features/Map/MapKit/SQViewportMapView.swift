import UIKit
import MapKit

/// Adaptateur iOS proposé pour MapKitMapView.makeUIView. Il détecte aussi un
/// changement de Split View sans dépendre d'un regionDidChangeAnimated fortuit.
@MainActor
final class SQViewportMapView: MKMapView {
    var onViewportLayout: ((MapViewportSnapshot) -> Void)?
    private var lastSize: CGSize = .zero
    private var layoutGeneration = UUID()
    private var requestedBottomInset: CGFloat?
    #if DEBUG
    private var qaEventCount = 0
    private let recordsViewportQA = ProcessInfo.processInfo.environment["SQ_MAP_VIEWPORT_QA"] == "1"
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        #if DEBUG
        recordViewportForQA(event: "layout-size-changed")
        #endif
        requestViewportDelivery()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { layoutGeneration = UUID() }
        else { requestViewportDelivery() }
    }

    func setOrnamentBottomInset(_ inset: CGFloat) {
        guard inset.isFinite else { return }
        let requested = max(0, inset)
        guard requestedBottomInset != requested else { return }
        requestedBottomInset = requested
        // layoutMargins reads back effective values including the safe area.
        // Reapplying those values accumulates the top inset on every render.
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: requested, trailing: 0)
        requestViewportDelivery()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        requestViewportDelivery()
    }

    override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        requestViewportDelivery()
    }

    var measuredViewport: MapViewportSnapshot? {
        guard let base = try? MapViewportProjection.measured(
            region: convert(bounds, toRegionFrom: self),
            widthPoints: Double(bounds.width), heightPoints: Double(bounds.height)
        ) else { return nil }
        // MapKit's region centre is a projected midpoint. At nonzero latitude,
        // centre +/- span/2 can fall slightly inside a visible corner. Keep its
        // longitude/wrap semantics and enclose the actual corner latitudes too.
        let latitudes = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                         CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
            .map { convert($0, toCoordinateFrom: self) }
            .filter { CLLocationCoordinate2DIsValid($0) }.map(\.latitude)
        let fullBounds = MapBounds(north: max(base.bounds.north, latitudes.max() ?? base.bounds.north),
                                   south: min(base.bounds.south, latitudes.min() ?? base.bounds.south),
                                   east: base.bounds.east, west: base.bounds.west)
        return MapViewportSnapshot(bounds: fullBounds, zoom: base.zoom,
                                   widthPoints: base.widthPoints, heightPoints: base.heightPoints,
                                   centerLatitude: base.centerLatitude, centerLongitude: base.centerLongitude)
    }

    func requestViewportDelivery() {
        let generation = UUID()
        layoutGeneration = generation
        // Sortir du cycle de layout avant de modifier un binding SwiftUI ; ne
        // livrer que la dernière taille, avec le rect adopté par MapKit ensuite.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutGeneration == generation, self.window != nil,
                  // visibleMapRect excludes ornament/safe-area margins.
                  let snapshot = self.measuredViewport else { return }
            #if DEBUG
            self.recordViewportForQA(event: "delivery", snapshot: snapshot)
            #endif
            self.onViewportLayout?(snapshot)
        }
    }

    #if DEBUG
    /// Opt-in geometry evidence for isolated simulator recipes only. No marker,
    /// account, credential or request body is recorded, and Release excludes it.
    func recordViewportForQA(event: String, snapshot: MapViewportSnapshot? = nil) {
        guard recordsViewportQA, qaEventCount < 512 else { return }
        qaEventCount += 1
        func number(_ value: Double) -> Any { value.isFinite ? value as Any : NSNull() }
        func rectangle(_ value: CGRect) -> [String: Any] {
            ["x": number(value.minX), "y": number(value.minY), "width": number(value.width), "height": number(value.height)]
        }
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)].map { point in
            let coordinate = convert(point, toCoordinateFrom: self)
            return ["lat": number(coordinate.latitude), "lng": number(coordinate.longitude)]
        }
        var ancestors: [[String: Any]] = []
        var current = superview
        for _ in 0..<5 {
            guard let view = current else { break }
            ancestors.append(["class": String(describing: type(of: view)), "frame": rectangle(view.frame), "bounds": rectangle(view.bounds)])
            current = view.superview
        }
        var value: [String: Any] = [
            "event": event, "at": Date().timeIntervalSince1970, "sequence": qaEventCount,
            "bounds": rectangle(bounds), "frame": rectangle(frame), "ancestors": ancestors, "corners": corners,
            "mapRect": ["x": number(visibleMapRect.minX), "y": number(visibleMapRect.minY),
                        "width": number(visibleMapRect.width), "height": number(visibleMapRect.height)],
            "region": ["lat": number(region.center.latitude), "lng": number(region.center.longitude),
                       "latDelta": number(region.span.latitudeDelta), "lngDelta": number(region.span.longitudeDelta)],
            "pitch": number(camera.pitch), "altitude": number(camera.altitude),
            "safeArea": ["top": number(safeAreaInsets.top), "bottom": number(safeAreaInsets.bottom)],
            "margins": ["top": number(layoutMargins.top), "bottom": number(layoutMargins.bottom)]
        ]
        if let snapshot {
            value["acceptedSnapshot"] = ["north": snapshot.bounds.north, "south": snapshot.bounds.south,
                "east": snapshot.bounds.east, "west": snapshot.bounds.west, "zoom": snapshot.zoom,
                "width": snapshot.widthPoints, "height": snapshot.heightPoints]
        }
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        data.append(0x0A)
        let file = caches.appendingPathComponent("qa-map-viewport-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
    #endif
}
