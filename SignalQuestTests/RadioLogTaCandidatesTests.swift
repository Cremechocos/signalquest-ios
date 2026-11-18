import SwiftUI
import XCTest
@testable import SignalQuest

/// TA-VISION r1.2 : la route des candidats d'un nœud du journal, son décodage tolérant, ce que
/// l'écran en dit, et le repli local aux mêmes seuils (`contracts/radio-logs/ta-candidates-v1.json`).
@MainActor
final class RadioLogTaCandidatesTests: XCTestCase {
    private func contract() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/radio-logs/ta-candidates-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: String) throws -> RadioLogTaCandidates {
        try JSONDecoder.signalQuest.decode(RadioLogTaCandidates.self, from: Data(json.utf8))
    }

    // MARK: Clé

    func testSiteKeysMatchTheSharedVectors() throws {
        let keys = try XCTUnwrap(contract()["keys"] as? [[String: Any]])
        var checked = 0
        for vector in keys where (vector["valid"] as? Bool) == true {
            let key = RadioLogTaSiteKey.make(
                enb: vector["enb"] as? String ?? "",
                gnb: vector["gnb"] as? String ?? "",
                mccMnc: vector["mccMnc"] as? String ?? ""
            )
            XCTAssertEqual(key, vector["key"] as? String, vector["name"] as? String ?? "")
            checked += 1
        }
        XCTAssertEqual(checked, 3)
        XCTAssertNil(RadioLogTaSiteKey.make(enb: "", gnb: "", mccMnc: "20801"), "sans nœud")
        XCTAssertNil(RadioLogTaSiteKey.make(enb: "12a", gnb: "", mccMnc: "20801"), "lettres")
        XCTAssertNil(RadioLogTaSiteKey.make(enb: "123", gnb: "", mccMnc: ""), "sans PLMN servant")
    }

    func testASiteWithoutServingPlmnHasNoKey() {
        XCTAssertEqual(RadioLogTaSiteKey.make(for: site(mcc: "208", mnc: "01")), "ODEyNzc3fHwyMDgwMQ")
        XCTAssertNil(RadioLogTaSiteKey.make(for: site(mcc: nil, mnc: nil)))
    }

    // MARK: Décodage

    func testTheResponseDecodesTolerantlyAndKeepsTheServerOrder() throws {
        let response = try decode(Self.rankedBody)
        XCTAssertTrue(response.isRanked)
        XCTAssertEqual(response.assessment, .convergent)
        XCTAssertEqual(response.zone?.radiusMeters, 210)
        XCTAssertEqual(response.readingCounts, .init(kept: 3, discarded: 2, near: 1, total: 6))
        XCTAssertEqual(response.readings.map(\.status), [.kept, .kept, .kept, .discarded, .discarded, .near, nil])
        XCTAssertEqual(response.candidates.map(\.rank), [1, 2, 3, 4], "triés par rang")
        XCTAssertEqual(response.candidates.first?.kind, .validated)
        XCTAssertTrue(response.confirmsValidatedSite)

        let hidden = response.candidates[2]
        XCTAssertNil(hidden.matchedRings, "site masqué : jamais comparé aux anneaux")
        XCTAssertFalse(hidden.hasPosition)
        XCTAssertNil(RadioLogTaVisionText.matchLine(hidden, ranked: true), "jamais « compatible avec 0 de tes M passages »")

        let estimated = response.candidates[3]
        XCTAssertNil(estimated.siteId)
        XCTAssertFalse(estimated.confirmable, "site estimé sans clé : rien à confirmer")
        XCTAssertNil(estimated.kind, "genre inconnu ignoré, le candidat reste")
        XCTAssertNil(RadioLogTaVisionText.matchLine(estimated, ranked: true), "jamais « compatible avec 0 »")
    }

    func testAnUnknownRankingMeansAbstention() throws {
        let response = try decode(#"{"ranking":"partially_ranked","assessment":"later","candidates":[]}"#)
        XCTAssertFalse(response.isRanked)
        XCTAssertNil(response.assessment)
    }

    func testAValidKeyWithoutReadingIsNoPosition() throws {
        let response = try decode(#"""
        {"assessment":"no_position","readingCounts":{"kept":0,"discarded":0,"near":0,"total":0},
         "ranking":"abstained","rankingReason":"no_position","zone":null,"readings":[],"candidates":[]}
        """#)
        let summary = RadioLogTaVisionText.summary(response)
        XCTAssertEqual(summary.headline, String(localized: "Aucun relevé n’a de position : antennes proposées par identifiant et fréquence seulement."))
        XCTAssertTrue(summary.lines.isEmpty)
    }

    // MARK: Ce que l'écran dit

    func testTheSummaryCountsAndExplainsDiscardedReadings() throws {
        let summary = RadioLogTaVisionText.summary(try decode(Self.rankedBody))
        XCTAssertEqual(summary.tone, .good)
        XCTAssertEqual(summary.headline, String(localized: "Les anneaux confirment le site validé"))
        let (kept, total, discarded, near) = (3, 6, 2, 1)
        let detail = "\(String(localized: "TA figé")) (1), \(String(localized: "GPS imprécis")) (1)"
        XCTAssertEqual(summary.lines, [
            String(localized: "\(kept) anneaux retenus sur \(total) relevés"),
            String(localized: "\(discarded) écartés : \(detail)"),
            String(localized: "\(near) TA 0 : antenne à moins de 400 m, affichés sans compter"),
        ])
    }

    func testDivergentRingsAbstainWithAWarning() throws {
        let summary = RadioLogTaVisionText.summary(try decode(#"""
        {"assessment":"divergent","ranking":"abstained","rankingReason":"rings_divergent",
         "readingCounts":{"kept":3,"discarded":15,"near":0,"total":18},"readingsTruncated":true,"candidates":[]}
        """#))
        XCTAssertEqual(summary.tone, .warning)
        XCTAssertEqual(summary.headline, String(localized: "Les anneaux ne se croisent pas : pas de classement"))
        XCTAssertNotNil(summary.detail)
        XCTAssertEqual(summary.lines.last, String(localized: "Lecture limitée aux 5 000 relevés les plus récents."))
        let discarded = 15
        XCTAssertEqual(summary.lines[1], String(localized: "\(discarded) écartés"), "relevés servis incomplets : pas de détail")
    }

    func testTooFewRingsAbstain() throws {
        let summary = RadioLogTaVisionText.summary(try decode(#"{"assessment":"unusable","ranking":"abstained","rankingReason":"rings_few"}"#))
        XCTAssertEqual(summary.headline, String(localized: "Trop peu d’anneaux pour classer : repasse près du site pour en ajouter."))
    }

    func testCandidateReasonsAreTranslatedAndUnknownCodesIgnored() throws {
        let first = try XCTUnwrap(decode(Self.rankedBody).candidates.dropFirst().first)
        XCTAssertEqual(
            RadioLogTaVisionText.reasonsLine(first),
            String(localized: "Secteur tourné vers tes relevés") + " · " + String(localized: "Bande relevée présente sur le site")
        )
        let (matched, rings) = (2, 3)
        XCTAssertEqual(RadioLogTaVisionText.matchLine(first, ranked: true), String(localized: "Compatible avec \(matched) de tes \(rings) passages"))
        XCTAssertNil(RadioLogTaVisionText.matchLine(first, ranked: false), "sans classement, pas de compte")
        XCTAssertEqual(RadioLogTaVisionText.kindLabel(.official, market: "FR"), "ANFR")
        XCTAssertEqual(RadioLogTaVisionText.kindLabel(.official, market: "CA"), "ISED")
    }

    // MARK: Repli local aux seuils du serveur

    func testTheLocalFallbackUsesTheServerThresholds() throws {
        let cases = try XCTUnwrap(contract()["readingCases"] as? [[String: Any]])
        var checked = 0
        for vector in cases {
            let input = try XCTUnwrap(vector["input"] as? [String: Any])
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            // Fiabilité et TA figé se jugent ailleurs (TA-READ-1, points de couverture).
            guard input["reliable"] as? Bool == true, input["frozen"] as? Bool == false else { continue }
            let entry = try entry(
                timingAdvance: input["timingAdvance"] as? Int ?? 0,
                accuracy: input["accuracyMeters"] as? Double,
                age: input["locationAgeMs"] as? Int
            )
            let reading = RadioLogIdentifyPicker.localReading(from: entry)
            let discarded = expected["status"] as? String == "discarded"
            XCTAssertEqual(reading == nil, discarded, vector["name"] as? String ?? "")
            if let reading {
                XCTAssertEqual(reading.accuracyMeters, input["accuracyMeters"] as? Double)
            }
            checked += 1
        }
        XCTAssertEqual(checked, 10)
    }

    // MARK: Sélection

    func testRankedCandidatesReplaceTheLocalListAndPreselectTheFirstConfirmable() async throws {
        let response = try decode(Self.rankedBody)
        let picker = RadioLogIdentifyPicker(
            service: VisionRadioLogsService(result: .success(response)),
            identify: NoIdentifyService(),
            antennas: NoAntennasService()
        )
        await picker.load(for: site(mcc: "208", mnc: "01"))
        XCTAssertEqual(picker.taVision, .served(response))
        XCTAssertEqual(picker.candidates.map(\.siteId), ["site-validated", "0381522", "COMMUNITY-7", ""])
        XCTAssertEqual(picker.selectedId, "site-validated")
        XCTAssertFalse(try XCTUnwrap(picker.candidates.first).needsVerification)
        XCTAssertFalse(picker.candidates[2].isSelectable, "site masqué non confirmable")
        XCTAssertFalse(picker.candidates[3].isSelectable)
        XCTAssertEqual(picker.taRings.count, 3)
        XCTAssertEqual(picker.taDiscardedRings.count, 2)
        XCTAssertEqual(picker.taNearDiscs.count, 1)
        XCTAssertEqual(picker.taAssessment, .convergent)
        XCTAssertEqual(picker.taZone?.radiusMeters, 210)
    }

    func testAbstentionPreselectsNothing() async throws {
        let response = try decode(#"""
        {"assessment":"divergent","ranking":"abstained","rankingReason":"rings_divergent","candidates":[
          {"siteId":"0381522","confirmable":true,"kind":"official","rank":1,"plausible":false,"matchedRings":1,"totalRings":3,
           "latitude":45.25,"longitude":5.67,"nearestReadingMeters":260,"reasons":[]}]}
        """#)
        let picker = RadioLogIdentifyPicker(
            service: VisionRadioLogsService(result: .success(response)),
            identify: NoIdentifyService(),
            antennas: NoAntennasService()
        )
        await picker.load(for: site(mcc: "208", mnc: "01"))
        XCTAssertEqual(picker.candidates.count, 1)
        XCTAssertNil(picker.selectedId)
        XCTAssertNotNil(picker.candidates.first?.verificationCaution)
    }

    func testAnUnreachableServerFallsBackToTheLocalList() async throws {
        let picker = RadioLogIdentifyPicker(
            service: VisionRadioLogsService(result: .failure(URLError(.notConnectedToInternet))),
            identify: NoIdentifyService(),
            antennas: NoAntennasService()
        )
        await picker.load(for: site(mcc: "208", mnc: "01"))
        XCTAssertEqual(picker.taVision, .unavailable)
        XCTAssertTrue(picker.candidates.isEmpty)
        XCTAssertNil(picker.taZone)
    }

    func testPremiumRequiredIsNotUnranked() async throws {
        let picker = RadioLogIdentifyPicker(
            service: VisionRadioLogsService(result: .failure(RadioLogSyncError.premiumRequired("Premium"))),
            identify: NoIdentifyService(),
            antennas: NoAntennasService()
        )
        await picker.load(for: site(mcc: "208", mnc: "01"))
        XCTAssertEqual(picker.taVision, .premiumRequired("Premium"))
    }

    // MARK: Captures (relecture visuelle, hors suite)

    /// Bloc de résumé et liste classée, rendus pour relecture : clair, sombre, AX.
    /// `TEST_RUNNER_SQ_TAVISION_SHOTS=<dossier>` pour l'activer.
    func testCaptureRankedListForReview() async throws {
        guard let output = ProcessInfo.processInfo.environment["SQ_TAVISION_SHOTS"] else {
            throw XCTSkip("SQ_TAVISION_SHOTS absent")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let ranked = try decode(Self.rankedBody)
        let divergent = try decode(#"""
        {"assessment":"divergent","ranking":"abstained","rankingReason":"rings_divergent",
         "readingCounts":{"kept":3,"discarded":15,"near":0,"total":18},"candidates":[
          {"siteId":"0381522","confirmable":true,"kind":"official","rank":1,"plausible":false,"matchedRings":1,"totalRings":3,
           "label":"Les Avenières · route de Lyon","generations":["4G","5G"],
           "latitude":45.25,"longitude":5.67,"nearestReadingMeters":260,"reasons":["frequency_match"]}]}
        """#)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        let variants: [(String, ColorScheme, DynamicTypeSize, RadioLogTaCandidates)] = [
            ("classe-clair", .light, .large, ranked), ("classe-sombre", .dark, .large, ranked),
            ("classe-ax", .light, .accessibility2, ranked), ("diverge-clair", .light, .large, divergent),
        ]
        for (name, scheme, size, response) in variants {
            let picker = RadioLogIdentifyPicker(
                service: VisionRadioLogsService(result: .success(response)),
                identify: NoIdentifyService(),
                antennas: NoAntennasService()
            )
            await picker.load(for: site(mcc: "208", mnc: "01"))
            let view = ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    RadioLogTaVisionSummaryView(state: picker.taVision)
                    RadioLogCandidateCard(
                        candidates: picker.candidates, selectedId: picker.selectedId,
                        mapLabel: "Choisir une autre antenne sur la carte",
                        onSelect: { _ in }, onOpenMap: {}
                    )
                }
                .padding(16)
            }
            .background(SQColor.bg)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: view)
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = host
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Données

    private func site(mcc: String?, mnc: String?) -> RadioLogSite {
        RadioLogSite(
            id: "orange|208|01|eNB|812777", kind: .enb, node: "812777", operatorName: "Orange", rawOperatorName: "Orange F",
            operatorKey: "orange", marketCode: "FR", countryCode: "FR", isRoaming: false, mcc: mcc, mnc: mnc,
            cells: [],
            logCount: 6, firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_790_050_000), latitude: 45.252, longitude: 5.672, band: 3, earfcn: 1_501
        )
    }

    private func entry(timingAdvance: Int, accuracy: Double?, age: Int?) throws -> RadioLogEntry {
        var object: [String: Any] = [
            "id": "e1", "dedupeKey": "cap|e1", "scope": "cap", "technology": "4G", "enb": "812777",
            "timingAdvance": timingAdvance, "latitude": 45.25, "longitude": 5.67,
            "observedAt": "2026-11-11T10:00:00.000Z", "updatedAt": "2026-11-11T10:00:00.000Z",
        ]
        if let accuracy { object["locationAccuracyMeters"] = accuracy }
        if let age { object["locationAgeMs"] = age }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: data)
    }

    private static let rankedBody = #"""
    {"contractVersion":1,"market":"FR","observedPlmn":"20801","nodeKind":"enb","node":"812777",
     "readings":[
      {"id":"r1","source":"entry","latitude":45.25,"longitude":5.67,"timingAdvance":7,"radiusMeters":547,"toleranceMeters":89,"accuracyMeters":50,"observedAt":"2026-11-11T10:00:00.000Z","status":"kept","reason":null},
      {"id":"r2","source":"entry","latitude":45.26,"longitude":5.68,"timingAdvance":8,"radiusMeters":625,"toleranceMeters":289,"accuracyMeters":null,"observedAt":"2026-11-12T10:00:00.000Z","status":"kept","reason":null},
      {"id":"r3","source":"observation","latitude":45.24,"longitude":5.66,"timingAdvance":6,"radiusMeters":469,"toleranceMeters":59,"accuracyMeters":20,"observedAt":"2026-11-13T10:00:00.000Z","status":"kept","reason":null},
      {"id":"r4","source":"entry","latitude":45.27,"longitude":5.69,"timingAdvance":1,"radiusMeters":78,"toleranceMeters":69,"accuracyMeters":30,"observedAt":"2026-11-14T10:00:00.000Z","status":"discarded","reason":"ta_frozen"},
      {"id":"r5","source":"entry","latitude":45.28,"longitude":5.70,"timingAdvance":9,"radiusMeters":703,"toleranceMeters":340,"accuracyMeters":301,"observedAt":"2026-11-15T10:00:00.000Z","status":"discarded","reason":"gps_imprecise"},
      {"id":"r6","source":"entry","latitude":45.251,"longitude":5.671,"timingAdvance":0,"radiusMeters":400,"toleranceMeters":30,"accuracyMeters":30,"observedAt":"2026-11-16T10:00:00.000Z","status":"near","reason":"ta_zero"},
      {"id":"r7","source":"entry","latitude":45.251,"longitude":5.671,"timingAdvance":3,"radiusMeters":234,"toleranceMeters":30,"accuracyMeters":30,"observedAt":"2026-11-16T10:00:00.000Z","status":"later","reason":null}
     ],
     "readingCounts":{"kept":3,"discarded":2,"near":1,"total":6},"readingsTruncated":false,
     "readingsSyncedThrough":"2026-11-16T10:00:00.000Z","assessment":"convergent","residualMeters":120,
     "zone":{"latitude":45.252,"longitude":5.671,"radiusMeters":210},"ranking":"ranked","rankingReason":null,
     "validatedSite":{"siteId":"site-validated","latitude":45.252,"longitude":5.672},
     "candidates":[
      {"siteId":"0381522","supId":"0381522","candidateKey":null,"confirmable":true,"kind":"official","operatorKey":"ORANGE",
       "label":"Le Fontanil · rue de la Gare","generations":["4G","5G"],"bands":["B3","n78"],"latitude":45.255,"longitude":5.668,
       "rank":2,"plausible":true,"confidence":"medium","score":62,"matchedRings":2,"totalRings":3,
       "distanceToZoneCenterMeters":290,"nearestReadingMeters":420,"azimuth":"consistent","frequency":"match",
       "reasons":["rings_matched","azimuth_consistent","frequency_match","future_reason"]},
      {"siteId":"site-validated","supId":null,"candidateKey":null,"confirmable":true,"kind":"validated","operatorKey":"ORANGE",
       "label":"Le Fontanil · mairie","generations":["4G"],"bands":["B3"],"latitude":45.252,"longitude":5.672,
       "rank":1,"plausible":true,"confidence":"high","score":90,"matchedRings":3,"totalRings":3,
       "distanceToZoneCenterMeters":80,"nearestReadingMeters":150,"azimuth":"unknown","frequency":"match",
       "reasons":["validated_same_plmn","rings_matched"]},
      {"siteId":"COMMUNITY-7","confirmable":false,"kind":"community","rank":3,"plausible":false,"matchedRings":null,"totalRings":3,
       "latitude":null,"longitude":null,"distanceToZoneCenterMeters":null,"nearestReadingMeters":null,"reasons":[]},
      {"siteId":null,"candidateKey":null,"confirmable":false,"kind":"guessed","rank":4,"plausible":false,"matchedRings":0,"totalRings":3,
       "latitude":45.3,"longitude":5.7,"reasons":[]}
     ]}
    """#
}

// MARK: - Doublures

private struct VisionRadioLogsService: RadioLogsServicing {
    let result: Result<RadioLogTaCandidates, Error>
    func cachedSnapshot() -> RadioLogSnapshot { RadioLogSnapshot() }
    func syncStream() -> AsyncStream<RadioLogSyncProgress> { AsyncStream { $0.finish() } }
    func cachedSiteStates() -> [String: RadioLogSiteState] { [:] }
    func cachedSiteProposals() -> [String: RadioLogSiteHypothesis] { [:] }
    func scanStream(sites: [RadioLogSite]) -> AsyncStream<RadioLogScanUpdate> { AsyncStream { $0.finish() } }
    func hypothesis(for site: RadioLogSite) async -> RadioLogSiteHypothesis? { nil }
    func taCandidates(for site: RadioLogSite) async throws -> RadioLogTaCandidates { try result.get() }
    func markIdentified(siteKey: String, siteId: String) {}
    func markWithdrawn(siteKey: String) {}
    func purge() async throws {}
    func clearLocalCache() {}
}

private struct NoIdentifyService: IdentifyServicing {
    func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult { throw APIError.cancelled }
    func mine(includeRelated: Bool) async throws -> [MyIdentification] { [] }
    func withdraw(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> WithdrawResult { throw APIError.cancelled }
    func delete(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> DeleteResult { throw APIError.cancelled }
    func editSite(fromSiteId: String, toSiteId: String, enb: String?, gnb: String?, reason: String?) async throws -> EditSiteResult { throw APIError.cancelled }
    func editSectors(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> EditSectorsResult { throw APIError.cancelled }
}

private struct NoAntennasService: AntennasServicing {
    func list(bbox: BoundingBox) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func details(id: String) async throws -> AntennaDetails { throw APIError.cancelled }
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails { throw APIError.cancelled }
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails { throw APIError.cancelled }
    func search(query: String) async throws -> [AntennaSite] { [] }
    func quickSearch(query: String, market: String, department: String?) async throws -> [AntennaSite] { [] }
    func listCommunitySites(bbox: BoundingBox, market: String, operatorName: String?) async throws -> [AntennaSite] { [] }
}
