import XCTest
import SwiftUI
@testable import SignalQuest

/// La fiche d'un test passé doit rendre sans crasher et afficher les vrais
/// chiffres, y compris quand des mesures manquent (upload raté, pings chargés
/// absents, pas de position). Rendu exporté pour revue visuelle.
@MainActor
final class SpeedtestDetailSheetTests: XCTestCase {

    private func sample(
        hasUpload: Bool = true,
        hasLoadedPings: Bool = true,
        hasCoordinate: Bool = true,
        download: Double = 487,
        loadedDownloadPing: Double? = 28,
        methodology: Int? = nil,
        pingMin: Double? = 14
    ) -> SpeedtestRunResult {
        var dl: [Double] = []
        var ul: [Double] = []
        for i in 0..<40 {
            let t = Double(i) / 39.0
            dl.append(download * (0.3 + 0.7 * t) + Double((i * 37) % 30))
            ul.append(45.0 * (0.3 + 0.7 * t) + Double((i * 19) % 12))
        }
        return SpeedtestRunResult(
            id: UUID(),
            label: "x",
            downloadMbps: download,
            downloadAverageMbps: download,
            downloadMaxMbps: download + 40,
            downloadP90Mbps: nil, downloadP95Mbps: nil,
            uploadMbps: hasUpload ? 45 : nil,
            uploadAverageMbps: hasUpload ? 45 : nil,
            uploadMaxMbps: hasUpload ? 60 : nil,
            uploadP90Mbps: nil, uploadP95Mbps: nil,
            pingMs: 18, pingMedianMs: 18, pingMinMs: pingMin, pingMaxMs: 30,
            jitterMs: 3,
            pingDlMs: hasLoadedPings ? loadedDownloadPing : nil,
            jitterDlMs: hasLoadedPings ? 4.1 : nil,
            pingUlMs: hasLoadedPings ? 36 : nil,
            jitterUlMs: hasLoadedPings ? 5.2 : nil,
            pingProtocol: "TCP", durationSeconds: 10,
            connectionType: .cellular,
            cellularTechnology: .fiveGSA,
            networkOperatorName: "Orange", wifiSSID: nil,
            city: "Grenoble",
            coordinate: hasCoordinate ? Coordinates(latitude: 45.188, longitude: 5.724) : nil,
            serverName: "Paris BBR (Bouygues)",
            downloadServerName: "Paris BBR (Bouygues)",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: dl,
            uploadSeriesMbps: hasUpload ? ul : nil,
            downloadGraceWindowCount: 4,
            uploadGraceWindowCount: hasUpload ? 4 : nil,
            uploadMeasurementSource: nil,
            deviceModel: "iPhone 17 Pro", osVersion: "iOS 26",
            methodologyVersion: methodology
        )
    }

    /// IOS-033 : dès la méthodologie 6, la tuile montre le minimum et le dit, comme
    /// l'écran de résultat ; avant, ou sans minimum servi, elle reste « Latence ».
    func testLatencyTileSaysMinimumFromMethodologySix() {
        XCTAssertTrue(SpeedtestDetailContent.latencyIsMinimum(sample(methodology: 6)))
        XCTAssertTrue(SpeedtestDetailContent.latencyIsMinimum(sample(methodology: 7)))
        XCTAssertFalse(SpeedtestDetailContent.latencyIsMinimum(sample(methodology: 5)))
        XCTAssertFalse(SpeedtestDetailContent.latencyIsMinimum(sample(methodology: nil)))
        XCTAssertFalse(SpeedtestDetailContent.latencyIsMinimum(sample(methodology: 6, pingMin: nil)))
        // La valeur affichée suit la même règle : le minimum dès la v6.
        XCTAssertEqual(sample(methodology: 6).primaryPingMs, 14)
        XCTAssertEqual(sample(methodology: 5).primaryPingMs, 18)
    }

    /// Les formats suivent le lexique (formateur commun `SQUnits`) : virgule
    /// française, « Mb/s », Gb/s au-delà de 1000, tiret quand la mesure manque.
    func testSpeedFormattingMatchesShareCard() {
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(487).value, "487")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(487).unit, "Mb/s")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(45.3).value, "45")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(4.53).value, "4,5")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(1_420).value, "1,420")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(1_420).unit, "Gb/s")
        // Upload raté : pas de zéro trompeur.
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(nil).value, "—")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(0).value, "—")
    }

    /// Rendu réel du contenu, cas nominal et dégradés.
    ///
    /// ⚠️ On rend `SpeedtestDetailContent`, PAS la sheet : `ImageRenderer` ne
    /// sait pas rendre un `NavigationStack` et renvoie une image de
    /// remplacement. Un test qui se contente de `width > 0` passe alors sur ce
    /// placeholder et ne prouve rien — c'est arrivé.
    func testContentRendersInAllStates() throws {
        let cases: [(String, SpeedtestRunResult)] = [
            ("nominal", sample()),
            ("noupload", sample(hasUpload: false)),
            ("noloadedping", sample(hasLoadedPings: false)),
            ("nocoordinate", sample(hasCoordinate: false)),
            ("gigabit", sample(download: 1_420)),
        ]
        for (name, result) in cases {
            let view = SpeedtestDetailContent(result: result, onShowOnMap: { _ in })
                .frame(width: 393)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "rendu nil pour \(name)")
            XCTAssertEqual(image.size.width, 393, accuracy: 1, "largeur inattendue pour \(name)")
            // Une fiche complète est longue : le placeholder de SwiftUI, lui,
            // prend la hauteur imposée. Ce seuil distingue les deux.
            XCTAssertGreaterThan(image.size.height, 600, "contenu trop court pour \(name) — placeholder ?")
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: URL(fileURLWithPath: "/tmp/sq_detail_\(name).png"))
            print("DETAIL_SHEET_WRITTEN /tmp/sq_detail_\(name).png")
        }
    }

    /// Le PATCH de visibilité doit porter EXACTEMENT ce que le backend lit.
    /// Un POST re-soumis renverrait sa réponse idempotente sans rien changer :
    /// la publication serait silencieusement sans effet.
    func testVisibilityUpdateEncodesBackendContract() throws {
        let body = SpeedtestVisibilityUpdate(isVisibleOnMap: true, shareExactLocation: false)
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["isVisibleOnMap"] as? Bool, true)
        XCTAssertEqual(json["shareExactLocation"] as? Bool, false)
        XCTAssertEqual(json.keys.count, 2, "aucun champ parasite : le PATCH ne doit rien écraser d'autre")
    }

    /// Un test antérieur à la mémorisation de l'id serveur n'est pas publiable :
    /// l'erreur doit l'expliquer, pas échouer en silence.
    func testUnknownServerIdIsExplained() {
        let message = SpeedtestPublishError.unknownServerId.errorDescription ?? ""
        // Indépendant de la langue : on vérifie qu'une EXPLICATION est fournie —
        // une vraie phrase, pas le nom de cas brut — et non sa formulation.
        XCTAssertFalse(message.isEmpty)
        XCTAssertGreaterThan(message.count, 20, "Un motif d'échec doit être explicité, pas nommé")
        XCTAssertFalse(message.contains("unknownServerId"))
    }

    // MARK: - Page Speedtest (piste A, 20/10)

    /// Le chiffre de l'anneau rejoint sa cible au rythme e^(-dt/180 ms), repart de
    /// zéro à chaque phase et ne saute pas après une pause de l'écran.
    func testGlideFollowsTheTargetWithTimeConstant() {
        let glide = SpeedtestGlide()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(glide.step(toward: 100, key: "1-2", at: start), 0)
        let afterOneTau = glide.step(toward: 100, key: "1-2", at: start.addingTimeInterval(SpeedtestGlide.timeConstant))
        XCTAssertEqual(afterOneTau, 100 * (1 - exp(-1)), accuracy: 0.001)
        // Une pause de 10 s compte pour 0,5 s : la valeur approche sans bondir d'un coup.
        let afterPause = glide.step(toward: 100, key: "1-2", at: start.addingTimeInterval(10))
        XCTAssertLessThan(afterPause, 100)
        XCTAssertGreaterThan(afterPause, afterOneTau)
        // Nouvelle phase : repart de zéro.
        XCTAssertEqual(glide.step(toward: 40, key: "1-3", at: start.addingTimeInterval(11)), 0)
    }

    /// « Sous charge » = latences totales mesurées pendant chaque phase (règle du
    /// 20/10, plus d'écart « +N ms ») ; un seul sens si l'autre manque ; rien sans
    /// mesure chargée ; pas de note sans preuve que le ping visait le serveur du test.
    func testUnderLoadShowsTotalLatencyPerDirection() {
        let loaded = SpeedtestResultFigures(result: sample())
        XCTAssertEqual(loaded.latencyMs, 18)
        XCTAssertEqual(loaded.underLoad?.receivingMs, 28)
        XCTAssertEqual(loaded.underLoad?.sendingMs, 36)
        XCTAssertNil(loaded.underLoad?.grade)

        let uploadOnly = SpeedtestResultFigures(result: sample(loadedDownloadPing: nil))
        XCTAssertNil(uploadOnly.underLoad?.receivingMs)
        XCTAssertEqual(uploadOnly.underLoad?.sendingMs, 36)

        XCTAssertNil(SpeedtestResultFigures(result: sample(hasLoadedPings: false)).underLoad)
    }

    /// Les données comptées par l'appareil servent de repli quand la trace manque.
    func testTransferredBytesFallsBackToTheDeviceCounter() {
        let figures = SpeedtestResultFigures(result: sample())
        XCTAssertEqual(figures.transferredBytes(deviceCount: 52_000_000), 52_000_000)
        XCTAssertNil(figures.transferredBytes(deviceCount: nil))
        XCTAssertNil(figures.transferredBytes(deviceCount: 0))
    }

    /// Un ancien test (pas de courbe, pas de latence, pas d'envoi) ne garde que
    /// ce qui a été mesuré : ni tuile « — », ni cadre de courbe vide, ni carte
    /// Latence remplie de tirets. Sa fiche est donc nettement plus courte.
    func testHistoricalTestHidesWhatWasNotMeasured() throws {
        let full = sample()
        let old = SpeedtestRunResult(
            id: UUID(), label: "x",
            downloadMbps: 148, downloadAverageMbps: 148, downloadMaxMbps: 161,
            downloadP90Mbps: nil, downloadP95Mbps: nil,
            uploadMbps: nil, uploadAverageMbps: nil, uploadMaxMbps: nil,
            uploadP90Mbps: nil, uploadP95Mbps: nil,
            pingMs: nil, pingMedianMs: nil, pingMinMs: nil, pingMaxMs: nil,
            jitterMs: nil, pingDlMs: nil, jitterDlMs: nil, pingUlMs: nil, jitterUlMs: nil,
            pingProtocol: nil, durationSeconds: 10,
            connectionType: .cellular, cellularTechnology: .fourG,
            networkOperatorName: "ORANGE", wifiSSID: nil,
            city: nil, coordinate: nil, serverName: nil, downloadServerName: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: nil, uploadSeriesMbps: nil,
            downloadGraceWindowCount: nil, uploadGraceWindowCount: nil,
            uploadMeasurementSource: nil, deviceModel: nil, osVersion: nil
        )
        func height(_ result: SpeedtestRunResult, _ name: String) throws -> CGFloat {
            let view = SpeedtestDetailContent(result: result)
                .frame(width: 393)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/sq_detail_\(name).png"))
            return image.size.height
        }
        let fullHeight = try height(full, "full")
        let oldHeight = try height(old, "historical")
        XCTAssertLessThan(oldHeight, fullHeight - 300, "courbe et latence absentes : leurs cartes ne doivent pas s'afficher")
    }

    func testPlmnIsSplitAfterTheCountryCode() {
        XCTAssertEqual(SpeedtestDetailContent.plmn("20801"), "208-01")
        XCTAssertEqual(SpeedtestDetailContent.plmn("302720"), "302-720")
        XCTAssertEqual(SpeedtestDetailContent.plmn("—"), "—")
    }

    /// Revue du détail (22/11) : le bloc « Signal » et l'adresse ne s'affichent que
    /// s'ils ont quelque chose à dire ; un résumé vide ne laisse pas de cadre.
    func testSignalCardAndAddressShowOnlyWithData() throws {
        func height(_ radio: SpeedtestServedRadio?, _ name: String) throws -> CGFloat {
            let view = SpeedtestDetailContent(result: sample(), radio: radio)
                .frame(width: 393)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/sq_detail_\(name).png"))
            return image.size.height
        }
        let radio = SpeedtestServedRadio(bands: "B3 + B7 · n78", readings: [
            .init(label: "RSRP", value: "-95 dBm", level: .fair),
            .init(label: "RSRQ", value: "-11 dB", level: .good),
            .init(label: "SINR", value: "14 dB", level: .good),
        ])
        let without = try height(nil, "nosignal")
        XCTAssertEqual(try height(SpeedtestServedRadio(bands: nil, readings: []), "emptysignal"), without, accuracy: 1)
        XCTAssertGreaterThan(try height(radio, "signal"), without + 120, "bandes et trois mesures : le bloc doit s'afficher")
    }

    /// QA-063 : la médiane s'écrit sous la courbe quand la trace en donne une, et rien ne
    /// la remplace sinon. Les deux textes existent dans la langue du test.
    func testThroughputMedianShowsUnderTheCurveOnlyWhenMeasured() throws {
        func result(_ samples: [SpeedtestMeasurementInterval], _ name: String) throws -> CGFloat {
            let phase = SpeedtestPhaseTrace(phase: "download", attemptId: "median", startOffsetMs: 0, warmupEndOffsetMs: 0,
                measurementEndOffsetMs: 4000, totalEndOffsetMs: 4000, measuredBytes: 16_000_000,
                totalTransferredBytes: 16_000_000, byteSource: "client-received", sampleByteSource: "client-received",
                liveWindowMs: 1000, peakWindowMs: 1200, samples: samples)
            let trace = SpeedtestMeasurementTrace(runId: "median-run", phases: [phase], abandonedAttempts: [])
            let run = SpeedtestRunResult(label: "median", downloadMbps: 32, downloadAverageMbps: 32,
                downloadMaxMbps: 80, uploadAverageMbps: nil, uploadMaxMbps: nil, durationSeconds: 4,
                connectionType: .wifi, measurementTrace: trace, methodologyVersion: 7)
            let view = SpeedtestDetailContent(result: run)
                .frame(width: 393)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/sq_detail_\(name).png"))
            return image.size.height
        }
        let measured = try result([
            .init(startMs: 0, endMs: 1000, bytes: 1_000_000), .init(startMs: 1000, endMs: 2000, bytes: 2_000_000),
            .init(startMs: 2000, endMs: 3000, bytes: 3_000_000), .init(startMs: 3000, endMs: 4000, bytes: 10_000_000),
        ], "median")
        // Un seul échantillon : une fenêtre, pas de courbe découpée, pas de médiane.
        let single = try result([.init(startMs: 0, endMs: 4000, bytes: 16_000_000)], "nomedian")
        XCTAssertGreaterThan(measured, single + 10, "la ligne Médiane doit s'afficher sous la courbe")

        let english = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
        XCTAssertEqual(String(localized: "Médiane \("20") \("Mb/s")"), english ? "Median 20 Mb/s" : "Médiane 20 Mb/s")
        XCTAssertEqual(String(localized: "Médiane : la moitié des secondes mesurées est au-dessus, l’autre moitié au-dessous."),
                       english ? "Median: half of the measured seconds are above it, half below."
                               : "Médiane : la moitié des secondes mesurées est au-dessus, l’autre moitié au-dessous.")
    }
}
