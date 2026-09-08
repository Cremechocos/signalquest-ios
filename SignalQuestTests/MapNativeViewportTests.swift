import XCTest
import SwiftUI
import MapKit
@testable import SignalQuest

/// Exercises the actual representable and MKMapView inside a UIWindow.
@MainActor
final class MapNativeViewportTests: XCTestCase {
    func testRenderUpdatesDoNotAccumulateSafeAreaIntoOrnamentMargins() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        XCTAssertGreaterThan(map.safeAreaInsets.top, 0)
        let initialTop = map.layoutMargins.top
        for _ in 0..<3 { try await fixture.refresh() }
        XCTAssertEqual(map.layoutMargins.top, initialTop, accuracy: 0.5,
                       "A render update must not turn effective safe-area margins into explicit margins")
        XCTAssertLessThanOrEqual(map.layoutMargins.bottom, fixture.probe.bottom + map.safeAreaInsets.bottom + 1)
    }

    func testPublishedViewportContainsAllFourVisibleCornersDespiteOrnamentInsets() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        try await fixture.refresh()
        let snapshot = try XCTUnwrap(fixture.probe.latest)
        assertCorners(map, within: snapshot)
        XCTAssertEqual(snapshot.heightPoints, map.bounds.height, accuracy: 0.5)
    }

    func testFullVisibleViewportStaysNarrowAcrossTheAntimeridian() async throws {
        let fixture = try Fixture(center: CLLocationCoordinate2D(latitude: 0, longitude: 179.999))
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        try await fixture.refresh()
        let snapshot = try XCTUnwrap(fixture.probe.latest)
        assertCorners(map, within: snapshot)
        XCTAssertLessThan(snapshot.bounds.east - snapshot.bounds.west, 1)
    }

    func testRotatedAndPitchedViewportIncludesVisibleCornersWithoutResettingCamera() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        let before = fixture.probe.publications
        let camera = try XCTUnwrap(map.camera.copy() as? MKMapCamera)
        camera.heading = 45
        camera.pitch = 45
        map.setCamera(camera, animated: false)
        try await fixture.settle { fixture.probe.publications > before }
        // MapKit may cap the requested pitch at the current camera distance.
        // The contract is to preserve the adopted tilted camera on refresh.
        let adoptedPitch = map.camera.pitch
        XCTAssertGreaterThan(adoptedPitch, 20)
        try await fixture.refresh()
        XCTAssertEqual(map.camera.heading, 45, accuracy: 0.5)
        XCTAssertEqual(map.camera.pitch, adoptedPitch, accuracy: 0.5)
        assertCorners(map, within: try XCTUnwrap(fixture.probe.latest))
    }

    func testResizeAndChangedInsetsPublishTheNewFullSurface() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        let initialSize = map.bounds.size
        fixture.window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        fixture.host.additionalSafeAreaInsets = UIEdgeInsets(top: 10, left: 30, bottom: 20, right: 0)
        fixture.probe.bottom = 160
        try await fixture.refresh()
        let snapshot = try XCTUnwrap(fixture.probe.latest)
        XCTAssertNotEqual(map.bounds.size, initialSize)
        XCTAssertGreaterThan(map.bounds.width, map.bounds.height)
        XCTAssertEqual(snapshot.widthPoints, map.bounds.width, accuracy: 0.5)
        XCTAssertEqual(snapshot.heightPoints, map.bounds.height, accuracy: 0.5)
        assertCorners(map, within: snapshot)
        XCTAssertLessThanOrEqual(map.layoutMargins.bottom, fixture.probe.bottom + map.safeAreaInsets.bottom + 1)
    }

    func testNativeZoomedOutViewPublishesFiniteBoundsContainingVisibleCorners() async throws {
        let fixture = try Fixture(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), zoom: 0)
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        try await fixture.refresh()
        let snapshot = try XCTUnwrap(fixture.probe.latest)
        XCTAssertTrue(snapshot.zoom.isFinite)
        XCTAssertLessThan(snapshot.zoom, 3, "The fixture must exercise the native zoomed-out camera")
        XCTAssertGreaterThan(snapshot.bounds.east - snapshot.bounds.west, 60)
        XCTAssertLessThanOrEqual(snapshot.bounds.east - snapshot.bounds.west, 360)
        assertCorners(map, within: snapshot)
        let observation = XCTAttachment(string: "Requested zoom 0; adopted camera \(map.camera); region \(map.region); published \(snapshot)")
        observation.name = "native-zoom-out-adopted-geometry"
        observation.lifetime = .keepAlways
        add(observation)
    }

    func testVisibleSpeedtestsExposeAccessibleActivatableElements() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        let coordinator = try XCTUnwrap(map.delegate as? MapKitMapView.Coordinator)
        let feature = SpeedtestFeature(id: "visible-measure", coordinate: map.centerCoordinate,
                                      downloadMbps: 120, uploadMbps: 30, pingMs: 12,
                                      tech: "4G", band: 3, frequency: nil, timestamp: nil)
        coordinator.setSpeedtest([feature], on: map)
        let container = try XCTUnwrap(coordinator.speedtestAccessibilityContainer)
        let elements = try XCTUnwrap(container.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.count, 1)
        let element = try XCTUnwrap(elements.first)
        XCTAssertTrue(element.isAccessibilityElement, "A generated description must actually be exposed to accessibility")
        XCTAssertTrue(element.accessibilityTraits.contains(.button))
        XCTAssertTrue(element.accessibilityActivate())
        XCTAssertEqual(fixture.probe.selectedIDs, ["visible-measure"])
        let screenPoint = map.convert(map.centerCoordinate, toPointTo: fixture.host.view)
        let hit = try XCTUnwrap(fixture.host.view.hitTest(screenPoint, with: nil))
        XCTAssertTrue(hit === map || hit.isDescendant(of: map),
                      "The accessibility sibling must not intercept the map's touch routing")
    }

    func testVisibleSpeedtestBeyondOrnamentMarginRemainsAccessible() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let map = try await fixture.loadedMap()
        let coordinator = try XCTUnwrap(map.delegate as? MapKitMapView.Coordinator)
        let coordinate = map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.maxY - 32), toCoordinateFrom: map)
        XCTAssertFalse(map.visibleMapRect.contains(MKMapPoint(coordinate)),
                       "The fixture must exercise the visible strip outside the ornament-adjusted map rect")
        let feature = SpeedtestFeature(id: "edge-measure", coordinate: coordinate,
                                      downloadMbps: 120, uploadMbps: nil, pingMs: nil,
                                      tech: "4G", band: nil, frequency: nil, timestamp: nil)
        coordinator.setSpeedtest([feature], on: map)
        let container = try XCTUnwrap(coordinator.speedtestAccessibilityContainer)
        let elements = try XCTUnwrap(container.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.count, 1, "A measurement inside the drawn map must not be removed by ornament margins")
    }

    private func assertCorners(_ map: MKMapView, within snapshot: MapViewportSnapshot,
                               file: StaticString = #filePath, line: UInt = #line) {
        let expanded = MapBounds(north: min(90, snapshot.bounds.north + 0.000001),
                                 south: max(-90, snapshot.bounds.south - 0.000001),
                                 east: snapshot.bounds.east + 0.000001, west: snapshot.bounds.west - 0.000001)
        for point in [CGPoint.zero, CGPoint(x: map.bounds.maxX, y: 0),
                      CGPoint(x: map.bounds.maxX, y: map.bounds.maxY), CGPoint(x: 0, y: map.bounds.maxY)] {
            let coordinate = map.convert(point, toCoordinateFrom: map)
            XCTAssertTrue(expanded.contains(lat: coordinate.latitude, lon: coordinate.longitude),
                          "Visible corner \(coordinate.latitude),\(coordinate.longitude) outside \(snapshot.bounds); current region \(map.convert(map.bounds, toRegionFrom: map))", file: file, line: line)
        }
    }

    @MainActor private final class Probe: ObservableObject {
        @Published var center: CLLocationCoordinate2D
        @Published var zoom = 14.5
        @Published var revision = 0
        var bottom: CGFloat = 80
        var publications = 0
        var latest: MapViewportSnapshot?
        var selectedIDs: [String] = []
        init(center: CLLocationCoordinate2D, zoom: Double) { self.center = center; self.zoom = zoom }
    }

    @MainActor private struct Harness: View {
        @ObservedObject var probe: Probe
        var body: some View {
            MapKitMapView(annotations: [], coverageHeatFeatures: [], speedtestFeatures: [],
                          renderVersion: probe.revision, viewportRefreshID: probe.revision,
                          colorScheme: .light, ornamentBottomInset: probe.bottom,
                          center: $probe.center, zoom: $probe.zoom,
                          onMoveEnd: { snapshot, _ in probe.latest = snapshot; probe.publications += 1 },
                          onSelect: { probe.selectedIDs.append($0.backendId ?? $0.id) })
                .ignoresSafeArea()
        }
    }

    @MainActor private final class Fixture {
        let probe: Probe
        let window: UIWindow
        let host: UIHostingController<Harness>
        weak var previousKey: UIWindow?

        init(center: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 45.188, longitude: 5.724),
             zoom: Double = 14.5) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKey = scene.windows.first { $0.isKeyWindow }
            probe = Probe(center: center, zoom: zoom)
            host = UIHostingController(rootView: Harness(probe: probe))
            host.additionalSafeAreaInsets.top = 20
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        }

        func loadedMap() async throws -> SQViewportMapView {
            try await settle { self.findMap(self.host.view) != nil && self.probe.publications > 0 }
            return try XCTUnwrap(findMap(host.view))
        }

        func refresh() async throws {
            let before = probe.publications
            probe.revision += 1
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await settle { self.probe.publications > before }
        }

        func settle(_ predicate: @MainActor () -> Bool) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
            guard predicate() else {
                XCTFail("The native map did not deliver a settled viewport")
                throw NSError(domain: "MapNativeViewportTests", code: 1)
            }
        }

        func findMap(_ view: UIView) -> SQViewportMapView? {
            if let map = view as? SQViewportMapView { return map }
            return view.subviews.lazy.compactMap { self.findMap($0) }.first
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKeyAndVisible()
        }
    }
}
