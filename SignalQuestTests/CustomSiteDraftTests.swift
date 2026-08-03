import XCTest
@testable import SignalQuest

/// Créer un site à partir de cellules observées : les identifiants radio sont
/// repris tels quels et l'utilisateur ne les ressaisit pas. Une erreur ici
/// produit un site faux que personne ne relira — d'où ces tests.
final class CustomSiteDraftTests: XCTestCase {

    private func cell(
        id: String,
        operatorKey: String?,
        enb: String? = nil,
        gnb: String? = nil,
        pci: Int? = nil,
        band: Int? = nil,
        mcc: Int? = nil,
        mnc: Int? = nil,
        observations: Int? = nil,
        lat: Double = 50.61,
        lng: Double = 4.32
    ) throws -> AndroidCommunitySiteMarker {
        var fields: [String] = [
            "\"id\": \"\(id)\"", "\"lat\": \(lat)", "\"lng\": \(lng)",
            "\"radioNodeType\": \"LTE\""
        ]
        if let operatorKey { fields.append("\"operatorKey\": \"\(operatorKey)\"") }
        if let enb { fields.append("\"enb\": \"\(enb)\"") }
        if let gnb { fields.append("\"gnb\": \"\(gnb)\"") }
        if let pci { fields.append("\"pci\": \(pci)") }
        if let band { fields.append("\"band\": \(band)") }
        if let mcc { fields.append("\"mcc\": \(mcc)") }
        if let mnc { fields.append("\"mnc\": \(mnc)") }
        if let observations { fields.append("\"observationCount\": \(observations)") }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder.signalQuest.decode(AndroidCommunitySiteMarker.self, from: Data(json.utf8))
    }

    /// JSON réel d'une cellule wallonne, avec les champs que la tuile ne servait
    /// pas avant l'enrichissement.
    func testEnrichedCellDecodesItsFullRadioIdentity() throws {
        let marker = try JSONDecoder.signalQuest.decode(AndroidCommunitySiteMarker.self, from: Data("""
        {
          "id": "cmptmhsnx0lr32fmr23a6h5wc",
          "candidateKey": "BE:BE-WAL:206:20:LTE:4597",
          "candidateKind": "observed_cell",
          "marketCode": "BE", "regionCode": "BE-WAL", "sourceMode": "community",
          "operatorKey": "TELENET_BASE_BE", "networkGroupKey": "TELENET_BASE_BE",
          "radioNodeType": "LTE", "enb": "4597", "gnb": null,
          "cellId": "1176322", "ci": "1176322", "pci": 311, "tac": "4402",
          "earfcn": 1501, "nrarfcn": null, "band": 3, "mcc": 206, "mnc": 20,
          "lat": 50.610685614352526, "lng": 4.328178427047469,
          "radiusMeters": 1263.33, "confidenceScore": 100, "confidenceLevel": "HIGH",
          "observationCount": 303, "distinctUserCount": 1,
          "medianAccuracyMeters": 5.952,
          "firstObservedAt": "2026-05-02T09:11:00.000Z",
          "lastObservedAt": "2026-06-06T17:25:40.786Z"
        }
        """.utf8))
        XCTAssertEqual(marker.pci, 311)
        XCTAssertEqual(marker.tac, "4402")
        XCTAssertEqual(marker.earfcn, 1501)
        XCTAssertEqual(marker.band, 3)
        XCTAssertEqual(marker.mcc, 206)
        XCTAssertEqual(marker.mnc, 20)
        XCTAssertEqual(marker.cellId, "1176322")
        XCTAssertEqual(marker.medianAccuracyMeters ?? 0, 5.952, accuracy: 0.001)
        XCTAssertNotNil(marker.firstObservedAt)
    }

    /// Une tuile servie avant l'enrichissement se décode sans erreur.
    func testLegacyCellDecodesWithoutTheNewFields() throws {
        let marker = try cell(id: "a", operatorKey: "POST_LU", enb: "250")
        XCTAssertNil(marker.pci)
        XCTAssertNil(marker.band)
        XCTAssertEqual(marker.enb, "250")
    }

    // MARK: Pré-remplissage

    func testDraftCarriesEachCellRadioIdentity() throws {
        let cells = [
            try cell(id: "a", operatorKey: "POST_LU", enb: "250", pci: 242, band: 3, mcc: 270, mnc: 1),
            try cell(id: "b", operatorKey: "TANGO_LU", enb: "807", pci: 118, band: 20, mcc: 270, mnc: 77)
        ]
        let draft = CustomSiteDraft.fromObservedCells(
            cells, latitude: 49.61, longitude: 6.13, name: "Pylône test", type: "PYLONE"
        ).normalized()

        XCTAssertEqual(draft.operatorRadios.count, 2)
        let post = try XCTUnwrap(draft.operatorRadios.first { $0.operator == "POST_LU" })
        XCTAssertEqual(post.enb, "250")
        XCTAssertEqual(post.pci, 242)
        XCTAssertEqual(post.band, 3)
        XCTAssertEqual(post.mcc, 270)
        XCTAssertEqual(post.technology, "LTE")
        // La position est celle de l'utilisateur, pas le centroïde des cellules.
        XCTAssertEqual(draft.latitude, 49.61, accuracy: 0.0001)
        XCTAssertEqual(draft.longitude, 6.13, accuracy: 0.0001)
    }

    /// Le backend REJETTE une radio dont l'opérateur n'est pas listé en hébergé :
    /// sans ce complètement, le site partirait sans aucun identifiant.
    func testHostedOperatorsAlwaysCoverEveryRadio() throws {
        let cells = [
            try cell(id: "a", operatorKey: "POST_LU", enb: "250"),
            try cell(id: "b", operatorKey: "ORANGE_LU", enb: "980")
        ]
        var draft = CustomSiteDraft.fromObservedCells(
            cells, latitude: 49.6, longitude: 6.1, name: "Site", type: "PYLONE"
        )
        draft.hostedOperators = []       // on simule un brouillon mal assemblé
        let normalized = draft.normalized()
        XCTAssertEqual(Set(normalized.hostedOperators), ["POST_LU", "ORANGE_LU"])
    }

    /// Le propriétaire de l'infra est forcément hébergé sur sa propre infra.
    func testInfraOwnerIsAddedToHostedOperators() throws {
        var draft = CustomSiteDraft.fromObservedCells(
            [try cell(id: "a", operatorKey: "POST_LU", enb: "250")],
            latitude: 49.6, longitude: 6.1, name: "Site", type: "PYLONE"
        )
        draft.infraOwnerOperator = "TANGO_LU"
        XCTAssertTrue(draft.normalized().hostedOperators.contains("TANGO_LU"))
    }

    /// Deux cellules du même opérateur = deux secteurs d'un même site, alors que
    /// le backend n'attend qu'une radio par opérateur. On garde la mieux mesurée.
    func testSameOperatorTwiceKeepsTheMostObservedCell() throws {
        let cells = [
            try cell(id: "a", operatorKey: "POST_LU", enb: "250", pci: 1, observations: 12),
            try cell(id: "b", operatorKey: "POST_LU", enb: "250", pci: 2, observations: 480)
        ]
        let draft = CustomSiteDraft.fromObservedCells(
            cells, latitude: 49.6, longitude: 6.1, name: "Site", type: "PYLONE"
        ).normalized()
        XCTAssertEqual(draft.operatorRadios.count, 1)
        XCTAssertEqual(draft.operatorRadios.first?.pci, 2)
    }

    /// Une cellule sans opérateur ne peut pas devenir une radio : le backend
    /// l'écarterait, autant ne pas la proposer.
    func testCellWithoutOperatorIsIgnored() throws {
        let draft = CustomSiteDraft.fromObservedCells(
            [try cell(id: "a", operatorKey: nil, enb: "250")],
            latitude: 49.6, longitude: 6.1, name: "Site", type: "PYLONE"
        ).normalized()
        XCTAssertTrue(draft.operatorRadios.isEmpty)
        XCTAssertTrue(draft.hostedOperators.isEmpty)
    }

    // MARK: Bornes du backend

    func testNameLengthMatchesTheBackendContract() throws {
        let cells = [try cell(id: "a", operatorKey: "POST_LU", enb: "250")]
        func draft(_ name: String) -> CustomSiteDraft {
            CustomSiteDraft.fromObservedCells(cells, latitude: 49.6, longitude: 6.1, name: name, type: "PYLONE")
        }
        XCTAssertFalse(draft("A").isValid, "1 caractère : sous le minimum backend")
        XCTAssertTrue(draft("AB").isValid)
        XCTAssertTrue(draft(String(repeating: "x", count: 120)).isValid)
        // Au-delà, le nom est rogné plutôt que refusé — un aller-retour perdu
        // pour un dépassement de longueur serait inutilement pénible.
        XCTAssertEqual(draft(String(repeating: "x", count: 200)).normalized().name.count, 120)
    }

    func testInvalidCoordinatesAreRejectedBeforeSending() throws {
        let cells = [try cell(id: "a", operatorKey: "POST_LU", enb: "250")]
        XCTAssertFalse(CustomSiteDraft.fromObservedCells(cells, latitude: 91, longitude: 6.1, name: "Site", type: "PYLONE").isValid)
        XCTAssertFalse(CustomSiteDraft.fromObservedCells(cells, latitude: 49.6, longitude: 181, name: "Site", type: "PYLONE").isValid)
        XCTAssertFalse(CustomSiteDraft.fromObservedCells(cells, latitude: .nan, longitude: 6.1, name: "Site", type: "PYLONE").isValid)
    }

    func testDescriptionIsCappedAtTheBackendLimit() throws {
        let draft = CustomSiteDraft.fromObservedCells(
            [try cell(id: "a", operatorKey: "POST_LU", enb: "250")],
            latitude: 49.6, longitude: 6.1, name: "Site", type: "PYLONE",
            description: String(repeating: "y", count: 900)
        ).normalized()
        XCTAssertEqual(draft.description?.count, 500)
    }

    /// Le corps JSON doit porter les clés qu'attend la route, sinon la création
    /// part avec des champs que le backend ignore en silence.
    func testEncodedBodyMatchesTheApiContract() throws {
        let draft = CustomSiteDraft.fromObservedCells(
            [try cell(id: "a", operatorKey: "POST_LU", enb: "250", pci: 242, band: 3)],
            latitude: 49.6, longitude: 6.1, name: "Pylône", type: "PYLONE"
        ).normalized()
        let data = try JSONEncoder().encode(draft)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "Pylône")
        XCTAssertEqual(json["type"] as? String, "PYLONE")
        XCTAssertNotNil(json["latitude"])
        XCTAssertNotNil(json["longitude"])
        XCTAssertEqual((json["hostedOperators"] as? [String]) ?? [], ["POST_LU"])
        let radios = try XCTUnwrap(json["operatorRadios"] as? [[String: Any]])
        XCTAssertEqual(radios.first?["operator"] as? String, "POST_LU")
        XCTAssertEqual(radios.first?["enb"] as? String, "250")
        XCTAssertEqual(radios.first?["pci"] as? Int, 242)
    }
}
