import XCTest
import MapKit
@testable import SignalQuest

/// Les territoires ont deux modes d'échec silencieux : un statut mal décodé
/// vide la carte sans erreur, et une géométrie fausse décale la grille sans que
/// rien ne le signale.
final class TerritoryTests: XCTestCase {

    private func cell(_ status: String, north: Double = 45.82, south: Double = 45.80,
                      east: Double = 4.86, west: Double = 4.84) -> TerritoryCell {
        let json = """
        {"cellKey":"grid:2290:242","status":"\(status)",
         "bounds":{"north":\(north),"south":\(south),"east":\(east),"west":\(west)},
         "pointsCount":12,"userCount":3,"trustScore":0.81,
         "lastObservedAt":"2026-07-20T10:00:00Z","mine":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(TerritoryCell.self, from: Data(json.utf8))
    }

    /// La zone blanche est l'état le plus intéressant du jeu — et celui qui
    /// était inatteignable avant le refactor SQL du backend.
    func testVirginIsARealStatus() {
        XCTAssertEqual(cell("virgin").status, .virgin)
        XCTAssertEqual(cell("virgin").statusLabel, "Zone blanche")
    }

    /// Un statut inconnu ne doit PAS faire échouer le décodage : la carte
    /// entière se viderait pour un mot ajouté côté serveur.
    func testAnUnknownStatusFallsBackInsteadOfFailing() {
        XCTAssertEqual(cell("conquered_by_aliens").status, .observed)
    }

    /// Chaque statut doit se distinguer visuellement, sinon la légende ment.
    func testEveryStatusHasItsOwnFill() {
        let statuses: [TerritoryCell.Status] = [.virgin, .observed, .reliable, .complete, .stale]
        let colors = statuses.map { s -> String in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            cell(s.rawValue).fillColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%.3f-%.3f-%.3f-%.3f", r, g, b, a)
        }
        XCTAssertEqual(Set(colors).count, statuses.count, "Deux statuts indiscernables : \(colors)")
    }

    /// La zone blanche doit rester DISCRÈTE : elle est l'état par défaut de la
    /// carte, la peindre vivement ferait un damier illisible.
    func testVirginIsTheFaintestFill() {
        var alphas: [TerritoryCell.Status: CGFloat] = [:]
        for s in [TerritoryCell.Status.virgin, .observed, .reliable, .complete] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            cell(s.rawValue).fillColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            alphas[s] = a
        }
        XCTAssertEqual(alphas.min(by: { $0.value < $1.value })?.key, .virgin)
    }

    /// Le rectangle projeté doit couvrir la cellule, sans inversion ni
    /// dimension nulle — une grille décalée d'une cellule est invisible en
    /// relecture de code.
    func testMapRectMatchesTheBounds() {
        let rect = cell("observed").mapRect
        XCTAssertGreaterThan(rect.size.width, 0)
        XCTAssertGreaterThan(rect.size.height, 0)
        let backNW = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let backSE = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        XCTAssertEqual(backNW.latitude, 45.82, accuracy: 0.0001)
        XCTAssertEqual(backNW.longitude, 4.84, accuracy: 0.0001)
        XCTAssertEqual(backSE.latitude, 45.80, accuracy: 0.0001)
        XCTAssertEqual(backSE.longitude, 4.86, accuracy: 0.0001)
    }

    /// `truncated` absent doit valoir `false` : le supposer vrai afficherait un
    /// avertissement permanent.
    func testGridDefaultsAreSafe() throws {
        let grid = try JSONDecoder().decode(TerritoryGrid.self, from: Data(#"{"cells":[]}"#.utf8))
        XCTAssertFalse(grid.truncated)
        XCTAssertEqual(grid.cellSize, 0.02)
        XCTAssertTrue(grid.cells.isEmpty)
    }

    /// Le seuil de zoom protège le serveur : au-delà, les cellules font moins
    /// d'un pixel et l'agrégation SQL travaillerait pour rien.
    @MainActor
    func testZoomThresholdIsCoarserThanACityButFinerThanACountry() {
        // ~1,2° ≈ 130 km : une agglomération tient dedans, une région non.
        let threshold = TerritoriesViewModel.maxSpanDegrees
        XCTAssertGreaterThan(threshold, 0.5)
        XCTAssertLessThan(threshold, 3.0)
    }
}
