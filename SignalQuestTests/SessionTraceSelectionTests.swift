import XCTest
import CoreLocation
@testable import SignalQuest

/// Carte plein écran d'un trajet : regroupement des antennes par site, nœuds sans
/// site, anneaux TA des points d'un même eNB et tracés de la sélection
/// (choix d'Alexandre du 11/11).
final class SessionTraceSelectionTests: XCTestCase {

    /// Trajet Android : trois points sur l'eNB 20500 (TA 6, 6 et 9), un point en
    /// 5G SA sur le gNB 900 du même site, un point sur l'eNB 777 que le serveur
    /// n'a pas résolu.
    private func detail() throws -> CoverageSessionDetail {
        let json = """
        {"session":{"id":"s1","name":"Trajet","source":"android","points":[
          {"id":"a","latitude":45.1700,"longitude":5.7000,"signalStrength":-95,"technology":"4G","enb":"20500","pci":"12",
           "timingAdvance":6,"rsrq":-11.5,"snr":7,"cellMeasurements":[{"isPrimary":true,"band":3,"cellType":"LTE"}]},
          {"id":"b","latitude":45.1702,"longitude":5.7001,"technology":"4G","enb":"20500","timingAdvance":6},
          {"id":"c","latitude":45.1800,"longitude":5.7100,"technology":"4G","enb":"20500","timingAdvance":9},
          {"id":"d","latitude":45.1750,"longitude":5.7050,"technology":"5G","gnb":"900","timingAdvance":4,
           "cellMeasurements":[{"isPrimary":true,"band":78,"cellType":"NR"}]},
          {"id":"e","latitude":45.1900,"longitude":5.7200,"technology":"4G","enb":"777"}
        ]},
        "servingAntennas":[
          {"id":"20500","ok":true,"result":{"identificationStatus":"uncertain","confidenceScore":72,
            "confidenceReason":["operator_match","frequency_match","some_future_code"],
            "estimatedSite":{"latitude":45.1760,"longitude":5.7040,"uncertaintyMeters":150,"observationCount":4},
            "hypothesis":{"siteId":"0381234","operator":"ORANGE","confidence":"MEDIUM","confidenceScore":72,
              "distanceMeters":600,"evidence":["operator_match","frequency_match","some_future_code"],"sectorAzimuthDeg":120},
            "antenna":{"latitude":45.1750,"longitude":5.7060,"operator":"ORANGE","sup_id":"0381234","enb":"20500"}}},
          {"id":"900","ok":true,"result":{"identificationStatus":"confirmed",
            "antenna":{"latitude":45.1750,"longitude":5.7060,"operator":"ORANGE","sup_id":"0381234","gnb":"900"}}},
          {"id":"777","ok":false,"result":{"error":"not found","code":"NOT_FOUND"}}
        ]}
        """
        return try JSONDecoder().decode(CoverageSessionDetail.self, from: Data(json.utf8))
    }

    func testPointDecodesRadioFieldsAndTimingAdvanceDistance() throws {
        let points = try detail().points
        let a = try XCTUnwrap(points.first { $0.id == "a" })
        XCTAssertEqual(a.rsrq, -11.5)
        XCTAssertEqual(a.snr, 7)
        XCTAssertEqual(a.primaryBand, 3)
        XCTAssertFalse(a.primaryBandIsNR)
        XCTAssertEqual(a.nodeKey, "20500")
        XCTAssertEqual(a.taDistanceMeters, 6 * 78)
        // Un point 5G SA (gNB seul) n'a pas d'anneau : le TA lu n'est pas celui d'une cellule LTE.
        let d = try XCTUnwrap(points.first { $0.id == "d" })
        XCTAssertEqual(d.nodeKey, "900")
        XCTAssertTrue(d.primaryBandIsNR)
        XCTAssertNil(d.taDistanceMeters)
    }

    func testAntennasOfOneSiteShareOnePinAndUnresolvedNodesAreCounted() throws {
        let detail = try detail()
        let groups = ServingSiteGroup.groups(detail.servingAntennas)
        XCTAssertEqual(groups.count, 1, "la 4G et la 5G du même support ne font qu'une pastille")
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.nodeKeys, ["20500", "900"])
        XCTAssertEqual(group.primary.status, .identified, "l'antenne identifiée passe devant l'hypothèse")
        XCTAssertEqual(ServingSiteGroup.unresolvedNodeKeys(points: detail.points, antennas: detail.servingAntennas), ["777"])

        let hypothesis = try XCTUnwrap(group.antennas.first { $0.lookupKey == "20500" })
        XCTAssertEqual(hypothesis.confidenceScore, 72)
        XCTAssertEqual(hypothesis.sectorAzimuthDeg, 120)
        XCTAssertEqual(hypothesis.estimatedSite?.uncertaintyMeters, 150)
        XCTAssertEqual(hypothesis.evidenceLabels.count, 2, "un code inconnu n'est pas affiché")
        XCTAssertFalse(hypothesis.evidenceLabels.contains { $0.contains("_") })
    }

    func testTimingAdvanceRingsCoverEveryPointOfTheNodeWithoutDuplicates() throws {
        let points = try detail().points
        // a et b : même TA dans la même case de 100 m, un seul anneau ; c : un autre.
        let rings = SessionTraceHighlight.taRings(nodeKeys: ["20500"], in: points, emphasizing: nil)
        XCTAssertEqual(rings.map(\.radiusMeters).sorted(), [6 * 78, 9 * 78])
        // Le point touché garde toujours son anneau, en fort, même s'il double un autre.
        let emphasized = SessionTraceHighlight.taRings(nodeKeys: ["20500"], in: points, emphasizing: "b")
        XCTAssertEqual(emphasized.filter(\.emphasized).count, 1)
        XCTAssertEqual(emphasized.count, 3)
    }

    func testSelectionDrawsLinksConeAndEstimate() throws {
        let detail = try detail()
        let groups = ServingSiteGroup.groups(detail.servingAntennas)
        let a = try XCTUnwrap(detail.points.first { $0.id == "a" })
        let point = SessionTraceHighlight.forPoint(a, in: detail.points, groups: groups)
        XCTAssertEqual(point.links.count, 1)
        XCTAssertEqual(point.cones.count, 1)
        XCTAssertEqual(point.estimates.count, 1)

        let site = SessionTraceHighlight.forGroup(try XCTUnwrap(groups.first), in: detail.points)
        // a, b, c et d sont servis par ce site ; a et b, à 20 m, partagent un trait.
        XCTAssertEqual(site.links.count, 3)
        XCTAssertEqual(site.rings.count, 2)

        // Un point dont le nœud n'a pas de site : ni trait, ni secteur.
        let e = try XCTUnwrap(detail.points.first { $0.id == "e" })
        let orphan = SessionTraceHighlight.forPoint(e, in: detail.points, groups: groups)
        XCTAssertTrue(orphan.links.isEmpty)
        XCTAssertTrue(orphan.cones.isEmpty)
    }

    func testRingsAreCappedAndEvenlySpread() {
        let spread = SessionTraceHighlight.evenlySpaced(Array(0..<200), limit: 60)
        XCTAssertEqual(spread.count, 60)
        XCTAssertEqual(spread.first, 0)
        XCTAssertGreaterThan(spread.last ?? 0, 190)
        XCTAssertEqual(SessionTraceHighlight.evenlySpaced([1, 2], limit: 60), [1, 2])
    }

    /// Sites de l'opérateur autour des anneaux : un site sur le croisement des
    /// anneaux ressort, un site à côté reste estompé.
    func testCandidateSiteFitsTheTimingAdvanceRings() {
        let site = CLLocationCoordinate2D(latitude: 45.18, longitude: 5.72)
        let rings = [0.0, 120, 240].map { bearing -> SessionTraceHighlight.Ring in
            let center = SessionTraceHighlight.destination(from: site, bearingDeg: bearing, meters: 7 * 78)
            return .init(center: center, radiusMeters: 7 * 78, emphasized: false)
        }
        let onIt = SessionTraceHighlight.ringFit(of: site, rings: rings)
        XCTAssertEqual(onIt.matching, 3)
        XCTAssertTrue(SessionTraceHighlight.isLikely(onIt))
        let elsewhere = SessionTraceHighlight.ringFit(
            of: SessionTraceHighlight.destination(from: site, bearingDeg: 45, meters: 1_500), rings: rings)
        XCTAssertFalse(SessionTraceHighlight.isLikely(elsewhere))
        // Un seul anneau ne suffit jamais à désigner un site.
        XCTAssertFalse(SessionTraceHighlight.isLikely((1, 1)))

        let box = try? XCTUnwrap(SessionTraceHighlight.searchBox(rings: rings, extra: []))
        XCTAssertNotNil(box)
        if let box {
            XCTAssertTrue((box.south...box.north).contains(site.latitude))
            XCTAssertTrue((box.west...box.east).contains(site.longitude))
            XCTAssertLessThanOrEqual(box.north - box.south, 0.22 + 1e-9)
        }
    }

    func testCandidateIdentificationUsesThePointNode() throws {
        let point = try XCTUnwrap(detail().points.first { $0.id == "a" })
        let site = AntennaSite(id: "0381999", siteId: "0381999", latitude: 45.18, longitude: 5.72,
                               operators: ["ORANGE"], technologies: [], bands: [], azimuths: [],
                               sharingType: nil, crozonLeader: nil, address: "Rue du Test", height: nil, owner: nil)
        let antenna = ServingAntenna(candidate: site, node: point, operatorName: "ORANGE")
        XCTAssertEqual(antenna.siteId, "0381999")
        XCTAssertEqual(antenna.enb, "20500")
        XCTAssertNil(antenna.gnb)
        XCTAssertEqual(antenna.pci, "12")
        XCTAssertTrue(antenna.isUnconfirmed)
        XCTAssertEqual(SessionDetailViewModel.sample(for: antenna, in: [point])?.id, "a")
    }

    /// Site mutualisé : `matchedOperators` [BOUYGUES, SFR] et `operators`
    /// ["SFR / BOUYGUES"] ne donnent qu'un nom par opérateur (retour du 11/11).
    func testSharedSiteOperatorsAreListedOnce() throws {
        let json = """
        {"id":"608665","ok":true,"result":{"identificationStatus":"uncertain","matchedOperators":["BOUYGUES","SFR"],
          "antenna":{"latitude":45.6,"longitude":5.3,"operator":"SFR / BOUYGUES","operators":["SFR / BOUYGUES"],"sup_id":"1316142"}}}
        """
        let wrapper = try JSONDecoder().decode(ServingAntennaWrapper.self, from: Data(json.utf8))
        let antenna = try XCTUnwrap(ServingAntenna(wrapper: wrapper))
        XCTAssertEqual(antenna.operatorNames, ["BOUYGUES", "SFR"])
        XCTAssertEqual(antenna.operatorName, "SFR")
        XCTAssertEqual(antenna.operatorDisplayName, "Bouygues Telecom + SFR")
        XCTAssertEqual(ServingAntenna.distinctOperatorKeys(["Free", "FREE", " Orange+SFR "]), ["Free", "Orange", "SFR"])
    }

    /// LOOKUP-CONFLICT r1 : le conflit est lu à part du statut ; un `kind` inconnu fait ignorer
    /// le bloc sans toucher au statut ; un candidat sans position reste listé, pas dessiné.
    @MainActor
    func testIdentificationConflictIsReadAndItsSitesAreDrawn() throws {
        func antenna(_ conflict: String, suggests: Bool = false) throws -> ServingAntenna {
            let json = """
            {"id":"608665","ok":true,"result":{"identificationStatus":"confirmed","confidenceScore":100,
              "cellValidationSuggested":\(suggests),"identificationConflict":\(conflict),
              "antenna":{"latitude":45.60,"longitude":5.30,"operator":"BOUYGUES","sup_id":"1316142","enb":"608665"}}}
            """
            let wrapper = try JSONDecoder().decode(ServingAntennaWrapper.self, from: Data(json.utf8))
            return try XCTUnwrap(ServingAntenna(wrapper: wrapper))
        }
        let served = try antenna("""
        {"kind":"multi_site","candidates":[
          {"siteId":"1452969","market":"FR","operator":"BOUYGUES","nodeType":"enb","nodeId":"608665","tech":"4G",
           "source":"manual","validatedAt":"2026-08-23T14:05:00.000Z","validationCount":2,"pci":[112],
           "latitude":45.64,"longitude":5.24,"distanceMeters":8760},
          {"siteId":"1316142","operator":"BOUYGUES","validationCount":1,"pci":[]},
          {"siteId":"999","operator":"BOUYGUES","validationCount":1},
          {"operator":"BOUYGUES"}]}
        """, suggests: true)
        XCTAssertEqual(served.status, .identified, "un conflit ne déclasse jamais le statut")
        XCTAssertTrue(served.cellValidationSuggested)
        let conflict = try XCTUnwrap(served.identificationConflict)
        XCTAssertEqual(conflict.kind, .multiSite)
        XCTAssertEqual(conflict.candidates.map(\.siteId), ["1452969", "1316142", "999"], "sans siteId : écarté")
        XCTAssertEqual(conflict.candidates[0].pci, [112])
        XCTAssertEqual(conflict.candidates[0].validatedAt, ISO8601DateFormatter().date(from: "2026-08-23T14:05:00Z"))
        XCTAssertNil(conflict.candidates[2].coordinate)
        XCTAssertTrue(conflict.isActionable)
        XCTAssertEqual(SessionConflictSites.line(conflict)?.contains("1316142, 999"), true,
                       "les supports sans position sont nommés")

        let unknown = try antenna(#"{"kind":"same_pci","candidates":[{"siteId":"1"}]}"#)
        XCTAssertNil(unknown.identificationConflict)
        XCTAssertEqual(unknown.status, .identified)
        XCTAssertFalse(try antenna(#"{"kind":"multi_operator","candidates":[{"siteId":"1"}]}"#)
            .identificationConflict!.isActionable, "autre PLMN : informatif seulement")

        // Sur la carte : seul le candidat placé, hors support desservant ; fusion avec la recherche.
        let groups = ServingSiteGroup.groups([served])
        let sites = SessionConflictSites.sites([served], rings: [], groups: groups)
        XCTAssertEqual(sites.map(\.site.writeSiteId), ["1452969"])
        XCTAssertEqual(sites.first?.conflict?.validationCount, 2)
        let around = AntennaSite(id: "1452969", siteId: "1452969", latitude: 45.64, longitude: 5.24,
                                 operators: ["BOUYGUES"], technologies: [], bands: [], azimuths: [],
                                 sharingType: nil, crozonLeader: nil, address: "Lieu-dit Les Combes", height: nil, owner: nil)
        let other = AntennaSite(id: "77", siteId: "77", latitude: 45.7, longitude: 5.2,
                                operators: ["BOUYGUES"], technologies: [], bands: [], azimuths: [],
                                sharingType: nil, crozonLeader: nil, address: nil, height: nil, owner: nil)
        let merged = SessionConflictSites.merging(sites, into: [
            SessionCandidateSite(site: other, operatorName: "BOUYGUES", fitMatching: 0, fitTotal: 0),
            SessionCandidateSite(site: around, operatorName: "BOUYGUES", fitMatching: 0, fitTotal: 0),
        ])
        XCTAssertEqual(merged.map(\.site.writeSiteId), ["77", "1452969"], "pas de doublon")
        XCTAssertEqual(merged[1].site.address, "Lieu-dit Les Combes", "la fiche trouvée autour est gardée")
        XCTAssertNotNil(merged[1].conflict)
    }

    func testConeOpensAroundTheAzimuth() {
        let origin = CLLocationCoordinate2D(latitude: 45, longitude: 5)
        let cone = SessionTraceHighlight.cone(at: origin, azimuthDeg: 90, radiusMeters: 1_000)
        XCTAssertEqual(cone.first?.latitude, origin.latitude)
        XCTAssertEqual(cone.last?.latitude, origin.latitude)
        // Vers l'est : tout l'arc est à l'est de l'antenne, à 1 km.
        let arc = cone.dropFirst().dropLast()
        XCTAssertTrue(arc.allSatisfy { $0.longitude > origin.longitude })
        let middle = arc[arc.startIndex + arc.count / 2]
        let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: middle.latitude, longitude: middle.longitude))
        XCTAssertEqual(distance, 1_000, accuracy: 5)
    }
}
