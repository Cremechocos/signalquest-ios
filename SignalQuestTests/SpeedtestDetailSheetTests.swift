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
        loadedDownloadPing: Double? = 28
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
            pingMs: 18, pingMedianMs: 18, pingMinMs: 14, pingMaxMs: 30,
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
            deviceModel: "iPhone 17 Pro", osVersion: "iOS 26"
        )
    }

    /// Les formats suivent le lexique (formateur commun `SQUnits`) : virgule
    /// française, « Mbit/s », Gbit/s au-delà de 1000, tiret quand la mesure manque.
    func testSpeedFormattingMatchesShareCard() {
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(487).value, "487")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(487).unit, "Mbit/s")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(45.3).value, "45")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(4.53).value, "4,5")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(1_420).value, "1,420")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(1_420).unit, "Gbit/s")
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

    /// Les valeurs absentes sont listées une fois : un groupe entier vide se
    /// nomme par son titre, pas ligne par ligne.
    func testMissingValuesAreListedOnce() {
        let figures = SpeedtestResultFigures(result: sample(hasUpload: false))
        let groups = SpeedtestTestDetailsSheet.groups(for: .speed, figures: figures)
        let missing = SpeedtestTestDetailsSheet.missing(in: groups)
        let upload = String(localized: "↑ Montant").trimmingCharacters(in: CharacterSet(charactersIn: "↓↑ ")).lowercased()
        XCTAssertTrue(missing.contains(upload), "\(missing)")
        XCTAssertEqual(missing.filter { $0 == upload }.count, 1)
        XCTAssertFalse(missing.contains { $0.hasPrefix(String(localized: "Moyenne").lowercased()) && $0.contains(upload) })
    }

    func testPlmnIsSplitAfterTheCountryCode() {
        XCTAssertEqual(SpeedtestTestDetailsSheet.plmn("20801"), "208-01")
        XCTAssertEqual(SpeedtestTestDetailsSheet.plmn("302720"), "302-720")
        XCTAssertEqual(SpeedtestTestDetailsSheet.plmn("—"), "—")
    }
}
