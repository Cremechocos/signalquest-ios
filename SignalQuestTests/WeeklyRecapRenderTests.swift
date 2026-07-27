import XCTest
import UIKit
@testable import SignalQuest

/// L'image partagée est le seul livrable vu par des gens sans l'app : un rendu
/// vide ou dégénéré ne se remarquerait nulle part ailleurs.
final class WeeklyRecapRenderTests: XCTestCase {
    @MainActor
    func testTheSharedCardRendersSomethingReal() throws {
        let stats = WeeklyRecapStats(
            weekStart: Date(timeIntervalSince1970: 1_753_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_753_604_800),
            speedtestCount: 12, topDownloadMbps: 243.5, topDownloadTech: "5G",
            topDownloadOperator: "Orange", sessionPoints: 840, sessionDistanceKm: 31.2,
            validationCount: 4, photoCount: 2, badgeCount: 1,
            signalMomentsShared: 3, topCity: "Lyon"
        )
        let image = try XCTUnwrap(WeeklyRecapImageRenderer.renderImage(stats))
        // Taille attendue à l'échelle d'export (3×).
        XCTAssertEqual(image.size.width, 420, accuracy: 1)
        XCTAssertEqual(image.size.height, 520, accuracy: 1)
        XCTAssertEqual(image.scale, 3, accuracy: 0.01)
        let png = try XCTUnwrap(image.pngData())
        // Une carte pleine de contenu pèse largement plus qu'un aplat uni ;
        // ce seuil attrape le rendu vide, pas une variation de mise en page.
        XCTAssertGreaterThan(png.count, 10_000, "Image suspecte : \(png.count) octets")
        // Dépose la carte pour inspection visuelle : c'est le seul livrable
        // qui sort de l'app, un test de taille ne dit rien de sa lisibilité.
        let dumped = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sq-recap-preview.png")
        try? png.write(to: dumped)
    }
}
