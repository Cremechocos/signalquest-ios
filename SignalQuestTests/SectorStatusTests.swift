import SwiftUI
import XCTest
@testable import SignalQuest

/// SECTOR-ORIGIN r1 à r1.3.2 : statut du secteur, geste « Je confirme » et comptes de la fiche.
@MainActor
final class SectorStatusTests: XCTestCase {
    private func line(_ json: String) throws -> MyIdentification {
        try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data(json.utf8))
    }

    private func pciLine(status: String? = "operator_rule", myConfirmation: String?? = nil, sectors: [Int] = [2],
                         id: String = "p1", type: String = "pci", cellId: String? = nil) throws -> MyIdentification {
        var fields = [
            "\"id\":\"\(id)\"", "\"siteId\":\"0381522\"", "\"type\":\"\(type)\"", "\"enb\":\"610423\"",
            "\"pci\":215", "\"tech\":\"4G\"", "\"operator\":\"ORANGE\"", "\"marketCode\":\"FR\"",
            "\"sectors\":[\(sectors.map(String.init).joined(separator: ","))]",
        ]
        if let status { fields.append("\"sectorStatus\":\"\(status)\"") }
        if let cellId { fields.append("\"cellId\":\"\(cellId)\"") }
        switch myConfirmation {
        case .none: break
        case .some(.none): fields.append("\"myConfirmation\":null")
        case let .some(.some(value)): fields.append("\"myConfirmation\":\"\(value)\"")
        }
        return try line("{\(fields.joined(separator: ","))}")
    }

    // MARK: - Décodage

    func testEveryServedStatusIsReadAndAnUnknownOneIsUnknownOrigin() {
        let served: [String: SectorStatus] = [
            "verified_on_site": .verifiedOnSite, "confirmed": .confirmed, "manual_edit": .manualEdit,
            "operator_rule": .operatorRule, "azimuth": .azimuth, "client": .client,
            "legacy_matches_rule": .legacyMatchesRule, "legacy_differs_rule": .legacyDiffersRule,
            "legacy_unknown": .legacyUnknown,
        ]
        for (raw, status) in served { XCTAssertEqual(SectorStatus(raw: raw), status, raw) }
        XCTAssertEqual(SectorStatus(raw: "gps_fix"), .unrecognized)
        XCTAssertEqual(SectorStatusText.label(.unrecognized), SectorStatusText.label(.legacyUnknown))
        XCTAssertNil(SectorStatus(raw: nil), "secteur vide : pas de statut")
        XCTAssertNil(SectorStatus(raw: " "))
    }

    func testMyConfirmationDecidesWhoConfirmedAndAnOlderServerFallsBackOnTheStatus() throws {
        // r1.3 : `confirmed` peut venir d'un votant ; `myConfirmation: null` dit « pas moi ».
        let byVoter = try pciLine(status: "confirmed", myConfirmation: .some(nil))
        XCTAssertEqual(byVoter.sectorStatus, .confirmed)
        XCTAssertNil(byVoter.ownConfirmation)
        XCTAssertEqual(SectorConfirmTarget.line(byVoter)?.own, nil)

        let mine = try pciLine(status: "verified_on_site", myConfirmation: "confirmed")
        XCTAssertEqual(mine.ownConfirmation, .confirmed)

        // Avant r1.3.2, seul l'auteur confirmait sa ligne.
        let older = try pciLine(status: "confirmed")
        XCTAssertFalse(older.servesMyConfirmation)
        XCTAssertEqual(older.ownConfirmation, .confirmed)
        let olderVerified = try pciLine(status: "verified_on_site")
        XCTAssertFalse(try XCTUnwrap(SectorConfirmTarget.line(olderVerified)).canConfirm,
                       "sans myConfirmation, une ligne vérifiée de l'auteur reste grisée")
        XCTAssertNil(try pciLine(status: "operator_rule").ownConfirmation)
    }

    func testConfirmResponseIsReadTolerantly() throws {
        let decode = { (json: String) in try JSONDecoder.signalQuest.decode(ConfirmSectorResult.self, from: Data(json.utf8)) }
        let proven = try decode(#"{"confirmed":2,"skipped":1,"scope":"pci","sectorStatus":"verified_on_site","proof":"radio_log","as":"voter"}"#)
        XCTAssertEqual(proven, ConfirmSectorResult(confirmed: 2, skipped: 1, scope: "pci", sectorStatus: .verifiedOnSite, proof: .radioLog))
        let unknownProof = try decode(#"{"confirmed":1,"scope":"cell","sectorStatus":"confirmed","proof":"gps"}"#)
        XCTAssertNil(unknownProof.proof, "preuve inconnue : sans preuve")
        XCTAssertEqual(unknownProof.skipped, 0)
    }

    // MARK: - Ciblage

    func testAPciRowConfirmsInPciScopeWithTheSectorsShown() throws {
        let pci = try pciLine(myConfirmation: .some(nil))
        let cell = try pciLine(status: "legacy_differs_rule", id: "c1", type: "cellid", cellId: "156266497")
        let row = try XCTUnwrap(SectorRow.rows([pci, cell]).first)
        let target = try XCTUnwrap(SectorConfirmTarget.row(row))
        XCTAssertEqual(target.id, "pci:215")
        XCTAssertEqual(target.pci, "215")
        XCTAssertEqual(target.enb, "610423")
        XCTAssertNil(target.cellId, "portée PCI : ni cellule ni CI")
        XCTAssertEqual(target.sectors, [2])
        XCTAssertEqual(target.operatorName, "ORANGE")
        XCTAssertEqual(target.status, .operatorRule, "le statut de la ligne PCI, celle qu'on voit")
        XCTAssertEqual(SectorStatusText.buttonTitle(own: target.own), String(localized: "Je confirme"))
    }

    func testNothingToConfirmWithoutStatusOrWhenThePciLinesDisagree() throws {
        XCTAssertNil(SectorConfirmTarget.row(try XCTUnwrap(SectorRow.rows([try pciLine(status: nil)]).first)))
        let misaligned = SectorRow.rows([try pciLine(), try pciLine(sectors: [3], id: "c1", type: "cellid", cellId: "1")])
        XCTAssertTrue(try XCTUnwrap(misaligned.first).isMisaligned)
        XCTAssertNil(SectorConfirmTarget.row(try XCTUnwrap(misaligned.first)))
    }

    func testACellLineConfirmsInCellScope() throws {
        let cell = try pciLine(status: "confirmed", myConfirmation: "confirmed", id: "c1", type: "cellid", cellId: "156266497")
        let target = try XCTUnwrap(SectorConfirmTarget.line(cell))
        XCTAssertEqual(target.cellId, "156266497")
        XCTAssertEqual(target.pci, "215")
        XCTAssertEqual(SectorStatusText.buttonTitle(own: target.own), String(localized: "Confirmer à nouveau"))
    }

    // MARK: - Comptes de la fiche

    func testCountsComeFromTheSameValueSectorAndNodeAndAreNeverSummed() {
        let identifiers = AntennaCellIdentifiers(pci: [
            AntennaPciEntry(value: "215", sector: 2, tech: "4G", band: 20, frequency: nil, enb: "610423",
                            sectorConfirmations: 3, sectorVerifiedConfirmations: 2),
            AntennaPciEntry(value: "215", sector: 2, tech: "4G", band: 3, frequency: nil, enb: "610423",
                            sectorConfirmations: 2, sectorVerifiedConfirmations: 1),
            AntennaPciEntry(value: "215", sector: 3, tech: "4G", band: 7, frequency: nil, enb: "610423",
                            sectorConfirmations: 9, sectorVerifiedConfirmations: 9),
            AntennaPciEntry(value: "215", sector: 2, tech: "4G", band: 1, frequency: nil, enb: "999999",
                            sectorConfirmations: 8, sectorVerifiedConfirmations: 0),
        ])
        let counts = SectorConfirmCounts.lookup(in: identifiers, pci: 215, cellId: nil, enb: "610423", gnb: nil, sectors: [2])
        XCTAssertEqual(counts, SectorConfirmCounts(members: 3, verified: 2))
        XCTAssertEqual(SectorStatusText.counts(counts!), String(localized: "Confirmé par \(3) membres, dont \(2) sur place"))
        XCTAssertNil(SectorConfirmCounts.lookup(in: identifiers, pci: 215, cellId: nil, enb: "610423", gnb: nil, sectors: [1]))
        XCTAssertNil(SectorConfirmCounts.lookup(in: identifiers, pci: 215, cellId: nil, enb: "610423", gnb: nil, sectors: [1, 2]),
                     "plusieurs secteurs : pas de compte unique")
    }

    func testMineLinesCarryTheirCounts() throws {
        let served = try line(#"{"id":"p1","siteId":"s","type":"pci","pci":215,"sectors":[2],"sectorStatus":"confirmed","sectorConfirmations":3,"sectorVerifiedConfirmations":5}"#)
        XCTAssertEqual(served.sectorConfirmCounts, SectorConfirmCounts(members: 3, verified: 3), "jamais plus de membres sur place que de membres")
        XCTAssertNil(try pciLine().sectorConfirmCounts, "serveur d'avant #1401 : la fiche sert de repli")
    }

    func testFicheEntriesDecodeTheirCounts() throws {
        let json = #"{"value":"215","sector":2,"tech":"4G","band":20,"enb":"610423","sectorStatus":"verified_on_site","sectorConfirmations":3,"sectorVerifiedConfirmations":2}"#
        let entry = try JSONDecoder.signalQuest.decode(AntennaPciEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.enb, "610423")
        XCTAssertEqual(entry.sectorConfirmations, 3)
        XCTAssertEqual(entry.sectorVerifiedConfirmations, 2)
        let bare = try JSONDecoder.signalQuest.decode(AntennaPciEntry.self, from: Data(#"{"value":"215"}"#.utf8))
        XCTAssertNil(bare.sectorConfirmations)
    }

    // MARK: - Geste

    private func target(status: SectorStatus = .operatorRule, own: SectorStatus? = nil) throws -> SectorConfirmTarget {
        var target = try XCTUnwrap(SectorConfirmTarget.row(try XCTUnwrap(SectorRow.rows([try pciLine()]).first)))
        if status != target.status || own != nil {
            target = SectorConfirmTarget(id: target.id, label: target.label, siteId: target.siteId, enb: target.enb,
                                         gnb: target.gnb, pci: target.pci, cellId: nil, ci: nil, tech: target.tech,
                                         operatorName: target.operatorName, marketCode: target.marketCode,
                                         sectors: target.sectors, status: status, own: own)
        }
        return target
    }

    private func waitUntilIdle(_ model: SectorConfirmModel) async {
        for _ in 0..<200 where model.phase != .idle { await Task.yield() }
    }

    func testNothingIsSentDuringTheEightSecondsAndCancelCostsNoCall() async throws {
        let service = ConfirmSpy(outcome: .success(ConfirmSectorResult(confirmed: 1, sectorStatus: .confirmed, proof: nil)))
        let gate = SleepGate()
        let model = SectorConfirmModel(service: service, sleep: { _ in try await gate.wait() })
        let target = try target()
        model.start(target) { _ in nil }
        XCTAssertEqual(model.phase, .counting(target, secondsLeft: SectorConfirmModel.delay))
        XCTAssertEqual(model.secondsLeft(for: target.id), 8)
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
        await gate.releaseAll()
        for _ in 0..<50 { await Task.yield() }
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty, "Annuler ne coûte aucun appel")
    }

    func testAfterTheDelayTheShownSectorsAreSentAndAMissingProofIsExplained() async throws {
        let service = ConfirmSpy(outcome: .success(ConfirmSectorResult(confirmed: 1, skipped: 2, scope: "pci",
                                                                       sectorStatus: .confirmed, proof: nil)))
        let model = SectorConfirmModel(service: service, sleep: { _ in })
        let target = try target()
        var reloaded = 0
        model.start(target) { _ in reloaded += 1; return [2] }
        await waitUntilIdle(model)
        let calls = await service.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.sectors, [2])
        XCTAssertEqual(calls.first?.pci, "215")
        XCTAssertNil(calls.first?.cellId)
        XCTAssertEqual(reloaded, 1, "les lignes se relisent pour montrer les statuts servis")
        XCTAssertEqual(model.notes[target.id]?.lines, [SectorStatusText.noProof, SectorStatusText.skipped(2)])
        XCTAssertEqual(model.notes[target.id]?.status, .confirmed)
        XCTAssertNil(model.message)
    }

    func testAProofIsNamed() async throws {
        let service = ConfirmSpy(outcome: .success(ConfirmSectorResult(confirmed: 1, sectorStatus: .verifiedOnSite, proof: .coverage)))
        let model = SectorConfirmModel(service: service, sleep: { _ in })
        let target = try target()
        model.start(target) { _ in nil }
        await waitUntilIdle(model)
        XCTAssertEqual(model.notes[target.id]?.lines, [String(localized: "Preuve : ta couverture")])
    }

    func testAChangedSectorConfirmsNothingAndSaysTheNewOne() async throws {
        let service = ConfirmSpy(outcome: .failure(APIError.http(status: 409, code: "SECTOR_CHANGED", message: "", requestId: nil, retryAfter: nil)))
        let model = SectorConfirmModel(service: service, sleep: { _ in })
        let target = try target()
        model.start(target) { _ in [3] }
        await waitUntilIdle(model)
        XCTAssertEqual(model.message, String(localized: "Le secteur est passé à \(3) entre-temps. Rien n’a été confirmé."))
        XCTAssertNil(model.notes[target.id])
        XCTAssertEqual(SectorStatusText.changed(to: nil), String(localized: "Le secteur a changé entre-temps. Rien n’a été confirmé."))
    }

    func testOnlyMyOwnVerifiedConfirmationGreysTheButton() async throws {
        // r1.3.4 : la ligne vérifiée par un autre membre reste confirmable par moi.
        XCTAssertTrue(try target(status: .verifiedOnSite, own: .confirmed).canConfirm)
        XCTAssertTrue(try target(status: .verifiedOnSite).canConfirm)
        let service = ConfirmSpy(outcome: .success(ConfirmSectorResult(confirmed: 1, sectorStatus: .verifiedOnSite, proof: .radioLog)))
        let model = SectorConfirmModel(service: service, sleep: { _ in })
        let mine = try target(status: .verifiedOnSite, own: .verifiedOnSite)
        XCTAssertFalse(mine.canConfirm)
        model.start(mine) { _ in nil }
        XCTAssertEqual(model.phase, .idle)
        for _ in 0..<20 { await Task.yield() }
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Capture (SQ_SECTOR_SHOTS)

    static let blockPage = #"""
    {"identifications":[
     {"id":"n1","siteId":"0381522","type":"enb","enb":"610423","tech":"4G","operator":"ORANGE","marketCode":"FR","sectors":[],"validations":4},
     {"id":"p214","siteId":"0381522","type":"pci","enb":"610423","pci":214,"tech":"4G","operator":"ORANGE","marketCode":"FR","sectors":[1],"validations":1,
      "sectorStatus":"verified_on_site","myConfirmation":"verified_on_site","sectorCheck":{"status":"match"}},
     {"id":"p215","siteId":"0381522","type":"pci","enb":"610423","pci":215,"tech":"4G","operator":"ORANGE","marketCode":"FR","sectors":[2],"validations":1,
      "sectorStatus":"operator_rule","myConfirmation":null,"sectorCheck":{"status":"match"}},
     {"id":"p216","siteId":"0381522","type":"pci","enb":"610423","pci":216,"tech":"4G","operator":"ORANGE","marketCode":"FR","sectors":[1],"validations":1,
      "sectorStatus":"legacy_differs_rule","myConfirmation":null,"sectorCheck":{"status":"mismatch","expected":3}},
     {"id":"p217","siteId":"0381522","type":"pci","enb":"610423","pci":217,"tech":"4G","operator":"ORANGE","marketCode":"FR","sectors":[3],"validations":1,
      "sectorStatus":"confirmed","myConfirmation":"confirmed","sectorCheck":{"status":"match"}}
    ],"nextCursor":null,"checks":{"conflict":"ok","cellConflict":"ok","sectorCheck":"ok"}}
    """#

    func testCaptureSectorStatusForReview() async throws {
        guard let output = ProcessInfo.processInfo.environment["SQ_SECTOR_SHOTS"] else {
            throw XCTSkip("SQ_SECTOR_SHOTS absent")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let page = try JSONDecoder.signalQuest.decode(MyIdentificationsPage.self, from: Data(Self.blockPage.utf8))
        let counts = AntennaCellIdentifiers(pci: [
            AntennaPciEntry(value: "214", sector: 1, tech: "4G", band: 20, frequency: nil, enb: "610423",
                            sectorConfirmations: 3, sectorVerifiedConfirmations: 2),
        ])
        let services = AppServices(config: .test)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()

        let gate = SleepGate()
        let counting = SectorConfirmModel(service: ConfirmSpy(outcome: .failure(APIError.cancelled)), sleep: { _ in try await gate.wait() })
        counting.start(try target()) { _ in nil }
        let conflict = SectorConfirmModel(service: ConfirmSpy(outcome: .failure(
            APIError.http(status: 409, code: "SECTOR_CHANGED", message: "", requestId: nil, retryAfter: nil))), sleep: { _ in })
        conflict.start(try target()) { _ in [3] }
        for _ in 0..<200 where conflict.phase != .idle { await Task.yield() }
        let detailLine = try pciLine(status: "confirmed", myConfirmation: "confirmed", id: "c1", type: "cellid", cellId: "156266497")

        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("bloc-clair", .light, .large), ("bloc-sombre", .dark, .large), ("bloc-ax", .light, .accessibility2),
        ]
        for (name, scheme, size) in variants {
            let view = ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    IdentificationCorrectionBlock(
                        target: IdentificationCorrectionTarget(siteId: "0381522", kind: .enb, node: "610423"),
                        service: PageService(page: page), sectorCounts: counts
                    ) { _ in }
                    SectorConfirmBanner(model: counting)
                    SectorConfirmBanner(model: conflict)
                    SectorConfirmNoteView(note: .init(lines: [SectorStatusText.noProof], status: .confirmed))
                    SectorConfirmSection(item: detailLine, expected: nil, service: PageService(page: page),
                                         isOnline: true, onChanged: {})
                }
                .padding(16)
            }
            .background(SQColor.bg)
            .environmentObject(services)
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
        await gate.releaseAll()
    }
}

// MARK: - Doubles

private actor SleepGate {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    func wait() async throws { try await withCheckedThrowingContinuation { waiters.append($0) } }
    func releaseAll() {
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        waiters = []
    }
}

private actor ConfirmSpy: IdentifyServicing {
    struct Call: Equatable { let pci: String?; let cellId: String?; let sectors: [Int] }
    let outcome: Result<ConfirmSectorResult, Error>
    private(set) var calls: [Call] = []

    init(outcome: Result<ConfirmSectorResult, Error>) { self.outcome = outcome }

    func confirmSector(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?,
                       tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> ConfirmSectorResult {
        calls.append(Call(pci: pci, cellId: cellId, sectors: sectors))
        return try outcome.get()
    }

    nonisolated func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult { throw APIError.cancelled }
    nonisolated func mine(includeRelated: Bool) async throws -> [MyIdentification] { [] }
    nonisolated func withdraw(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> WithdrawResult { throw APIError.cancelled }
    nonisolated func delete(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> DeleteResult { throw APIError.cancelled }
    nonisolated func editSite(fromSiteId: String, toSiteId: String, enb: String?, gnb: String?, reason: String?) async throws -> EditSiteResult { throw APIError.cancelled }
    nonisolated func editSectors(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> EditSectorsResult { throw APIError.cancelled }
}

private struct PageService: IdentifyServicing, @unchecked Sendable {
    let page: MyIdentificationsPage
    func minePage(cursor: String?, siteId: String, enb: String?, gnb: String?) async throws -> MyIdentificationsPage { page }
    func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult { throw APIError.cancelled }
    func mine(includeRelated: Bool) async throws -> [MyIdentification] { [] }
    func withdraw(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> WithdrawResult { throw APIError.cancelled }
    func delete(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> DeleteResult { throw APIError.cancelled }
    func editSite(fromSiteId: String, toSiteId: String, enb: String?, gnb: String?, reason: String?) async throws -> EditSiteResult { throw APIError.cancelled }
    func editSectors(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> EditSectorsResult { throw APIError.cancelled }
}
