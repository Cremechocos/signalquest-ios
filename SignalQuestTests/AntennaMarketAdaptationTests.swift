import XCTest
@testable import SignalQuest

/// La fiche antenne sert cinq registres qui ne remplissent pas les mêmes champs
/// et ne donnent pas le même sens aux mêmes clés. Ces tests figent l'adaptation
/// par marché à partir de réponses RÉELLES relevées en production (août 2026).
final class AntennaMarketAdaptationTests: XCTestCase {

    private func core(_ json: String) throws -> AntennaCoreDetails {
        try JSONDecoder.signalQuest.decode(AntennaCoreDetails.self, from: Data(json.utf8))
    }

    private func minimal(
        market: String,
        status: String? = nil,
        supportType: String? = nil,
        commune: String? = nil,
        extraSiteInfo: String = ""
    ) -> String {
        let statusJSON = status.map { "\"status\": \"\($0)\"," } ?? ""
        let supportJSON = supportType.map { "\"supportType\": \"\($0)\"," } ?? ""
        let communeJSON = commune.map { "\"commune\": \"\($0)\"," } ?? ""
        return """
        {
          "id": "x", "supId": "x", "anfrCode": "ID-1", "market": "\(market)",
          "lat": 0, "lng": 0, \(communeJSON) \(statusJSON)
          "operators": [], "technologies": [], "azimuts": [],
          "frequencyBands": [], "radioCarriers": [],
          "cellIdentifiers": { "enb": [], "gnb": [], "pci": [], "cellId": [] },
          "technical": {},
          "siteInfo": { \(supportJSON) \(extraSiteInfo) "_": null }
        }
        """
    }

    // MARK: Statut

    /// Suisse : l'OFCOM recopie la CLASSE D'INSTALLATION dans `status`
    /// (« Outdoor > 6 Werp »). Ce n'est pas un statut — l'afficher en badge
    /// orange laissait croire à un site à l'arrêt.
    func testSwissInstallationClassIsNotShownAsAStatus() throws {
        let core = try core(minimal(market: "CH", status: "Outdoor > 6 Werp", supportType: "Outdoor > 6 Werp"))
        XCTAssertNil(core.displayStatus)
    }

    /// Belgique : le BIPT publie « Octroye », sans accent. C'est bien un statut,
    /// mais de licence — on l'affiche correctement écrit et en attente.
    func testBelgianLicenceStatusIsSpelledAndFlaggedPending() throws {
        let core = try core(minimal(market: "BE", status: "Octroye"))
        XCTAssertEqual(core.displayStatus, "Licence octroyée")
        XCTAssertTrue(core.isPendingStatus)
        XCTAssertFalse(core.isInService)
    }

    func testFrenchStatusesAreKeptAsIs() throws {
        let inService = try core(minimal(market: "FR", status: "En service", supportType: "Immeuble"))
        XCTAssertEqual(inService.displayStatus, "En service")
        XCTAssertTrue(inService.isInService)
        XCTAssertFalse(inService.isPendingStatus)

        let project = try core(minimal(market: "FR", status: "Projet approuvé", supportType: "Pylône"))
        XCTAssertEqual(project.displayStatus, "Projet approuvé")
        XCTAssertTrue(project.isPendingStatus)
    }

    /// Canada : `status` est absent. Pas de badge, et surtout pas d'orange.
    func testCanadaHasNoStatusBadge() throws {
        let core = try core(minimal(market: "CA", supportType: "P"))
        XCTAssertNil(core.displayStatus)
        XCTAssertFalse(core.isPendingStatus)
    }

    // MARK: Libellés

    /// « Code ANFR » devant un identifiant ISED, BIPT ou OFCOM serait faux.
    func testRegistryLabelFollowsTheMarketRegulator() throws {
        XCTAssertEqual(try core(minimal(market: "FR")).registryLabel, "Code ANFR")
        XCTAssertEqual(try core(minimal(market: "DROM")).registryLabel, "Code ANFR")
        XCTAssertEqual(try core(minimal(market: "CA")).registryLabel, "Identifiant ISED")
        XCTAssertEqual(try core(minimal(market: "BE")).registryLabel, "Identifiant BIPT")
        XCTAssertEqual(try core(minimal(market: "CH")).registryLabel, "Identifiant OFCOM")
        XCTAssertEqual(try core(minimal(market: "PT")).registryLabel, "Identifiant du registre")
    }

    /// ISED met le code de province (« QC ») là où la France met une commune.
    func testCanadaLocalityIsLabelledProvince() throws {
        XCTAssertEqual(try core(minimal(market: "CA", commune: "QC")).localityLabel, "Province")
        XCTAssertEqual(try core(minimal(market: "FR", commune: "Paris 4e")).localityLabel, "Commune")
    }

    // MARK: Données structurelles

    /// BE/CH ne publient ni hauteur, ni secteurs, ni azimuts : la fiche doit
    /// pouvoir l'expliquer au lieu de ressembler à un chargement raté.
    func testMissingStructuralDataIsDetected() throws {
        XCTAssertFalse(try core(minimal(market: "BE")).hasStructuralData)
        XCTAssertTrue(try core(minimal(market: "FR", extraSiteInfo: "\"supportHeight\": \"29,5\",")).hasStructuralData)
        XCTAssertTrue(try core(minimal(market: "CA", extraSiteInfo: "\"sectorCount\": 2,")).hasStructuralData)
    }

    /// La hauteur arrive en chaîne du registre (« 29,5 » en France, « 4 » au
    /// Canada) : sans conversion, la fiche l'affichait sans unité.
    func testSupportHeightParsesRegistryStrings() throws {
        let fr = try core(minimal(market: "FR", extraSiteInfo: "\"supportHeight\": \"29,5\","))
        XCTAssertEqual(fr.siteInfo.supportHeightMeters ?? 0, 29.5, accuracy: 0.001)
        let ca = try core(minimal(market: "CA", extraSiteInfo: "\"supportHeight\": \"4\","))
        XCTAssertEqual(ca.siteInfo.supportHeightMeters ?? 0, 4, accuracy: 0.001)
    }

    // MARK: Sites relevés par un membre

    /// `/map/antenna/{id}` sert AUSSI les sites pointés à la main : la fiche est
    /// la même, seule la provenance change. JSON réel du site bosnien.
    func testCustomSiteDetailIsDecodedWithItsProvenance() throws {
        let core = try core("""
        {
          "id": "cmrvefks50b0f01qzafukx84k", "supId": "cmrvefks50b0f01qzafukx84k",
          "anfrCode": "cs-site-250", "siteKey": "cs-site-250",
          "displayName": "Pylône BH Telecom", "source": "user",
          "isCustomSite": true, "validationStatus": "validated",
          "status": null, "description": null,
          "lat": 43.823190524392345, "lng": 18.211460717057633,
          "address": "4 Kopišanj II, 71240 Hadžići", "commune": null,
          "market": "BA", "marketCode": "BA",
          "operators": ["BH_MOBILE_BA", "BH MOBILE"], "technologies": ["4G"],
          "azimuts": [], "frequencyBands": ["4G B3 (1820 MHz)"], "radioCarriers": [],
          "cellIdentifiers": { "enb": ["250"], "gnb": [], "pci": [], "cellId": [] },
          "technical": {}, "siteInfo": {}
        }
        """)
        XCTAssertTrue(core.isCustomSite)
        XCTAssertEqual(core.displayName, "Pylône BH Telecom")
        XCTAssertEqual(core.source, "user")
        XCTAssertEqual(core.validationStatus, "validated")
        XCTAssertEqual(core.address, "4 Kopišanj II, 71240 Hadžići")
        XCTAssertEqual(core.cellIdentifiers.enb, ["250"])
        // Le slug interne n'est l'identifiant d'aucun régulateur.
        XCTAssertEqual(core.registryLabel, "Référence du site")
        XCTAssertNil(core.displayStatus)
        XCTAssertFalse(core.hasStructuralData)
    }

    /// Une fiche officielle ne doit jamais être prise pour une contribution.
    func testOfficialSiteIsNotFlaggedAsCustom() throws {
        let core = try core(minimal(market: "FR", status: "En service", supportType: "Immeuble"))
        XCTAssertFalse(core.isCustomSite)
        XCTAssertNil(core.displayName)
        XCTAssertEqual(core.registryLabel, "Code ANFR")
    }
}


/// Sites pointés à la main : seule couche d'antennes disponible dans les pays
/// sans open data. Le JSON ci-dessous est la réponse RÉELLE de la tuile
/// bosnienne (z12/2255/1492, août 2026).
final class CustomSiteDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> AndroidCustomSiteTileResponse {
        try JSONDecoder.signalQuest.decode(AndroidCustomSiteTileResponse.self, from: Data(json.utf8))
    }

    func testBosnianCustomSiteDecodesWithItsRadioIdentifiers() throws {
        let response = try decode("""
        {
          "tile": { "z": 12, "x": 2255, "y": 1492 },
          "markers": [{
            "id": "cmrvefks50b0f01qzafukx84k",
            "lat": 43.823190524392345, "lng": 18.211460717057633,
            "name": "Pylône BH Telecom", "type": "PYLONE", "description": null,
            "createdByUserId": "cmoyedypl001428pfhwzv8jsx",
            "createdByDisplayName": "zlnvcc",
            "createdAt": "2026-07-22T01:23:46.037Z",
            "photoCount": 0, "primaryPhotoUrl": null,
            "validationStatus": "validated",
            "radio": {
              "enb": "250", "gnb": null, "cellId": "184", "pci": 242, "tac": "4074",
              "earfcn": 1351, "nrarfcn": null, "band": 3, "mcc": 218, "mnc": 90,
              "operator": "BH Mobile", "technology": "LTE"
            }
          }]
        }
        """)
        let marker = try XCTUnwrap(response.markers.first)
        XCTAssertEqual(marker.name, "Pylône BH Telecom")
        XCTAssertEqual(marker.typeLabel, "Pylône")
        XCTAssertTrue(marker.isValidated)
        XCTAssertEqual(marker.createdByDisplayName, "zlnvcc")
        XCTAssertEqual(marker.radio?.enb, "250")
        XCTAssertEqual(marker.radio?.pci, 242)
        XCTAssertEqual(marker.radio?.band, 3)
        // Le PLMN se recompose des deux moitiés : 218-90 = BH Telecom.
        XCTAssertEqual(marker.radio?.plmn, "218-90")
        XCTAssertFalse(marker.radio?.isEmpty ?? true)
    }

    /// Un site sans identifiants relevés doit rester affichable : la fiche masque
    /// simplement la section radio.
    func testCustomSiteWithoutRadioStaysUsable() throws {
        let response = try decode("""
        {
          "tile": { "z": 12, "x": 1, "y": 1 },
          "markers": [{ "id": "a", "lat": 1.5, "lng": 2.5, "name": null, "type": "CHATEAU_EAU",
                        "photoCount": 2, "validationStatus": "pending", "radio": {} }]
        }
        """)
        let marker = try XCTUnwrap(response.markers.first)
        XCTAssertEqual(marker.typeLabel, "Château d'eau")
        XCTAssertFalse(marker.isValidated)
        XCTAssertEqual(marker.photoCount, 2)
        XCTAssertTrue(marker.radio?.isEmpty ?? false)
    }

    /// Un type inconnu du backend ne doit pas disparaître de la fiche : on le
    /// rend lisible plutôt que de le masquer ou d'afficher la constante brute.
    func testUnknownSupportTypeIsHumanised() throws {
        let response = try decode("""
        { "tile": { "z": 1, "x": 0, "y": 0 },
          "markers": [{ "id": "b", "lat": 1, "lng": 1, "type": "ANTENNE_MURALE" }] }
        """)
        XCTAssertEqual(response.markers.first?.typeLabel, "Antenne Murale")
    }
}
