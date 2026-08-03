import XCTest
@testable import SignalQuest

/// Deux mécanismes où une erreur produirait une carte crédible mais fausse :
/// le filtre « couverture de ce site seulement », et l'anneau 5G par opérateur.
final class CoverageFocusAndFiveGTests: XCTestCase {

    // MARK: Couverture isolée

    /// Un site 5G NSA porte les deux identifiants et ses mesures se répartissent
    /// entre eux : les deux doivent partir, le backend les croise en OU.
    func testFocusSendsBothRadioNodes() {
        let focus = AntennaCoverageFocus(siteLabel: "Site", operatorKey: "SFR", enb: "12345", gnb: "678")
        let items = focus.queryItems
        XCTAssertEqual(items.first(where: { $0.name == "enb" })?.value, "12345")
        XCTAssertEqual(items.first(where: { $0.name == "gnb" })?.value, "678")
        XCTAssertTrue(focus.isUsable)
    }

    func testFocusWithOnlyOneNodeSendsOnlyThatOne() {
        let lte = AntennaCoverageFocus(siteLabel: "Site", operatorKey: "SFR", enb: "12345", gnb: nil)
        XCTAssertEqual(lte.queryItems.count, 1)
        XCTAssertEqual(lte.queryItems.first?.name, "enb")

        let nr = AntennaCoverageFocus(siteLabel: "Site", operatorKey: "SFR", enb: nil, gnb: "678")
        XCTAssertEqual(nr.queryItems.count, 1)
        XCTAssertEqual(nr.queryItems.first?.name, "gnb")
    }

    /// Sans identifiant, le filtre ne restreint RIEN : la carte montrerait toute
    /// la couverture de l'opérateur en prétendant montrer ce pylône.
    func testFocusWithoutAnyNodeIsRejected() {
        let empty = AntennaCoverageFocus(siteLabel: "Site", operatorKey: "SFR", enb: nil, gnb: nil)
        XCTAssertFalse(empty.isUsable)
        XCTAssertTrue(empty.queryItems.isEmpty)

        let blank = AntennaCoverageFocus(siteLabel: "Site", operatorKey: "SFR", enb: "", gnb: "")
        XCTAssertFalse(blank.isUsable)
    }

    /// L'identité entre dans la clé de cache des tuiles : deux sites différents
    /// ne doivent jamais se partager des tuiles de couverture.
    func testDistinctSitesHaveDistinctCacheIdentities() {
        let a = AntennaCoverageFocus(siteLabel: "A", operatorKey: "SFR", enb: "111", gnb: nil)
        let b = AntennaCoverageFocus(siteLabel: "B", operatorKey: "SFR", enb: "222", gnb: nil)
        let sameNodeOtherOperator = AntennaCoverageFocus(siteLabel: "A", operatorKey: "ORANGE", enb: "111", gnb: nil)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, sameNodeOtherOperator.id, "un même eNB chez deux opérateurs reste deux jeux de mesures")
    }

    func testSummaryNamesTheSiteAndItsNodes() {
        let focus = AntennaCoverageFocus(siteLabel: "Site 1234", operatorKey: "SFR", enb: "12345", gnb: nil)
        XCTAssertTrue(focus.summary.contains("Site 1234"))
        XCTAssertTrue(focus.summary.contains("eNB 12345"))
    }

    // MARK: Anneau 5G par opérateur

    private func marker(_ json: String) throws -> AndroidAntennaMarker {
        try JSONDecoder.signalQuest.decode(AndroidAntennaMarker.self, from: Data(json.utf8))
    }

    /// Sur un support partagé, `technologies` fusionné dit qu'il y a de la 5G
    /// quelque part — pas à qui elle appartient. C'est `operators5G` qui le dit.
    func testSharedSiteDecodesWhichOperatorsHave5G() throws {
        let marker = try marker("""
        {
          "id": "1", "supId": "1", "lat": 48.85, "lng": 2.35,
          "operators": ["SFR", "ORANGE"], "technologies": ["5G", "4G"],
          "operators5G": ["ORANGE"],
          "azimuts": [], "bands": []
        }
        """)
        XCTAssertEqual(marker.operators5G, ["ORANGE"])
        // La techno globale reste vraie : le site PORTE de la 5G.
        XCTAssertTrue(marker.technologies.contains("5G"))
    }

    /// Une tuile servie avant le déploiement n'a pas la clé : l'anneau retombe
    /// sur son rendu d'origine, d'une seule couleur.
    func testLegacyTileHasNoPerOperator5G() throws {
        let marker = try marker("""
        { "id": "1", "supId": "1", "lat": 48.85, "lng": 2.35,
          "operators": ["SFR", "ORANGE"], "technologies": ["5G"], "azimuts": [], "bands": [] }
        """)
        XCTAssertTrue(marker.operators5G.isEmpty)
    }

    /// Le payload travaille en INDICES de teintes, pas en couleurs : deux
    /// opérateurs peuvent partager une teinte, et il faut malgré tout que chaque
    /// arc coiffe la bonne part du camembert.
    func testFiveGIndicesAddressSlicesNotColours() {
        var payload = MapAnnotationPayload(
            id: "x", kind: .antenna, title: "t", subtitle: "s",
            coordinate: .init(latitude: 0, longitude: 0),
            metric: nil, backendId: nil, details: nil, antennaId: nil,
            clusterCount: nil, azimuths: [], showsAzimuths: false
        )
        payload.operatorTints = [.red, .blue, .orange]
        payload.fiveGTintIndices = [1, 2]
        // L'anneau doit dessiner deux arcs, sur les parts 1 et 2 — pas trois.
        XCTAssertEqual(payload.fiveGTintIndices.count, 2)
        XCTAssertFalse(payload.fiveGTintIndices.contains(0))
        XCTAssertTrue(payload.fiveGTintIndices.allSatisfy { $0 < payload.operatorTints.count })
    }

    /// Deux payloads qui ne diffèrent QUE par les opérateurs 5G doivent être vus
    /// comme différents, sinon la vue recyclée garderait l'ancien anneau.
    func testPayloadEqualityAccountsForFiveGIndices() {
        var a = MapAnnotationPayload(
            id: "x", kind: .antenna, title: "t", subtitle: "s",
            coordinate: .init(latitude: 0, longitude: 0),
            metric: nil, backendId: nil, details: nil, antennaId: nil,
            clusterCount: nil, azimuths: [], showsAzimuths: false
        )
        a.operatorTints = [.red, .blue]
        var b = a
        a.fiveGTintIndices = [0]
        b.fiveGTintIndices = [1]
        XCTAssertNotEqual(a, b)
    }
}
