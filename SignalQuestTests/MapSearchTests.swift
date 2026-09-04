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

    func testQuickSearchSendsExactWorldwideMarket() throws {
        let items = try AntennasService.quickSearchQueryItems(
            query: "Bamako",
            market: " ml ",
            department: nil
        )
        let query = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(query["q"], "Bamako")
        XCTAssertEqual(query["market"], "ML")

        let crossBorder = try AntennasService.quickSearchQueryItems(
            query: "Genève",
            market: "ch",
            department: nil
        )
        XCTAssertEqual(crossBorder.first(where: { $0.name == "market" })?.value, "CH")

        let reunion = try AntennasService.quickSearchQueryItems(
            query: "Saint-Denis",
            market: "DROM",
            department: "974"
        )
        XCTAssertEqual(reunion.first(where: { $0.name == "department" })?.value, "974")
    }

    func testQuickSearchRefusesUnknownMarketBeforeNetwork() {
        XCTAssertThrowsError(
            try AntennasService.quickSearchQueryItems(
                query: "Bamako",
                market: "UNKNOWN",
                department: nil
            )
        ) { error in
            guard case AntennasServiceError.marketRequired = error else {
                return XCTFail("Erreur inattendue: \(error)")
            }
        }
    }

    func testSelectedPlaceBuildsASeparateSearchPin() throws {
        let pin = try XCTUnwrap(
            MapAnnotationPayload.searchPin(
                latitudeText: "50.62925",
                longitudeText: "3.057256",
                title: "Lille",
                subtitle: "Nord"
            )
        )

        XCTAssertEqual(pin.id, "searched-place-pin")
        XCTAssertEqual(pin.coordinate.latitude, 50.62925, accuracy: 0.0000001)
        XCTAssertEqual(pin.coordinate.longitude, 3.057256, accuracy: 0.0000001)
        XCTAssertEqual(pin.title, "Lille")
        XCTAssertEqual(pin.subtitle, "Nord")
        XCTAssertEqual(pin.glyphOverride, "mappin.circle.fill")
        XCTAssertEqual(pin.tint, SQColor.searchPin)
        XCTAssertTrue(pin.isSearchPin)
    }

    func testClearedOrInvalidCoordinatesDoNotBuildASearchPin() {
        XCTAssertNil(
            MapAnnotationPayload.searchPin(
                latitudeText: "",
                longitudeText: "",
                title: "",
                subtitle: ""
            )
        )
        XCTAssertNil(
            MapAnnotationPayload.searchPin(
                latitudeText: "95",
                longitudeText: "3",
                title: "Invalide",
                subtitle: ""
            )
        )
    }
}
