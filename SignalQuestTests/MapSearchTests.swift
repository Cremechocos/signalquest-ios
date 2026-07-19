import XCTest
@testable import SignalQuest

@MainActor
final class MapSearchTests: XCTestCase {
    private func place(_ i: Int) -> PlaceResult {
        PlaceResult(id: "p\(i)", name: "Ville \(i)", subtitle: nil, latitude: 45, longitude: 5)
    }

    private func antenna(_ i: Int) -> AntennaSite {
        AntennaSite(
            id: "a\(i)", siteId: "S\(i)", anfrCode: nil, latitude: 45, longitude: 5,
            operators: [], technologies: [], bands: [], azimuths: [],
            sharingType: nil, crozonLeader: nil, isZTD: false, address: nil, height: nil, owner: nil
        )
    }

    func testMergePlacesFirstCappedAt8() {
        let merged = MapExplorerViewModel.mergeSearchResults(
            places: (0..<6).map(place), antennas: (0..<6).map(antenna)
        )
        XCTAssertEqual(merged.count, 8, "plafonné à 8")
        // 4 lieux d'abord…
        XCTAssertEqual(Array(merged.prefix(4).map(\.id)), ["p0", "p1", "p2", "p3"])
        // …puis 4 antennes.
        XCTAssertEqual(Array(merged.suffix(4).map(\.id)), ["antenna-a0", "antenna-a1", "antenna-a2", "antenna-a3"])
    }

    func testMergeFewResultsKeepsAllPlacesFirst() {
        let merged = MapExplorerViewModel.mergeSearchResults(
            places: [place(0), place(1)], antennas: [antenna(0)]
        )
        XCTAssertEqual(merged.map(\.id), ["p0", "p1", "antenna-a0"])
    }

    func testMergeAntennasOnlyWhenNoPlaces() {
        let merged = MapExplorerViewModel.mergeSearchResults(
            places: [], antennas: (0..<5).map(antenna)
        )
        XCTAssertEqual(merged.count, 5)
        XCTAssertTrue(merged.allSatisfy { if case .antenna = $0 { return true } else { return false } })
    }
}
