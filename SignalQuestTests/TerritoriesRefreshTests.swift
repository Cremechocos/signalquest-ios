import MapKit
import SwiftUI
import XCTest
@testable import SignalQuest

@MainActor
final class TerritoriesRefreshTests: XCTestCase {
    private enum FixtureError: Error { case offline }

    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.86, longitude: 2.35),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    private func grid(status: String = "observed", mine: Bool = false, east: Double = 2.36) throws -> TerritoryGrid {
        let json: [String: Any] = [
            "cells": [[
                "cellKey": "same-cell",
                "status": status,
                "bounds": ["north": 48.87, "south": 48.85, "east": east, "west": 2.34],
                "pointsCount": 10,
                "userCount": 2,
                "trustScore": 0.5,
                "mine": mine,
            ]],
            "truncated": false,
        ]
        return try JSONDecoder().decode(TerritoryGrid.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSameCellKeysRedrawForStatusOwnershipOrAppearanceChanges() throws {
        let observed = try grid()
        let reliable = try grid(status: "reliable")
        let mine = try grid(mine: true)
        let moved = try grid(east: 2.37)
        let original = TerritoryRenderIdentity(cells: observed.cells, colorScheme: .light, contrast: .standard)

        XCTAssertEqual(original, TerritoryRenderIdentity(cells: observed.cells, colorScheme: .light, contrast: .standard))
        XCTAssertNotEqual(original, TerritoryRenderIdentity(cells: reliable.cells, colorScheme: .light, contrast: .standard))
        XCTAssertNotEqual(original, TerritoryRenderIdentity(cells: mine.cells, colorScheme: .light, contrast: .standard))
        XCTAssertNotEqual(original, TerritoryRenderIdentity(cells: moved.cells, colorScheme: .light, contrast: .standard))
        XCTAssertNotEqual(original, TerritoryRenderIdentity(cells: observed.cells, colorScheme: .dark, contrast: .standard))
        XCTAssertNotEqual(original, TerritoryRenderIdentity(cells: observed.cells, colorScheme: .light, contrast: .increased))
    }

    func testMapKitReplacesAnOverlayWhenAVisibleStatusChanges() throws {
        let map = MKMapView()
        let coordinator = TerritoryMapView.Coordinator(onRegionChange: { _, _ in })
        let observed = try grid()
        let reliable = try grid(status: "reliable")
        let firstIdentity = TerritoryRenderIdentity(cells: observed.cells, colorScheme: .light, contrast: .standard)
        let secondIdentity = TerritoryRenderIdentity(cells: reliable.cells, colorScheme: .light, contrast: .standard)

        coordinator.render(cells: observed.cells, identity: firstIdentity, on: map)
        let first = try XCTUnwrap(map.overlays.first as? TerritoryOverlay)
        coordinator.render(cells: observed.cells, identity: firstIdentity, on: map)
        XCTAssertTrue(map.overlays.first === first, "Identical data should not rebuild the overlay")

        coordinator.render(cells: reliable.cells, identity: secondIdentity, on: map)
        let changed = try XCTUnwrap(map.overlays.first as? TerritoryOverlay)
        XCTAssertFalse(changed === first, "A changed status must replace the rendered overlay")
    }

    func testInitialFailureThenRetryDistinguishesErrorFromTrueEmpty() async throws {
        var offline = true
        let empty = try JSONDecoder().decode(TerritoryGrid.self, from: Data(#"{"cells":[],"truncated":false}"#.utf8))
        let model = TerritoriesViewModel { _, _ in
            if offline { throw FixtureError.offline }
            return empty
        }

        await model.load(region: region, span: region.span)
        XCTAssertNil(model.grid)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)

        offline = false
        await model.retry()
        XCTAssertEqual(model.grid?.cells.count, 0)
        XCTAssertNil(model.errorMessage, "An authoritative empty response must clear the earlier failure")
    }

    func testFailurePreservesPreviousGridButZoomingOutRemovesIt() async throws {
        var offline = false
        let initial = try grid()
        let model = TerritoriesViewModel { _, _ in
            if offline { throw FixtureError.offline }
            return initial
        }

        await model.load(region: region, span: region.span)
        XCTAssertEqual(model.grid, initial)
        offline = true
        await model.load(region: region, span: region.span)
        XCTAssertEqual(model.grid, initial)
        XCTAssertNotNil(model.errorMessage, "Old data must be labelled stale after a failed refresh")

        model.regionChanged(region, span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        XCTAssertTrue(model.isZoomedOut)
        XCTAssertNil(model.grid, "Cells outside the supported viewport must not remain on the map")
    }
}
