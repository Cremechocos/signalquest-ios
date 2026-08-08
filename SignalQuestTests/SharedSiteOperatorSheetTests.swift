import XCTest
import SwiftUI
@testable import SignalQuest

/// Sur un site partagé, changer d'opérateur doit changer SA fiche. Deux choses
/// l'en empêchaient, toutes deux vérifiées ici à partir du site ANFR 2991320
/// (83-79 rue Léon Blum, Rosny-sous-Bois — SFR/Bouygues/Orange/Free, 10 secteurs) :
/// les replis de la fiche lisaient l'agrégat du premier opérateur fusionné, et la
/// grille des secteurs imposait une largeur que la fiche ne pouvait pas tenir.
final class SharedSiteOperatorSheetTests: XCTestCase {

    // MARK: Azimuts scopés opérateur

    private func sharedSite(
        azimuths: [Double],
        byOperator: [String: [Double]]
    ) -> AntennaSite {
        var site = AntennaSite(
            id: "2991320",
            siteId: "2991320",
            anfrCode: "0932703794",
            latitude: 48.87,
            longitude: 2.48,
            operators: ["SFR", "BOUYGUES", "ORANGE", "FREE"],
            technologies: ["5G", "4G"],
            bands: [1, 3, 7, 78],
            azimuths: azimuths,
            sharingType: "ztd_same_support",
            crozonLeader: nil,
            address: nil,
            height: 30,
            owner: "SFR"
        )
        site.azimuthsByOperator = byOperator
        return site
    }

    /// Le cœur du bug : la tuile ne met dans `azimuts` que les secteurs du
    /// PREMIER opérateur fusionné. Demander ceux d'Orange devait rendre ceux
    /// d'Orange, pas ceux de SFR.
    func testAzimuthsAreScopedToTheSelectedOperator() {
        let site = sharedSite(
            azimuths: [50, 70, 100, 135, 150, 215, 230, 250, 280, 330],
            byOperator: [
                "SFR": [50, 70, 100, 135, 150, 215, 230, 250, 280, 330],
                "ORANGE": [50, 70, 95, 135, 150, 230, 250, 275, 315, 330],
                "FREE": [50, 70, 100, 135, 215, 230, 250, 280],
            ]
        )
        XCTAssertEqual(site.azimuths(for: "ORANGE"), [50, 70, 95, 135, 150, 230, 250, 275, 315, 330])
        XCTAssertEqual(site.azimuths(for: "FREE").count, 8, "Free n'a que 8 secteurs sur ce support")
        XCTAssertNotEqual(site.azimuths(for: "ORANGE"), site.azimuths(for: "SFR"))
    }

    /// La casse de la clé vient du backend, pas de nous.
    func testOperatorLookupIgnoresCase() {
        let site = sharedSite(azimuths: [0], byOperator: ["ORANGE": [95, 275]])
        XCTAssertEqual(site.azimuths(for: "orange"), [95, 275])
    }

    /// Un dictionnaire non vide qui n'a pas la clé demandée veut dire « pas
    /// d'azimut publié pour cet opérateur » — surtout pas « prends ceux du
    /// voisin », qui est exactement la fiche figée que l'on corrige.
    func testUnknownOperatorOnASharedSiteYieldsNoAzimuths() {
        let site = sharedSite(azimuths: [0, 120, 240], byOperator: ["SFR": [0, 120, 240]])
        XCTAssertTrue(site.azimuths(for: "BOUYGUES").isEmpty)
    }

    /// Site mono-opérateur (ou tuile servie avant le déploiement du champ) :
    /// aucune régression, le repli historique reste en place.
    func testSingleOperatorSiteKeepsItsAzimuths() {
        let site = sharedSite(azimuths: [30, 150, 270], byOperator: [:])
        XCTAssertEqual(site.azimuths(for: "SFR"), [30, 150, 270])
        XCTAssertEqual(site.azimuths(for: "ALL"), [30, 150, 270])
    }

    // MARK: Largeur de la grille des secteurs

    /// Largeur utile réelle de la grille dans la fiche : écran d'iPhone moins la
    /// marge du ScrollView (18 pt) et celle de la section repliable (16 pt).
    private static let availableWidth: CGFloat = 393 - 2 * 18 - 2 * 16

    @MainActor
    private func gridWidth(sectorCount: Int) -> CGFloat {
        let azimuths = (0..<sectorCount).map { Double($0) * (360 / Double(sectorCount)) }
        let view = AntennaSectorGridView(
            azimuths: azimuths,
            siteBands: ["5G NR 3500", "LTE 1800", "LTE 2100", "LTE 2600"],
            // Non vide : c'est le cas « les secteurs ne portent pas les mêmes
            // bandes », celui qui déclenche la grille (et celui de la vidéo).
            sectorSystems: azimuths.enumerated().map { index, azimuth in
                AntennaSectorSystems(
                    azimuth: azimuth,
                    systems: index.isMultiple(of: 2) ? ["5G NR 3500", "LTE 1800"] : ["5G NR 3500"]
                )
            },
            technologies: ["5G", "4G"],
            projectBands: [],
            antennaHeightMeters: 30,
            tint: .red
        )
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: Self.availableWidth, height: .greatestFiniteMagnitude)).width
    }

    /// Le débordement : dix secteurs × 42 pt rigides = 420 pt réclamés pour 325
    /// disponibles. La fiche entière devenait plus large que l'écran et le
    /// ScrollView la centrait, rognée des deux côtés.
    @MainActor
    func testTenSectorGridStaysWithinTheSheet() {
        XCTAssertLessThanOrEqual(gridWidth(sectorCount: 10), Self.availableWidth + 0.5)
    }

    /// Même garantie dans le cas extrême, où seule la variante défilante tient.
    @MainActor
    func testVeryWideGridStaysWithinTheSheet() {
        XCTAssertLessThanOrEqual(gridWidth(sectorCount: 18), Self.availableWidth + 0.5)
    }

    /// Un site à trois secteurs tenait déjà : il ne doit pas se resserrer pour
    /// autant.
    @MainActor
    func testThreeSectorGridIsUnchanged() {
        XCTAssertLessThanOrEqual(gridWidth(sectorCount: 3), Self.availableWidth + 0.5)
    }
}
