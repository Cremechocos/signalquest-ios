import XCTest
@testable import SignalQuest

/// Refonte des cartes de posts automatiques (04/11) : jauge de débit, mots des
/// étoiles et tracé coloré d'une session.
final class FeedAutomaticCardsRedesignTests: XCTestCase {
    // MARK: Jauge de débit

    func testSpeedScaleSitsOnTheTierBoundaries() {
        // Sept paliers de largeur égale : chaque seuil du contrat tombe sur une frontière.
        for (index, threshold) in [10.0, 30, 100, 300, 600, 1_000].enumerated() {
            XCTAssertEqual(FeedSpeedScale.position(mbps: threshold), Double(index + 1) / 7, accuracy: 1e-9, "\(threshold)")
        }
    }

    func testSpeedScaleKeepsRoomAboveOneGigabit() {
        // La 5G dépasse souvent 1 000 Mbit/s : le dernier palier va jusqu'à 3 000.
        XCTAssertEqual(FeedSpeedScale.position(mbps: 1_450), (6 + log(1.45) / log(3)) / 7, accuracy: 1e-9)
        XCTAssertLessThan(FeedSpeedScale.position(mbps: 2_000), 1)
        XCTAssertEqual(FeedSpeedScale.position(mbps: 3_000), 1, accuracy: 1e-9)
        XCTAssertEqual(FeedSpeedScale.position(mbps: 9_000), 1, accuracy: 1e-9)
        XCTAssertEqual(FeedSpeedScale.position(mbps: 118), (3 + log(1.18) / log(3)) / 7, accuracy: 1e-9)
        XCTAssertEqual(FeedSpeedScale.position(mbps: 0), 0)
    }

    func testSpeedScaleUsesTheMapColours() {
        // Les couleurs de la couche speedtest de la carte, du plus lent au plus rapide.
        XCTAssertEqual(FeedSpeedScale.tiers.map(\.hex),
                       [0xEF4444, 0xF97316, 0xEAB308, 0x84CC16, 0x22C55E, 0x06B6D4, 0x3B82F6])
        XCTAssertEqual(FeedSpeedScale.tiers.map { SQNetworkColors.speedHex($0.lowerBoundMbps) }, FeedSpeedScale.tiers.map(\.hex))
    }

    // MARK: Note de signal

    func testStarsHaveWords() {
        XCTAssertEqual((0...6).map { RatingCardView.starsWords($0) },
                       [nil, "Très mal", "Plutôt mal", "Correct", "Plutôt bien", "Très bien", nil])
    }

    // MARK: Tracé d'une session (contrat session-signal-trace v1, #958)

    private typealias Vector = (name: String, points: [SessionSignalTrace.Point], states: [String], segments: [String], summary: (String, String)?)

    private let vectors: [Vector] = [
        ("deux points mesurés", [.init(technology: "4G", signalStrength: -85), .init(technology: "4G", signalStrength: -112)], ["good", "critical"], ["critical"], ("good", "critical")),
        ("point « Aucun » au milieu", [.init(technology: "4G", signalStrength: -95), .init(technology: "Aucun", signalStrength: -125), .init(technology: "5G", signalStrength: -78)], ["fair", "noService", "excellent"], ["noService", "excellent"], ("excellent", "fair")),
        ("signal à 0 : sentinelle", [.init(technology: "4G", signalStrength: -90), .init(technology: "4G", signalStrength: 0)], ["good", "unknown"], ["unknown"], ("good", "good")),
        ("−140 en RSRP : identité factice, pas une mesure", [.init(technology: "4G", signalStrength: -100), .init(technology: "4G", signalStrength: -140)], ["fair", "unknown"], ["unknown"], ("fair", "fair")),
        ("hors plage 3GPP : valeur invalide", [.init(technology: "4G", signalStrength: -85), .init(technology: "4G", signalStrength: -30)], ["good", "unknown"], ["unknown"], ("good", "good")),
        ("ancien « Aucun » d'iOS servi « Inconnu », alias LTE et 4G+", [.init(technology: "Inconnu", signalStrength: 0), .init(technology: "LTE", signalStrength: -80), .init(technology: "4G+", signalStrength: -101)], ["unknown", "excellent", "poor"], ["excellent", "poor"], ("excellent", "poor")),
        ("2G et 3G à leurs propres seuils, jamais à l'échelle LTE", [.init(technology: "2G", signalStrength: -70), .init(technology: "3G", signalStrength: -76)], ["excellent", "good"], ["good"], ("excellent", "good")),
        ("aucun point mesuré", [.init(technology: "Aucun", signalStrength: 0), .init(technology: "4G", signalStrength: 0)], ["noService", "unknown"], ["unknown"], nil),
        ("un seul point", [.init(technology: "4G", signalStrength: -85)], ["good"], [], ("good", "good")),
    ]

    func testTraceVectors() {
        XCTAssertEqual(vectors.count, 9)
        for vector in vectors {
            XCTAssertEqual(SessionSignalTrace.states(vector.points).map(\.contractKey), vector.states, vector.name)
            XCTAssertEqual(SessionSignalTrace.segments(vector.points).map(\.contractKey), vector.segments, vector.name)
            switch (SessionSignalTrace.summary(vector.points), vector.summary) {
            case (.none, nil): break
            case (.range(let best, let worst), let expected?):
                XCTAssertEqual(best.contractKey, expected.0, vector.name)
                XCTAssertEqual(worst.contractKey, expected.1, vector.name)
            case (let got, let expected):
                XCTFail("\(vector.name) : \(got) au lieu de \(String(describing: expected))")
            }
        }
    }

    func testNoServiceIsDashedSlateAndUnknownIsGrey() {
        XCTAssertTrue(SQQualityScale.Signal.noService.isHatched)
        XCTAssertEqual(SQQualityScale.Signal.noService.hex, 0x64748B)
        XCTAssertEqual(SQQualityScale.Signal.unknown.hex, 0x9CA3AF)
    }

    func testSessionPointsDecodeTheirSignal() throws {
        let json = #"{"latitude":45.2,"longitude":5.72,"signalStrength":-95,"technology":"5G"}"#
        let point = try JSONDecoder().decode(SocialMapPoint.self, from: Data(json.utf8))
        XCTAssertEqual(point.signalStrength, -95)
        XCTAssertEqual(point.technology, "5G")
        let bare = try JSONDecoder().decode(SocialMapPoint.self, from: Data(#"{"latitude":1,"longitude":2}"#.utf8))
        XCTAssertNil(bare.technology)
    }
}
