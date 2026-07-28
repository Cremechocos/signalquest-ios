import XCTest
@testable import SignalQuest

/// Quantification des coordonnées publiées.
///
/// C'est la seule barrière entre la trace réelle d'un utilisateur et ce qui part
/// sur la carte publique. Une erreur de signe ou un arrondi qui ne « colle » pas
/// exactement ne se voit sur aucune capture : les points sont juste un peu
/// ailleurs, ou ne se dédoublonnent plus.
final class CoordinateGridTests: XCTestCase {

    private let step = CoordinateGrid.publicationStep

    /// Toute valeur produite doit être un multiple exact du pas — c'est ce qui
    /// permet à deux points d'un même carreau d'être ÉGAUX, donc dédoublonnables.
    func testSnappedValuesAreExactMultiplesOfTheStep() {
        for raw in [45.764_312, 4.835_701, -0.000_1, 179.999_9, -89.123_456] {
            let snapped = CoordinateGrid.snap(raw)
            let multiples = snapped / step
            XCTAssertEqual(
                multiples, multiples.rounded(), accuracy: 1e-6,
                "\(raw) → \(snapped) n'est pas sur la grille"
            )
        }
    }

    /// Deux positions distantes de moins d'un demi-pas doivent tomber sur le même
    /// carreau : sinon la publication garde une précision qu'elle prétend retirer.
    func testNearbyPointsCollapseToTheSameCell() {
        let a = CoordinateGrid.snap(45.764_300)
        let b = CoordinateGrid.snap(45.764_390)
        XCTAssertEqual(a, b, "Deux points à 10 m devraient partager un carreau")
    }

    /// …et deux positions franchement éloignées ne doivent PAS fusionner, sinon
    /// la trace se réduirait à un point.
    func testDistantPointsStaySeparate() {
        XCTAssertNotEqual(CoordinateGrid.snap(45.764_0), CoordinateGrid.snap(45.766_0))
    }

    /// L'hémisphère sud et l'ouest du méridien sont des coordonnées négatives :
    /// un arrondi qui tronque au lieu d'arrondir s'y trompe systématiquement de
    /// sens. Le décalage doit rester borné par un demi-pas des deux côtés.
    func testNegativeCoordinatesAreSnappedSymmetrically() {
        for raw in [-45.764_312, -0.000_312, -179.999_812] {
            let snapped = CoordinateGrid.snap(raw)
            XCTAssertLessThanOrEqual(
                abs(snapped - raw), step / 2 + 1e-9,
                "\(raw) → \(snapped) : décalage supérieur à un demi-pas"
            )
        }
    }

    /// Le décalage maximal doit valoir un demi-pas, jamais un pas entier.
    func testDisplacementNeverExceedsHalfAStep() {
        for index in 0..<400 {
            let raw = 43.0 + Double(index) * 0.000_137
            XCTAssertLessThanOrEqual(abs(CoordinateGrid.snap(raw) - raw), step / 2 + 1e-9)
        }
    }

    /// Un pas ~50 m : la grille doit rester plus fine que la cadence de capture,
    /// sinon deux points capturés se retrouveraient dans le même carreau.
    func testStepIsAboutFiftyMetres() {
        let metresPerDegreeLatitude = 111_320.0
        let metres = step * metresPerDegreeLatitude
        XCTAssertGreaterThan(metres, 40, "Grille trop fine : la trace redevient identifiante")
        XCTAssertLessThan(metres, 70, "Grille trop grossière : quadrillage visible au zoom de rue")
    }

    /// Une coordonnée invalide ne doit pas être « réparée » en silence : elle
    /// ressort telle quelle, à charge de l'appelant de la refuser.
    func testNonFiniteValuesPassThrough() {
        XCTAssertTrue(CoordinateGrid.snap(.nan).isNaN)
        XCTAssertEqual(CoordinateGrid.snap(.infinity), .infinity)
    }

    /// Zéro reste zéro — et surtout ne devient pas `-0.0`, qui sérialiserait en
    /// `-0` dans le JSON envoyé au backend.
    func testZeroStaysZero() {
        XCTAssertEqual(CoordinateGrid.snap(0), 0)
        XCTAssertFalse(CoordinateGrid.snap(0).sign == .minus)
    }

    /// Les deux chemins de publication (couverture et speedtest) DOIVENT produire
    /// la même position : sinon un speedtest et son point de couverture, pris au
    /// même endroit, atterrissent à deux places différentes sur la carte.
    func testCoverageAndSpeedtestAgreeOnTheSameCell() throws {
        let latitude = 45.764_312
        let longitude = 4.835_701
        let coveragePoint = CoveragePointUpload(
            latitude: latitude, longitude: longitude, timestamp: 0, technology: "4G"
        ).minimizedCoordinates()
        let speedtestPoint = try XCTUnwrap(
            SpeedtestSubmission.minimizedCoordinates(Coordinates(latitude: latitude, longitude: longitude))
        )
        XCTAssertEqual(coveragePoint.latitude, speedtestPoint.latitude)
        XCTAssertEqual(coveragePoint.longitude, speedtestPoint.longitude)
    }
}
