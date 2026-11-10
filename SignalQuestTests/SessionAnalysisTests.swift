import SwiftUI
import XCTest
@testable import SignalQuest

/// DRIVE-ANALYSIS-1 v1 : analyse de trajet servie par le serveur, une ligne par
/// opérateur. La réponse ci-dessous reprend, sans les endroits, celle d'un
/// trajet public double opérateur lue en prod le 10/11.
@MainActor
final class SessionAnalysisTests: XCTestCase {
    private let readyJSON = #"""
    {"analysis":{"contractVersion":1,"formulaVersion":1,"status":"ready","reason":null,
     "computedAt":"2026-11-10T15:36:47.642Z",
     "basis":{"durationSec":84020,"distanceKm":118.97,"usablePoints":2926,"excludedPoints":0,"excludedReasons":{}},
     "thresholds":{"usableRsrpDbm":-110,"goodRsrpDbm":-95,"weakRsrpDbm":-100,"noServiceRsrpDbm":-120},
     "noRecord":{"km":1.939,"count":2,"source":"server_estimate","totalSec":70,"fractionOfDuration":0.001},
     "gps":{"lossSec":null,"segments":null},
     "operators":[
      {"seriesKey":null,"operatorKey":"FREE","marketCode":"FR","operatorRank":null,"pointCount":2882,
       "quality":{"level":"fair","score":47,"weighting":"per_km","recordedFraction":0.977},
       "verdict":{"holes":9,"level":"fair","headlineCode":"WITH_HOLES","headlineParams":{"holes":9,"level":"fair"}},
       "spots":[],"spotsTotal":134},
      {"seriesKey":null,"operatorKey":"ORANGE","marketCode":"FR","operatorRank":null,"pointCount":44,
       "quality":{"level":"fair","score":57,"weighting":"per_km","recordedFraction":1},
       "verdict":{"holes":1,"level":"fair","headlineCode":"WITH_HOLES","headlineParams":{"holes":1,"level":"fair"}},
       "spots":[],"spotsTotal":7}
     ]}}
    """#

    private func decode(_ json: String) throws -> SessionAnalysis {
        try XCTUnwrap(try JSONDecoder.signalQuest.decode(SessionAnalysisResponse.self, from: Data(json.utf8)).analysis)
    }

    func testReadyAnalysisDecodesOneLinePerOperator() throws {
        let analysis = try decode(readyJSON)
        XCTAssertTrue(analysis.isDisplayable)
        XCTAssertEqual(analysis.operators.map(\.operatorKey), ["FREE", "ORANGE"], "Ordre du serveur gardé")
        XCTAssertNotEqual(analysis.operators[0].id, analysis.operators[1].id)
        let free = analysis.operators[0]
        XCTAssertEqual(SessionAnalysisText.operatorLabel(free), "Free Mobile")
        XCTAssertEqual(free.quality?.score, 47)
        XCTAssertEqual(SessionAnalysisText.headline(free), "Correct · 9 trous")
        XCTAssertEqual(SessionAnalysisText.headline(analysis.operators[1]), "Correct · 1 trou")
        XCTAssertEqual(SessionAnalysisText.recordedLabel(free), "Mesuré sur 98 % du trajet")
        XCTAssertFalse(free.isUnreliable)
        XCTAssertEqual(analysis.noRecord?.source, "server_estimate")
        XCTAssertNotNil(SessionAnalysisText.noRecordLabel(analysis.noRecord))
    }

    func testUnavailableAndLiveAnalysesAreHidden() throws {
        for (status, reason) in [("unavailable", "no_points"), ("unavailable", "too_short"), ("live", "session_active")] {
            let json = #"{"analysis":{"contractVersion":1,"formulaVersion":1,"status":"\#(status)","reason":"\#(reason)","operators":[]}}"#
            XCTAssertFalse(try decode(json).isDisplayable, "\(status)/\(reason) : bloc caché")
        }
    }

    func testTwoSimsOfTheSameOperatorAndUnknownNetworkAreLabelled() throws {
        let json = #"""
        {"analysis":{"contractVersion":1,"formulaVersion":2,"status":"ready","operators":[
          {"seriesKey":"a1b2c3d4e5f60718","operatorKey":"ORANGE","operatorRank":1,"pointCount":10,
           "verdict":{"level":"poor","holes":0,"headlineCode":"UNRELIABLE"}},
          {"seriesKey":"0f1e2d3c4b5a6978","operatorKey":"ORANGE","operatorRank":2,"pointCount":9,
           "verdict":{"level":"weird_future_level","holes":2,"headlineCode":"WITH_HOLES"}},
          {"seriesKey":null,"operatorKey":null,"pointCount":3,"verdict":{"level":"good","holes":0,"headlineCode":"OK"}},
          {"operatorKey":42}
        ]}}
        """#
        let analysis = try decode(json)
        XCTAssertEqual(analysis.operators.map(SessionAnalysisText.operatorLabel), ["Orange (1)", "Orange (2)", "Réseau inconnu", "Réseau inconnu"])
        XCTAssertTrue(analysis.operators[0].isUnreliable)
        XCTAssertEqual(SessionAnalysisText.headline(analysis.operators[0]), "Faible · aucun trou")
        XCTAssertEqual(SessionAnalysisText.headline(analysis.operators[1]), "2 trous", "Niveau inconnu : on ne l'invente pas")
        XCTAssertEqual(Set(analysis.operators.map(\.id)).count, 4, "Ids distincts, seriesKey jamais affiché")
    }

    func testNoRecordIsSilentWithoutHoles() {
        XCTAssertNil(SessionAnalysisText.noRecordLabel(nil))
        let json = #"{"totalSec":0,"count":0,"km":0,"source":"server_estimate"}"#
        let none = try? JSONDecoder().decode(SessionAnalysis.NoRecord.self, from: Data(json.utf8))
        XCTAssertNil(SessionAnalysisText.noRecordLabel(none))
    }

    /// Rendu FR/EN de la carte, pour relecture (`build/qa/session-analysis`).
    func testAnalysisCardRenders() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = repository.appendingPathComponent("build/qa/session-analysis")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let analysis = try decode(readyJSON)
        for scheme in [ColorScheme.light, .dark] {
            let content = SessionAnalysisCard(analysis: analysis)
                .padding(16)
                .frame(width: 390)
                .background(SQColor.bg)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 150)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("card-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
