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
        download: Double = 487
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
            pingDlMs: hasLoadedPings ? 28 : nil,
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

    /// Les formats suivent l'image de partage : virgule française, Gbps au-delà
    /// de 1000, tiret quand la mesure manque.
    func testSpeedFormattingMatchesShareCard() {
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(487).value, "487")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(487).unit, "Mbps")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(45.3).value, "45,3")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(1_420).value, "1,42")
        XCTAssertEqual(SpeedtestDetailSheet.formatSpeedParts(1_420).unit, "Gbps")
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
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.lowercased().contains("publié") || message.lowercased().contains("référence"))
    }
}
