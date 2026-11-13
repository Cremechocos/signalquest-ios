import XCTest
@testable import SignalQuest

/// OFFICIAL-NEARBY r1 : faits officiels de la fiche (§3) et avertissement après création (§2).
/// Valeurs reprises de registres publics (instantané du 13/11/2026), sans adresse.
final class OfficialNearbyTests: XCTestCase {
    private func details(_ json: String) throws -> OfficialSiteDetails {
        try JSONDecoder.signalQuest.decode(OfficialSiteDetails.self, from: Data(json.utf8))
    }

    /// CH:BAKOM:Sunrise_ZH301_3_2699484_1263084.
    func testSwissPositionReadsItsClassLimitTypeAndOperation() throws {
        let swiss = try details(#"{"powerClass":"medium","powerClassMaxW":5000,"installationLimitVm":5,"installationType":"outdoor_high","adaptiveMode":"partial"}"#)
        XCTAssertEqual(swiss.powerClass, .medium)
        XCTAssertFalse(swiss.isBrussels)
        let fr = Locale(identifier: "fr_FR")
        let watts = 5000.formatted(.number.grouping(.automatic).locale(fr))
        XCTAssertEqual(swiss.powerClassText(locale: fr), "Moyenne, jusqu’à \(watts)\u{00A0}W")
        XCTAssertEqual(swiss.installationLimitText(locale: fr), "5,0\u{00A0}V/m")
        XCTAssertEqual(swiss.installationText, "Extérieure, plus de 6\u{00A0}W\u{00A0}ERP", "Unité jamais coupée de son nombre")
        XCTAssertTrue(swiss.adaptivePartial)
        XCTAssertEqual(swiss.title, "Données officielles OFCOM")
    }

    /// CH:BAKOM:Swisscom_LANS_2762058_1173220 : classe forte, sans plafond ; et le piège
    /// `adaptiveMode: null` PRÉSENT (CH:BAKOM:Sunrise_ZU407_3_2692402_1241977).
    func testHighClassShowsItsFloorAndANullAdaptiveModeShowsNoOperationRow() throws {
        let high = try details(#"{"powerClass":"high","powerClassMaxW":null,"powerClassMinW":5000,"installationLimitVm":5,"installationType":"outdoor_high","adaptiveMode":null}"#)
        let fr = Locale(identifier: "fr_FR")
        XCTAssertEqual(high.powerClassText(locale: fr), "Forte, plus de \(5000.formatted(.number.grouping(.automatic).locale(fr)))\u{00A0}W")
        XCTAssertFalse(high.adaptivePartial)
        let unknown = try details(#"{"powerClass":"giant","installationType":"rooftop"}"#)
        XCTAssertNil(unknown.powerClass, "Valeur inconnue : rien d'inventé")
        XCTAssertNil(unknown.installationType)
        XCTAssertTrue(unknown.isEmpty)
    }

    /// BE:BRU:Bruxelles_1D_octroye_02VVL_42098B1 : seul le nombre d'opérateurs.
    func testBrusselsPositionShowsOnlyItsOperatorCount() throws {
        let brussels = try details(#"{"operatorCount":2}"#)
        XCTAssertTrue(brussels.isBrussels)
        XCTAssertEqual(brussels.operatorCount, 2)
        XCTAssertEqual(brussels.title, "Données officielles Bruxelles Environnement")
        XCTAssertNil(brussels.powerClassText())
    }


    /// `officialDetails` est à la RACINE de la fiche (à côté de `antenna`), quelle que soit la
    /// plateforme ; une fiche française ou un serveur antérieur n'en a pas.
    func testAntennaDetailsReadOfficialDetailsAtTheRoot() throws {
        let swiss = try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
        {
          "antenna": {
            "id": "CH:BAKOM:Sunrise_ZH301_3_2699484_1263084", "supId": "CH:BAKOM:Sunrise_ZH301_3_2699484_1263084",
            "lat": 47.51096938959109, "lng": 8.759287377258746,
            "operators": ["SUNRISE_CH"], "technologies": ["5G", "4G"]
          },
          "officialDetails": {"powerClass":"medium","powerClassMaxW":5000,"installationLimitVm":5,"installationType":"outdoor_high","adaptiveMode":"partial"}
        }
        """.utf8))
        XCTAssertEqual(swiss.officialDetails?.powerClass, .medium)
        XCTAssertEqual(swiss.officialDetails?.installationType, .outdoorHigh)
        let french = try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
        {"antenna": {"id": "24763", "supId": "24763", "lat": 42.9158, "lng": 1.0139, "operators": ["SFR"], "technologies": ["4G"]}}
        """.utf8))
        XCTAssertNil(french.officialDetails)
        XCTAssertNotNil(french.core, "Le champ additif ne casse pas la fiche")
    }

    func testCreationWarningNamesTheNearestOfficialPosition() throws {
        let result = try JSONDecoder.signalQuest.decode(CustomSiteCreationResult.self, from: Data("""
        {"site":{"id":"cm-new","slug":"pylone"},"warnings":{"nearbyOfficial":[
          {"siteKey":"BE:VLA:53LED_00","supId":"BE:VLA:53LED_00","market":"BE","region":"BE-VLA","operator":"PROXIMUS_BE","distanceMeters":120.4,"hasEnb":false,"hasGnb":false,"enbCount":0},
          {"siteKey":"BE:VLA:C2_40472_G1","supId":"BE:VLA:C2_40472_G1","market":"BE","region":"BE-VLA","operator":"PROXIMUS_BE","distanceMeters":10.2,"hasEnb":false,"hasGnb":false,"enbCount":0}
        ]}}
        """.utf8))
        XCTAssertEqual(result.id, "cm-new")
        XCTAssertEqual(result.nearestOfficialMeters, 10)
        XCTAssertNotNil(result.nearbyOfficialNotice)
        let plain = try JSONDecoder.signalQuest.decode(CustomSiteCreationResult.self, from: Data(#"{"id":"cm-2"}"#.utf8))
        XCTAssertNil(plain.nearestOfficialMeters, "Hors BE/CH ou ancien serveur : pas d'avertissement")
    }
}
