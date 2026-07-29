import XCTest
@testable import SignalQuest

/// Verrouille ce qui casserait en silence : le décodage du journal (dont `ci`,
/// qui arrive en CHAÎNE), la fusion idempotente avec pierres tombales,
/// l'agrégation en sites, le critère d'« identifié », et la charge
/// d'`identify/direct` — celle-là même qui envoyait un PLMN sous des noms que le
/// serveur ignore.
final class RadioLogsTests: XCTestCase {

    // MARK: Décodage

    /// `ci` est un `BigInt` côté serveur : `JSON.stringify` refuse de le
    /// sérialiser en nombre, il arrive donc en chaîne. Le décoder en `Int64`
    /// depuis un nombre ferait échouer la ligne entière.
    func testDecodesCiFromString() throws {
        let json = """
        {"items":[{
          "id":"c1","dedupeKey":"cap|1","scope":"cap","technology":"LTE","operator":"SFR",
          "mccMnc":"208-10","enb":"626821","ci":"160466202","pci":35,"band":3,
          "observedAt":"2026-07-01T10:00:00.000Z","updatedAt":"2026-07-01T10:00:00.000Z"
        }],"nextCursor":{"sinceAt":"2026-07-01T10:00:00.000Z","sinceId":"c1"},"hasMore":false,"readOnly":false}
        """
        let page = try JSONDecoder.signalQuest.decode(RadioLogPullPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].ci, 160_466_202)
        XCTAssertEqual(page.items[0].enb, "626821")
        XCTAssertEqual(page.items[0].mcc, "208")
        XCTAssertEqual(page.items[0].mnc, "10")
        XCTAssertEqual(page.nextCursor?.sinceId, "c1")
        XCTAssertFalse(page.hasMore)
    }

    /// Un NCI 5G dépasse 2^36 : il doit survivre au décodage sans perte.
    func testDecodesLargeNrCellIdentity() throws {
        let json = """
        {"items":[{"id":"c2","dedupeKey":"cap|2","scope":"cap","technology":"NR",
        "gnb":"9881","ci":"161806340","observedAt":"2026-07-01T10:00:00.000Z",
        "updatedAt":"2026-07-01T10:00:00.000Z"}],"hasMore":false}
        """
        let page = try JSONDecoder.signalQuest.decode(RadioLogPullPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items[0].ci, 161_806_340)
        XCTAssertTrue(page.items[0].isNr)
    }

    /// Une ligne malformée ne doit pas emporter le lot entier.
    func testMalformedRowDoesNotDropThePage() throws {
        let json = """
        {"items":[
          {"id":"ok","dedupeKey":"cap|ok","scope":"cap","technology":"LTE","enb":"1",
           "observedAt":"2026-07-01T10:00:00.000Z","updatedAt":"2026-07-01T10:00:00.000Z"},
          {"id":42}
        ],"hasMore":false}
        """
        let page = try JSONDecoder.signalQuest.decode(RadioLogPullPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.map(\.dedupeKey), ["cap|ok"])
    }

    /// `mccMnc` arrive sous plusieurs formes selon l'émetteur.
    func testPlmnSplitAcceptsEveryKnownShape() {
        XCTAssertEqual(RadioLogPlmn.split("208-10")?.mnc, "10")
        XCTAssertEqual(RadioLogPlmn.split("208/15")?.mnc, "15")
        XCTAssertEqual(RadioLogPlmn.split("20810")?.mcc, "208")
        XCTAssertEqual(RadioLogPlmn.split("20810")?.mnc, "10")
        XCTAssertEqual(RadioLogPlmn.split("208001")?.mnc, "001")
        XCTAssertNil(RadioLogPlmn.split(nil))
        XCTAssertNil(RadioLogPlmn.split("  "))
    }

    // MARK: Fusion

    /// Le curseur recule de 5 s à chaque page : le serveur RENVOIE des lignes
    /// déjà reçues. L'application doit donc être idempotente, et le dernier
    /// état reçu doit gagner.
    func testMergeIsIdempotentAndLastWriteWins() throws {
        let first = try entry(id: "a", dedupeKey: "cap|1", pci: 35)
        let updated = try entry(id: "a", dedupeKey: "cap|1", pci: 112)

        let once = RadioLogStore.applying(incoming: [first], to: [])
        XCTAssertEqual(once.count, 1)

        let twice = RadioLogStore.applying(incoming: [first], to: once)
        XCTAssertEqual(twice.count, 1, "Rejouer la même ligne ne doit pas la dupliquer")

        let merged = RadioLogStore.applying(incoming: [updated], to: twice)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].pci, 112)
    }

    /// Une pierre tombale (`deletedAt` non nul) est PRÉSENTE dans la réponse :
    /// elle propage une suppression faite ailleurs, elle ne s'ajoute pas.
    func testTombstoneRemovesTheRow() throws {
        let live = try entry(id: "a", dedupeKey: "cap|1", pci: 35)
        let tombstone = try entry(id: "a", dedupeKey: "cap|1", pci: nil, deleted: true)

        let stored = RadioLogStore.applying(incoming: [live], to: [])
        XCTAssertEqual(stored.count, 1)

        let after = RadioLogStore.applying(incoming: [tombstone], to: stored)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: Agrégation en sites

    /// L'unité de la page est le SITE. En 5G le gNB prime, sinon l'eNB.
    func testAggregatesByNodeWithGnbPriorityOnNr() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "626821", pci: 35, ci: 160_466_202),
            try entry(id: "2", dedupeKey: "cap|2", enb: "626821", pci: 112, ci: 160_466_178),
            try entry(id: "3", dedupeKey: "cap|3", enb: "626821", pci: 35, ci: 160_466_202),
            try entry(id: "4", dedupeKey: "cap|4", enb: "1", gnb: "9881", technology: "NR", pci: 500)
        ]
        let sites = RadioLogSiteBuilder.build(from: entries).sorted { $0.logCount > $1.logCount }

        XCTAssertEqual(sites.count, 2)
        let lte = try XCTUnwrap(sites.first { $0.kind == .enb })
        XCTAssertEqual(lte.node, "626821")
        XCTAssertEqual(lte.logCount, 3)
        XCTAssertEqual(lte.cells.count, 2, "Deux cellules distinctes, la première vue deux fois")
        XCTAssertEqual(lte.distinctPciCount, 2)
        XCTAssertEqual(lte.techLabel, "4G")

        let nr = try XCTUnwrap(sites.first { $0.kind == .gnb })
        XCTAssertEqual(nr.node, "9881", "En NR le gNB prime, même si un eNB est présent")
        XCTAssertEqual(nr.techLabel, "5G")
    }

    /// Plusieurs cellules partagent souvent le même PCI (bandes ou secteurs
    /// différents). Les pastilles décrivent le SITE : les répéter contredisait le
    /// « 3 PCI » affiché juste au-dessus — vu tel quel sur un site réel, qui
    /// alignait « PCI 261 » quatre fois.
    func testPciPillsAreDistinct() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "95566", pci: 261, ci: 1),
            try entry(id: "2", dedupeKey: "cap|2", enb: "95566", pci: 261, ci: 2),
            try entry(id: "3", dedupeKey: "cap|3", enb: "95566", pci: 261, ci: 3),
            try entry(id: "4", dedupeKey: "cap|4", enb: "95566", pci: 262, ci: 4)
        ]
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: entries).first)
        XCTAssertEqual(site.cells.count, 4, "Quatre cellules distinctes")
        XCTAssertEqual(site.distinctPciCount, 2)
        XCTAssertEqual(site.distinctPciLabels, ["PCI 261", "PCI 262"])
    }

    /// Une ligne supprimée ne compte pas dans les sites.
    func testDeletedEntriesAreNotAggregated() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "1", pci: 1),
            try entry(id: "2", dedupeKey: "cap|2", enb: "1", pci: 2, deleted: true)
        ]
        let sites = RadioLogSiteBuilder.build(from: entries)
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].logCount, 1)
    }

    /// La position est une MÉDIANE par axe : un fix GPS aberrant ne doit pas
    /// déplacer le site. Avec une moyenne, ce test échouerait de ~1,6°.
    func testMedianPositionResistsAnOutlierFix() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "1", latitude: 45.50, longitude: 5.30),
            try entry(id: "2", dedupeKey: "cap|2", enb: "1", latitude: 45.51, longitude: 5.31),
            try entry(id: "3", dedupeKey: "cap|3", enb: "1", latitude: 45.52, longitude: 5.32),
            try entry(id: "4", dedupeKey: "cap|4", enb: "1", latitude: 52.00, longitude: 13.00)
        ]
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: entries).first)
        let latitude = try XCTUnwrap(site.latitude)
        XCTAssertEqual(latitude, 45.515, accuracy: 0.001)
    }

    /// Deux opérateurs qui partagent un numéro d'eNB restent deux sites : les
    /// eNB ne sont uniques qu'à l'intérieur d'un réseau.
    func testSameNodeOnTwoOperatorsStaysTwoSites() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "42", operatorName: "SFR", mccMnc: "208-10"),
            try entry(id: "2", dedupeKey: "cap|2", enb: "42", operatorName: "ORANGE", mccMnc: "208-01")
        ]
        XCTAssertEqual(RadioLogSiteBuilder.build(from: entries).count, 2)
    }

    // MARK: Critère d'identification

    /// UN critère : l'eNB/gNB est-il connu du serveur ? Une résolution par
    /// PROXIMITÉ (aucun identifiant radio reconnu) n'est PAS une identification.
    func testProximityResolutionIsNotAnIdentification() throws {
        let site = try makeSite(kind: .enb, node: "626821")
        let proximity = try resolution("""
        {"found":true,"siteId":"0380001","resolutionMode":"proximity","matchedRadio":[],
         "distanceMeters":2900}
        """)
        XCTAssertEqual(RadioLogsService.state(from: proximity, site: site), .unidentified)
    }

    func testMatchedNodeIsAnIdentification() throws {
        let site = try makeSite(kind: .enb, node: "626821")
        let matched = try resolution("""
        {"found":true,"canonicalSiteId":"0382700518","matchedRadio":[{"type":"enb","value":"626821"}]}
        """)
        XCTAssertEqual(RadioLogsService.state(from: matched, site: site), .identified(siteId: "0382700518"))
    }

    /// SITE MUTUALISÉ — le cas qui a fait tomber 23 % du catalogue à tort.
    ///
    /// Le serveur renvoie `requiresUserConfirmation: true` et
    /// `resolutionMode: "shared_operator"` pour un site partagé entre opérateurs,
    /// TOUT EN listant l'eNB dans `matchedRadio` et en le sourçant depuis
    /// `fr_validations`. Le nœud est donc parfaitement connu : ce qui demande
    /// confirmation, c'est l'opérateur propriétaire, pas l'existence du nœud.
    /// Mesuré sur un journal réel : 35 sites sur 150 dans ce cas.
    func testSharedOperatorSiteWithMatchedNodeIsIdentified() throws {
        let site = try makeSite(kind: .enb, node: "531087")
        let shared = try resolution("""
        {"found":true,"siteId":"1713624","canonicalSiteId":"1713624",
         "resolutionMode":"shared_operator","source":"fr_validations",
         "requiresUserConfirmation":true,"operatorMatched":true,
         "matchedRadio":[{"type":"enb","value":"531087"}]}
        """)
        XCTAssertEqual(
            RadioLogsService.state(from: shared, site: site),
            .identified(siteId: "1713624"),
            "Un nœud listé dans matchedRadio est connu, quelle que soit la confirmation demandée sur le site"
        )
    }

    /// Sans AUCUNE correspondance détaillée, `requiresUserConfirmation` reprend
    /// tout son sens : le `found` ne vient alors pas d'un identifiant radio.
    func testConfirmationRequiredWithoutAnyMatchIsNotAnIdentification() throws {
        let site = try makeSite(kind: .enb, node: "1")
        let vague = try resolution("""
        {"found":true,"siteId":"S","matchedRadio":[],"requiresUserConfirmation":true}
        """)
        XCTAssertEqual(RadioLogsService.state(from: vague, site: site), .unidentified)
    }

    /// Un PCI reconnu sans le nœud ne suffit pas : c'est le nœud qui porte
    /// l'identification du site.
    func testMatchedPciAloneIsNotAnIdentification() throws {
        let site = try makeSite(kind: .gnb, node: "9881")
        let pciOnly = try resolution("""
        {"found":true,"siteId":"0380001","matchedRadio":[{"type":"pci","value":"500"}]}
        """)
        XCTAssertEqual(RadioLogsService.state(from: pciOnly, site: site), .unidentified)
    }

    func testNotFoundIsUnidentified() throws {
        let site = try makeSite(kind: .enb, node: "1")
        XCTAssertEqual(RadioLogsService.state(from: nil, site: site), .unidentified)
        let notFound = try resolution(#"{"found":false}"#)
        XCTAssertEqual(RadioLogsService.state(from: notFound, site: site), .unidentified)
    }

    // MARK: Charge d'identify/direct

    /// LE défaut historique : iOS envoyait `mcc`/`mnc`, que `DirectIdentifyBody`
    /// ne connaît pas. Résultat, aucun PLMN côté serveur → `400 MISSING_PLMN`.
    /// Ce test verrouille les noms que le serveur lit VRAIMENT.
    func testIdentifyPayloadCarriesPlmnUnderTheServerNames() async throws {
        let site = try makeSite(kind: .enb, node: "626821", mccMnc: "208-10", operatorName: "SFR")
        let candidate = RadioLogCandidate(
            id: "0382700518", siteId: "0382700518", latitude: 45.5, longitude: 5.3,
            operators: ["SFR"], technologies: ["4G"], address: nil,
            distanceMeters: 320, confidenceScore: 88, isServerHypothesis: true
        )
        let request = RadioLogIdentifyPicker.request(for: site, candidate: candidate)

        XCTAssertEqual(request.mcc, "208")
        XCTAssertEqual(request.mnc, "10")

        let encoded = try await encodeIdentifyBody(request)
        XCTAssertEqual(encoded["mobileCountryCode"] as? Int, 208)
        XCTAssertEqual(encoded["mobileNetworkCode"] as? Int, 10)
        XCTAssertNil(encoded["mcc"], "Le serveur ne lit pas `mcc` — l'envoyer revient à n'envoyer aucun PLMN")
        XCTAssertNil(encoded["mnc"])
        XCTAssertEqual(encoded["siteId"] as? String, "0382700518")
        XCTAssertEqual(encoded["enb"] as? String, "626821")
        XCTAssertEqual(encoded["tech"] as? String, "4G")
        XCTAssertNil(encoded["sectorIndex"], "Le secteur est dérivé par le serveur, sa règle fait autorité")
    }

    /// Sans PLMN dans le log, la table de repli opérateur→PLMN prend le relais —
    /// plutôt que de partir vers un `MISSING_PLMN` certain.
    func testIdentifyPayloadFallsBackToOperatorTableForPlmn() throws {
        let site = try makeSite(kind: .enb, node: "1", mccMnc: nil, operatorName: "Orange")
        let candidate = RadioLogCandidate(
            id: "S", siteId: "S", latitude: nil, longitude: nil, operators: [],
            technologies: [], address: nil, distanceMeters: nil, confidenceScore: nil,
            isServerHypothesis: false
        )
        let request = RadioLogIdentifyPicker.request(for: site, candidate: candidate)
        XCTAssertEqual(request.mcc, "208")
        XCTAssertEqual(request.mnc, "1")
    }

    /// `ci` part en CHAÎNE : le serveur le relit en `BigInt`, et un NCI 5G
    /// dépasse la précision d'un nombre JSON.
    func testIdentifyPayloadSendsCellIdentityAsString() async throws {
        let site = try makeSite(kind: .gnb, node: "9881", mccMnc: "208-15", operatorName: "FREE", ci: 161_806_340)
        let candidate = RadioLogCandidate(
            id: "S", siteId: "S", latitude: nil, longitude: nil, operators: [],
            technologies: [], address: nil, distanceMeters: nil, confidenceScore: nil,
            isServerHypothesis: false
        )
        let encoded = try await encodeIdentifyBody(RadioLogIdentifyPicker.request(for: site, candidate: candidate))
        XCTAssertEqual(encoded["ci"] as? String, "161806340")
        XCTAssertEqual(encoded["gnb"] as? String, "9881")
        XCTAssertEqual(encoded["tech"] as? String, "5G")
        XCTAssertNil(encoded["enb"], "Un site 5G n'envoie pas d'eNB")
    }

    /// On refuse de partir vers un échec prévisible, et on dit pourquoi.
    func testBlockingReasonNamesWhatIsMissing() throws {
        let noPlmn = try makeSite(kind: .enb, node: "1", mccMnc: nil, operatorName: "Inconnu")
        XCTAssertNotNil(RadioLogIdentifyPicker.blockingReason(for: noPlmn))

        let noPosition = try makeSite(kind: .enb, node: "1", mccMnc: "208-10", operatorName: "SFR", latitude: nil)
        XCTAssertNotNil(RadioLogIdentifyPicker.blockingReason(for: noPosition))

        let complete = try makeSite(kind: .enb, node: "1", mccMnc: "208-10", operatorName: "SFR")
        XCTAssertNil(RadioLogIdentifyPicker.blockingReason(for: complete))
    }

    // MARK: Libellés d'erreur

    /// Un code technique ne doit jamais s'afficher tel quel.
    func testKnownIdentifyErrorCodesGetAFrenchLabel() {
        for code in ["MISSING_PLMN", "OPERATOR_NOT_ALLOWED", "IDENTIFY_MARKET_MISMATCH",
                     "IDENTIFY_OPERATOR_MISMATCH", "VALIDATION_NODE_SITE_MISMATCH",
                     "IDENTIFY_SITE_NOT_FOUND", "MISSING_CELL_IDENTIFIERS", "PREMIUM_REQUIRED"] {
            let message = APIError.userFacingMessage(status: 400, code: code, serverMessage: code)
            XCTAssertFalse(message.contains("_"), "\(code) s'affiche encore brut : « \(message) »")
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: Fabriques

    private func entry(
        id: String,
        dedupeKey: String,
        enb: String? = nil,
        gnb: String? = nil,
        technology: String = "LTE",
        operatorName: String? = "SFR",
        mccMnc: String? = "208-10",
        pci: Int? = nil,
        ci: Int64? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        deleted: Bool = false
    ) throws -> RadioLogEntry {
        var fields: [String] = [
            "\"id\":\"\(id)\"",
            "\"dedupeKey\":\"\(dedupeKey)\"",
            "\"scope\":\"cap\"",
            "\"technology\":\"\(technology)\"",
            "\"observedAt\":\"2026-07-01T10:00:00.000Z\"",
            "\"updatedAt\":\"2026-07-01T10:00:00.000Z\""
        ]
        if let operatorName { fields.append("\"operator\":\"\(operatorName)\"") }
        if let mccMnc { fields.append("\"mccMnc\":\"\(mccMnc)\"") }
        if let enb { fields.append("\"enb\":\"\(enb)\"") }
        if let gnb { fields.append("\"gnb\":\"\(gnb)\"") }
        if let pci { fields.append("\"pci\":\(pci)") }
        if let ci { fields.append("\"ci\":\"\(ci)\"") }
        if let latitude { fields.append("\"latitude\":\(latitude)") }
        if let longitude { fields.append("\"longitude\":\(longitude)") }
        if deleted { fields.append("\"deletedAt\":\"2026-07-02T10:00:00.000Z\"") }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: Data(json.utf8))
    }

    private func makeSite(
        kind: RadioLogNodeKind,
        node: String,
        mccMnc: String? = "208-10",
        operatorName: String? = "SFR",
        ci: Int64? = 160_466_202,
        latitude: Double? = 45.5
    ) throws -> RadioLogSite {
        let entry = try entry(
            id: "s",
            dedupeKey: "cap|s",
            enb: kind == .enb ? node : nil,
            gnb: kind == .gnb ? node : nil,
            technology: kind == .gnb ? "NR" : "LTE",
            operatorName: operatorName,
            mccMnc: mccMnc,
            pci: 35,
            ci: ci,
            latitude: latitude,
            longitude: latitude == nil ? nil : 5.3
        )
        return try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
    }

    private func resolution(_ json: String) throws -> QuickIdentifyResolution {
        try JSONDecoder.signalQuest.decode(QuickIdentifyResolution.self, from: Data(json.utf8))
    }

    /// Capture le corps HTTP RÉELLEMENT émis par `IdentifyService`.
    ///
    /// On passe par le vrai service et un vrai `APIClient` : un test qui
    /// reconstruirait la charge de son côté validerait sa propre copie, pas le
    /// code livré — et laisserait passer un renommage de champ, c'est-à-dire
    /// exactement le défaut qu'on corrige ici.
    private func encodeIdentifyBody(_ request: IdentifyDirectRequest) async throws -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let captured = CapturedBody()
        MockURLProtocol.requestHandler = { urlRequest in
            // URLSession transforme `httpBody` en flux avant d'atteindre le
            // URLProtocol : c'est là qu'il faut aller le chercher.
            captured.data = urlRequest.httpBody ?? urlRequest.httpBodyStream.map(Self.readAll)
            let response = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true,"siteId":"S"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let service = IdentifyService(api: APIClient(config: .test, session: session))
        _ = try await service.identify(request)

        let body = try XCTUnwrap(captured.data, "Aucun corps HTTP capturé")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private final class CapturedBody: @unchecked Sendable {
        var data: Data?
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Doublures

private struct StubIdentifyService: IdentifyServicing {
    func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult { throw APIError.cancelled }
    func mine(includeRelated: Bool) async throws -> [MyIdentification] { [] }
    func withdraw(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> WithdrawResult { throw APIError.cancelled }
    func delete(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> DeleteResult { throw APIError.cancelled }
    func editSite(fromSiteId: String, toSiteId: String, enb: String?, gnb: String?, reason: String?) async throws -> EditSiteResult { throw APIError.cancelled }
    func editSectors(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> EditSectorsResult { throw APIError.cancelled }
}

private struct StubRadioLogsService: RadioLogsServicing {
    func cachedSnapshot() -> RadioLogSnapshot { RadioLogSnapshot() }
    func syncStream() -> AsyncStream<RadioLogSyncProgress> { AsyncStream { $0.finish() } }
    func cachedSiteStates() -> [String: RadioLogSiteState] { [:] }
    func scanStream(sites: [RadioLogSite]) -> AsyncStream<[String: RadioLogSiteState]> { AsyncStream { $0.finish() } }
    func hypothesis(for site: RadioLogSite) async -> RadioLogSiteHypothesis? { nil }
    func purge() async throws {}
    func clearLocalCache() {}
}

private struct StubAntennasService: AntennasServicing {
    func list(bbox: BoundingBox) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func details(id: String) async throws -> AntennaDetails { throw APIError.cancelled }
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails { throw APIError.cancelled }
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails { throw APIError.cancelled }
    func search(query: String) async throws -> [AntennaSite] { [] }
    func quickSearch(query: String) async throws -> [AntennaSite] { [] }
}
