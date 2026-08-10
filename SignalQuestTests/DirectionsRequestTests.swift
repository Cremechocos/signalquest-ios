import CoreLocation
import MapKit
import XCTest
@testable import SignalQuest

/// Verrouille la réception d'une demande d'itinéraire venant de Plan.
///
/// L'`Info.plist` déclare `MKDirectionsApplicationSupportedModes` : SignalQuest
/// figure donc dans la liste des apps d'itinéraire de Plan. Déclarer sans traiter
/// est pire que ne rien déclarer — l'utilisateur choisit SignalQuest, l'app
/// s'ouvre et ne fait rien, ce qui est un motif de rejet en revue.
///
/// Ce qui est testé ici est la DÉCISION (valider, nommer, rejeter), pas
/// l'extraction MapKit : le format d'URL que Plan produit n'est pas documenté et
/// `isDirectionsRequest(_:)` rejette tout ce qu'on fabriquerait à la main. Cette
/// moitié se vérifie en lançant un itinéraire depuis Plan, pas ici.
final class DirectionsRequestTests: XCTestCase {

    private let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)

    /// Une URL qui n'est pas une demande d'itinéraire ne doit RIEN déclencher :
    /// le handler est appelé pour toutes les ouvertures d'URL de l'app, y compris
    /// les deep links `signalquest://`.
    func testNonDirectionsUrlIsIgnored() {
        XCTAssertNil(DirectionsRequestHandler.destination(from: URL(string: "signalquest://map")!))
        XCTAssertNil(DirectionsRequestHandler.destination(from: URL(string: "https://signalquest.fr")!))
    }

    func testNamedDestinationKeepsItsName() throws {
        let destination = try XCTUnwrap(DirectionsRequestHandler.destination(
            coordinate: paris, name: "Tour Eiffel", placemarkTitle: "Champ de Mars"))
        XCTAssertEqual(destination.name, "Tour Eiffel")
        XCTAssertEqual(destination.coordinate.latitude, paris.latitude, accuracy: 0.0001)
    }

    /// Le nom est facultatif côté Plan : on retombe sur l'adresse du placemark.
    func testFallsBackToPlacemarkTitle() throws {
        let destination = try XCTUnwrap(DirectionsRequestHandler.destination(
            coordinate: paris, name: nil, placemarkTitle: "Champ de Mars"))
        XCTAssertEqual(destination.name, "Champ de Mars")
    }

    /// Sans aucun libellé, la destination apparaîtrait sans étiquette dans les
    /// récents et dans la prévisualisation CarPlay.
    func testUnnamedDestinationStillGetsALabel() throws {
        let destination = try XCTUnwrap(DirectionsRequestHandler.destination(
            coordinate: paris, name: nil, placemarkTitle: nil))
        XCTAssertFalse(destination.name.isEmpty)
    }

    /// Un nom vide ou blanc ne vaut pas mieux qu'aucun nom.
    func testBlankNameIsTreatedAsMissing() throws {
        let destination = try XCTUnwrap(DirectionsRequestHandler.destination(
            coordinate: paris, name: "   ", placemarkTitle: nil))
        XCTAssertFalse(destination.name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// (0, 0) est le golfe de Guinée, pas une destination : c'est ce que rend une
    /// requête vide, et l'accepter enverrait le conducteur au large.
    func testNullIslandIsRejected() {
        XCTAssertNil(DirectionsRequestHandler.destination(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            name: "Nulle part", placemarkTitle: nil))
    }

    func testInvalidCoordinateIsRejected() {
        XCTAssertNil(DirectionsRequestHandler.destination(
            coordinate: CLLocationCoordinate2D(latitude: 200, longitude: 500),
            name: "Impossible", placemarkTitle: nil))
    }
}
