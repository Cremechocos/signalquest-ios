import XCTest
@testable import SignalQuest

/// Le marqueur d'antenne porte désormais trois signaux visuels (coche eNB,
/// anneau gNB, badge photo) et une adresse. Tous viennent de champs que le
/// backend n'émet qu'après déploiement : ces tests figent le comportement AVANT
/// (rien ne casse) autant qu'APRÈS (les signaux arrivent).
final class AntennaMarkerDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> AndroidAntennaMarker {
        try JSONDecoder.signalQuest.decode(AndroidAntennaMarker.self, from: Data(json.utf8))
    }

    /// Une tuile servie par un backend antérieur (ou déjà en cache disque) n'a ni
    /// `hasEnb` ni `hasGnb` : elle doit se décoder sans erreur et simplement ne
    /// pas afficher de coche.
    func testLegacyTileDecodesWithoutTheNewFields() throws {
        let marker = try decode("""
        {
          "id": "3079254", "supId": "3079254", "anfrCode": "0380123",
          "lat": 45.18, "lng": 5.72,
          "operator": "SFR", "operators": ["SFR"],
          "technologies": ["4G"], "azimuts": [30, 150, 270], "bands": [20]
        }
        """)
        XCTAssertFalse(marker.hasEnb)
        XCTAssertFalse(marker.hasGnb)
        XCTAssertFalse(marker.isZTD)
        XCTAssertEqual(marker.photoCount, 0)
    }

    func testIdentifiedSiteCarriesItsRadioFlags() throws {
        let marker = try decode("""
        {
          "id": "3079254", "supId": "3079254", "lat": 45.18, "lng": 5.72,
          "operators": ["SFR"], "technologies": ["5G", "4G"], "azimuts": [], "bands": [],
          "hasEnb": true, "hasGnb": true, "photoCount": 3, "validationCount": 7, "isZTD": true
        }
        """)
        XCTAssertTrue(marker.hasEnb)
        XCTAssertTrue(marker.hasGnb)
        XCTAssertTrue(marker.isZTD)
        XCTAssertEqual(marker.photoCount, 3)
        XCTAssertEqual(marker.validationCount, 7)
    }

    /// Le backend n'émet PAS de clé `address` : il envoie les composants ANFR
    /// séparément. Sans recomposition, l'adresse restait vide sur tous les sites
    /// venus des tuiles — c'est-à-dire le cas courant.
    func testAddressIsComposedFromAnfrComponents() throws {
        let marker = try decode("""
        {
          "id": "1", "lat": 45.18, "lng": 5.72, "operators": [], "technologies": [],
          "azimuts": [], "bands": [],
          "adr_lb_add1": "12 rue des Lilas", "adr_nm_cp": "38000", "commune": "Grenoble"
        }
        """)
        XCTAssertEqual(marker.address, "12 rue des Lilas, 38000 Grenoble")
    }

    func testAddressFallsBackToPlaceNameWhenStreetIsMissing() throws {
        let marker = try decode("""
        {
          "id": "1", "lat": 45.18, "lng": 5.72, "operators": [], "technologies": [],
          "azimuts": [], "bands": [], "adr_lb_lieu": "Lieu-dit Le Sappey", "commune": "Sappey"
        }
        """)
        XCTAssertEqual(marker.address, "Lieu-dit Le Sappey, Sappey")
    }

    func testAddressIsNilWhenNothingIsUsable() throws {
        let marker = try decode("""
        {"id": "1", "lat": 45.18, "lng": 5.72, "operators": [], "technologies": [], "azimuts": [], "bands": []}
        """)
        XCTAssertNil(marker.address, "Mieux vaut pas de ligne qu'une ligne vide dans la fiche")
    }

    /// Le site 5G se déduit des technologies normalisées, sans champ dédié :
    /// c'est ce test qui garantit que l'anneau 5G apparaît là où il doit.
    func testSiteDetectsFiveGFromNormalizedTechnologies() {
        let site = AntennaSite(
            id: "1", siteId: "1", latitude: 45.18, longitude: 5.72,
            operators: ["SFR"], technologies: ["5G NR 3500", "LTE 800"], bands: [],
            azimuths: [], sharingType: nil, crozonLeader: nil,
            address: nil, height: nil, owner: nil
        )
        XCTAssertTrue(site.has5G)

        let lteOnly = AntennaSite(
            id: "2", siteId: "2", latitude: 45.18, longitude: 5.72,
            operators: ["SFR"], technologies: ["LTE 800"], bands: [],
            azimuths: [], sharingType: nil, crozonLeader: nil,
            address: nil, height: nil, owner: nil
        )
        XCTAssertFalse(lteOnly.has5G)
    }

    // MARK: Fiche détaillée

    /// Statut, dates et technos en projet sont des champs additifs : la fiche
    /// doit rester décodable sur un backend qui ne les envoie pas encore.
    func testDetailsDecodeWithoutTheAdditiveFields() throws {
        let core = try JSONDecoder.signalQuest.decode(AntennaCoreDetails.self, from: Data("""
        {
          "id": "1", "supId": "1", "anfrCode": "0380123", "lat": 45.18, "lng": 5.72,
          "operators": ["SFR"], "technologies": ["4G"], "azimuts": [30],
          "frequencyBands": ["LTE 800"], "siteInfo": {"supportType": "Pylône"}
        }
        """.utf8))
        XCTAssertNil(core.status)
        XCTAssertTrue(core.technologiesInProject.isEmpty)
        XCTAssertTrue(core.isInService, "Sans statut connu, on n'accuse pas un site d'être éteint")
        XCTAssertNil(core.siteInfo.pylonHeight)
    }

    func testDetailsDecodeStatusAndProjectTechnologies() throws {
        let core = try JSONDecoder.signalQuest.decode(AntennaCoreDetails.self, from: Data("""
        {
          "id": "1", "supId": "1", "anfrCode": "0380123", "lat": 45.18, "lng": 5.72,
          "operators": ["SFR"], "technologies": ["4G"], "azimuts": [30],
          "frequencyBands": ["LTE 800"],
          "status": "Projet approuvé",
          "technologiesInProject": {"lte": ["800"], "5g": ["3500"]},
          "siteInfo": {
            "supportType": "Pylône", "pylonHeight": 42,
            "antennaTypes": ["Panneau"], "implantationDate": "2019-04-01",
            "commissioningDate": "2019-06-15", "lastUpdated": "2026-07-01"
          }
        }
        """.utf8))
        XCTAssertEqual(core.status, "Projet approuvé")
        XCTAssertFalse(core.isInService)
        XCTAssertEqual(core.technologiesInProject, ["5G 3500", "4G 800"])
        XCTAssertEqual(core.siteInfo.pylonHeight, 42)
        XCTAssertEqual(core.siteInfo.antennaTypes, ["Panneau"])
        XCTAssertEqual(core.siteInfo.commissioningDate, "2019-06-15")
    }

    /// La hauteur utilisée pour la ligne de visée doit dégrader du plus précis au
    /// plus grossier, et se déclarer estimée quand elle vient du support.
    func testRadiatingHeightFallsBackAndFlagsEstimates() {
        let precise = AntennaSiteInfo(antennaHeight5g: 28, pylonHeight: 42)
        XCTAssertEqual(precise.radiatingHeightMeters, 28)
        XCTAssertFalse(precise.radiatingHeightIsEstimated)

        let fromSupport = AntennaSiteInfo(supportHeight: "42 m")
        XCTAssertEqual(fromSupport.radiatingHeightMeters, 42)
        XCTAssertTrue(fromSupport.radiatingHeightIsEstimated)

        let fromPylon = AntennaSiteInfo(pylonHeight: 35)
        XCTAssertEqual(fromPylon.radiatingHeightMeters, 35)
        XCTAssertTrue(fromPylon.radiatingHeightIsEstimated)

        let unknown = AntennaSiteInfo()
        XCTAssertNil(unknown.radiatingHeightMeters)
        XCTAssertFalse(unknown.radiatingHeightIsEstimated, "Rien à estimer quand rien n'est connu")
    }
}

/// La fiche s'ouvre avant que le détail du site ne réponde. Ce que la tuile
/// porte déjà — hauteur du support, nature, systèmes radio — décide donc de la
/// justesse du premier affichage : sans ces champs, la ligne de visée se
/// calculait sur une hauteur par défaut et restait fausse jusqu'à ce qu'on
/// actualise à la main.
final class AntennaTileGeometryDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> AndroidAntennaMarker {
        try JSONDecoder.signalQuest.decode(AndroidAntennaMarker.self, from: Data(json.utf8))
    }

    func testSupportHeightIsReadFromTheTile() throws {
        let marker = try decode("""
        {
          "id": "2877566", "supId": "2877566", "lat": 45.65, "lng": 5.47,
          "operators": ["SFR"], "technologies": ["5G"], "azimuts": [0, 90, 270], "bands": [],
          "support_info": {"hauteur": "52,2", "nature": "Monument religieux", "type_proprietaire": "Commune"}
        }
        """)
        // La virgule décimale est celle de l'ANFR : la lire comme un séparateur
        // de milliers donnerait 522 m.
        XCTAssertEqual(try XCTUnwrap(marker.supportHeightMeters), 52.2, accuracy: 0.01)
        XCTAssertEqual(marker.supportNature, "Monument religieux")
    }

    func testRadioSystemsGiveTheLowestBand() throws {
        let marker = try decode("""
        {
          "id": "1", "lat": 45.65, "lng": 5.47, "operators": [], "technologies": [],
          "azimuts": [], "bands": [],
          "emr_lb_systeme": ["5G NR 3500", "LTE 700", "LTE 2600"]
        }
        """)
        XCTAssertEqual(marker.radioSystems.count, 3)
        let frequencies = marker.radioSystems.compactMap { label -> Int? in
            guard let range = label.range(of: #"\d{3,4}"#, options: .regularExpression) else { return nil }
            return Int(label[range])
        }
        XCTAssertEqual(frequencies.min(), 700, "C'est la bande la plus basse qui sert au calcul de Fresnel")
    }

    /// Une tuile sans ces champs doit rester décodable : le site s'affichera
    /// simplement sans hauteur, comme avant.
    func testTileWithoutSupportInfoStillDecodes() throws {
        let marker = try decode("""
        {"id": "1", "lat": 45.65, "lng": 5.47, "operators": [], "technologies": [], "azimuts": [], "bands": []}
        """)
        XCTAssertNil(marker.supportHeightMeters)
        XCTAssertNil(marker.supportNature)
        XCTAssertTrue(marker.radioSystems.isEmpty)
    }

    func testMalformedSupportHeightIsIgnoredRatherThanGuessed() throws {
        let marker = try decode("""
        {
          "id": "1", "lat": 45.65, "lng": 5.47, "operators": [], "technologies": [], "azimuts": [], "bands": [],
          "support_info": {"nature": "Pylône treillis"}
        }
        """)
        XCTAssertNil(marker.supportHeightMeters)
        XCTAssertEqual(marker.supportNature, "Pylône treillis")
    }
}
