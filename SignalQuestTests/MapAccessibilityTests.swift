import XCTest
import CoreLocation
@testable import SignalQuest

/// Les descriptions d'accessibilité de la carte ne sont JAMAIS affichées : une
/// erreur y est invisible en test visuel comme en relecture d'écran. D'où ces
/// tests, qui sont le seul filet sur ce texte.
final class MapAccessibilityTests: XCTestCase {

    private func payload(
        kind: MapDisplayItem.Kind,
        title: String = "Orange 4G",
        subtitle: String = "700 MHz",
        metric: String? = nil,
        clusterCount: Int? = nil
    ) -> MapAnnotationPayload {
        MapAnnotationPayload(
            id: "1", kind: kind, title: title, subtitle: subtitle,
            coordinate: CLLocationCoordinate2D(latitude: 48.8, longitude: 2.3),
            metric: metric, backendId: nil, details: nil, antennaId: nil,
            clusterCount: clusterCount, azimuths: [], showsAzimuths: false
        )
    }

    /// Le label doit nommer la NATURE de l'élément : « Orange 4G » seul ne dit
    /// pas à un lecteur d'écran s'il s'agit d'une antenne ou d'une mesure.
    func testLabelNamesTheKind() {
        XCTAssertTrue(MapAccessibility.describe(payload(kind: .antenna)).label.hasPrefix("Antenne"))
        XCTAssertTrue(MapAccessibility.describe(payload(kind: .photo)).label.hasPrefix("Photo"))
        XCTAssertTrue(MapAccessibility.describe(payload(kind: .friend)).label.hasPrefix("Ami"))
        XCTAssertTrue(MapAccessibility.describe(payload(kind: .outage)).label.hasPrefix("Incident"))
    }

    func testLabelIncludesTheTitle() {
        XCTAssertTrue(MapAccessibility.describe(payload(kind: .antenna)).label.contains("Orange 4G"))
    }

    /// Un titre vide ne doit pas produire un label tronqué du type « Antenne ».
    func testEmptyTitleFallsBackGracefully() {
        let description = MapAccessibility.describe(payload(kind: .antenna, title: ""))
        XCTAssertTrue(description.label.contains("Antenne"))
        XCTAssertFalse(description.label.hasSuffix(" "), "Label mal formé : \(description.label)")
        XCTAssertGreaterThan(description.label.count, "Antenne".count)
    }

    /// L'information utile va en `value` : VoiceOver l'énonce après le label et
    /// le rotor ne l'utilise pas pour la recherche.
    func testValueCarriesSubtitleAndMetric() throws {
        let description = MapAccessibility.describe(
            payload(kind: .speedtest, title: "SFR", subtitle: "5G", metric: "142 Mbps")
        )
        let value = try XCTUnwrap(description.value)
        XCTAssertTrue(value.contains("5G"), value)
        XCTAssertTrue(value.contains("142 Mbps"), value)
    }

    func testValueIsNilWhenNothingToSay() {
        XCTAssertNil(MapAccessibility.describe(payload(kind: .coverage, subtitle: "", metric: nil)).value)
    }

    /// Un cluster n'est pas un lieu : il doit annoncer ce qu'il regroupe, et
    /// dire comment le développer.
    func testClusterAnnouncesItsCount() {
        let description = MapAccessibility.describe(payload(kind: .antenna, clusterCount: 42))
        XCTAssertTrue(description.label.contains("42"), description.label)
        XCTAssertTrue(description.label.contains("antennes"), description.label)
        XCTAssertNotNil(description.hint, "Un cluster doit indiquer qu'il faut zoomer")
    }

    /// Un « cluster » de 1 est un élément simple : il ne doit pas être annoncé
    /// comme un groupe.
    func testSingleElementClusterIsNotAnnouncedAsGroup() {
        let description = MapAccessibility.describe(payload(kind: .antenna, clusterCount: 1))
        XCTAssertFalse(description.label.contains("Groupe"), description.label)
    }

    /// L'indice dit ce que le tap PRODUIT — non déductible sans voir l'écran —
    /// et ne répète pas le label.
    func testHintDescribesTheOutcomeWithoutRepeatingTheLabel() {
        for kind in [MapDisplayItem.Kind.antenna, .photo, .friend, .outage, .planned] {
            let description = MapAccessibility.describe(payload(kind: kind))
            let hint = description.hint
            XCTAssertNotNil(hint, "\(kind) devrait annoncer son action")
            XCTAssertNotEqual(hint, description.label)
        }
    }

    /// Les couches non tappables n'ont pas d'indice : annoncer une action
    /// inexistante est pire que se taire.
    func testNonInteractiveKindsHaveNoHint() {
        for kind in [MapDisplayItem.Kind.coverage, .speedtest, .validation, .session, .communitySite] {
            XCTAssertNil(MapAccessibility.describe(payload(kind: kind)).hint, "\(kind)")
        }
    }

    /// Aucun `kind` ne doit produire une description vide : c'est le défaut que
    /// l'exhaustivité du `switch` est censée rendre impossible.
    func testEveryKindProducesANonEmptyLabel() {
        let kinds: [MapDisplayItem.Kind] = [
            .friend, .photo, .validation, .session, .coverage,
            .speedtest, .outage, .planned, .antenna, .communitySite
        ]
        for kind in kinds {
            let label = MapAccessibility.describe(payload(kind: kind)).label
            XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty, "\(kind)")
        }
    }

    /// `SQMapKitAnnotation` n'implémentait ni `title` ni `subtitle`, alors que
    /// ce sont les propriétés dont MapKit dérive l'accessibilité par défaut :
    /// les cartes utilisant la vue système restaient muettes pour rien.
    func testAnnotationExposesTitleAndSubtitleToMapKit() {
        let annotation = SQMapKitAnnotation(payload: payload(kind: .antenna))
        XCTAssertEqual(annotation.title, "Orange 4G")
        XCTAssertEqual(annotation.subtitle, "700 MHz")
    }

    /// Un titre vide doit donner `nil`, pas une chaîne vide : MapKit afficherait
    /// sinon un callout au titre blanc.
    func testAnnotationReturnsNilRatherThanEmptyStrings() {
        let annotation = SQMapKitAnnotation(payload: payload(kind: .antenna, title: "", subtitle: ""))
        XCTAssertNil(annotation.title)
        XCTAssertNil(annotation.subtitle)
    }

    // MARK: - Exposition réelle des vues d'annotation

    /// Test DÉCISIF : construit une vraie vue de marqueur et vérifie qu'elle
    /// devient un élément d'accessibilité étiqueté.
    ///
    /// Un test UI ne peut pas le prouver : XCUITest retrouve une vue par son
    /// `accessibilityIdentifier` même quand `isAccessibilityElement` est faux,
    /// donc il passerait dans les deux cas. Seule l'inspection directe de la vue
    /// distingue « présent dans l'arbre » de « annoncé par VoiceOver ».
    @MainActor
    func testMarkerViewBecomesAnAccessibilityElement() {
        let annotation = SQMapKitAnnotation(payload: payload(kind: .antenna))
        let view = SQMapKitMarkerView(annotation: annotation, reuseIdentifier: "test")
        XCTAssertFalse(view.isAccessibilityElement, "Une MKAnnotationView ne l'est pas par défaut")

        view.apply(annotation.payload)

        XCTAssertTrue(view.isAccessibilityElement, "Sans cela, VoiceOver ignore le marqueur")
        XCTAssertEqual(view.accessibilityLabel, MapAccessibility.describe(annotation.payload).label)
        XCTAssertEqual(view.accessibilityValue, MapAccessibility.describe(annotation.payload).value)
        XCTAssertTrue(view.accessibilityTraits.contains(.button), "Le marqueur est actionnable")
        XCTAssertEqual(view.accessibilityIdentifier, "map.marker")
    }

    /// Le label doit suivre le contenu : un marqueur réutilisé pour une autre
    /// antenne ne doit pas annoncer l'ancienne.
    @MainActor
    func testMarkerLabelFollowsItsPayload() {
        let first = SQMapKitAnnotation(payload: payload(kind: .antenna, title: "Orange"))
        let view = SQMapKitMarkerView(annotation: first, reuseIdentifier: "test")
        view.apply(first.payload)
        let firstLabel = view.accessibilityLabel

        let second = payload(kind: .photo, title: "Pylône rue Victor Hugo")
        view.apply(second)

        XCTAssertNotEqual(view.accessibilityLabel, firstLabel)
        XCTAssertTrue(view.accessibilityLabel?.contains("Pylône") == true, view.accessibilityLabel ?? "nil")
    }
}
