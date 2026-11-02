import XCTest
@testable import SignalQuest

/// Image de partage d'un test d'expérience : la phrase `share` de `presentation-v1` sur chaque
/// usage, et rien ne se coupe dans la mise en page de la maquette.
final class ExperienceSharePhraseTests: XCTestCase {
    /// Les cas de `presentation-v1`, qui reprend les six cas de l'ancien contrat de phrases.
    private func vectors() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/experience-tests/presentation-v1.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["cases"] as? [[String: Any]])
    }

    private func sharePhrases(_ tests: [String: Any], _ language: ExperienceShareLanguage) -> [String] {
        let uses = ExperiencePresentation.uses(tests: tests, methodology: "experience-v4")
        return ExperiencePresentation.Use.allCases.compactMap { uses[$0]?.share.rendered(language) }
    }

    func testNumbersUseTheContractSpaces() {
        XCTAssertEqual(ExperiencePresentation.format(.duration, .int(990), .fr), "990\u{00A0}ms")
        XCTAssertEqual(ExperiencePresentation.format(.duration, .int(1_250), .fr), "1,3\u{00A0}s")
        XCTAssertEqual(ExperiencePresentation.format(.duration, .int(12_449), .en), "12.4\u{00A0}s")
        XCTAssertEqual(ExperiencePresentation.format(.duration, .int(1_234_560), .fr), "1\u{202F}234,6\u{00A0}s")
        XCTAssertEqual(ExperienceSharePhrases.integer(1_000, .fr), "1\u{202F}000")
        XCTAssertEqual(ExperienceSharePhrases.integer(1_000, .en), "1,000")
    }

    /// L'image reprend la phrase `share` de chaque usage, sans ligne « Échelle · Adaptative ».
    func testRowsTakeThePresentationSharePhrase() {
        let tests: [String: Any] = [
            "videoLadder": ["state": "measured", "rungs": [["quality": "720p", "state": "measured", "stalls": []]]],
            "videoAdaptive": ["state": "interrupted"],
            "webPage": ["state": "failed"],
        ]
        let scores = ExperienceScores(tests: tests)
        let model = ExperienceShareCardBuilder.model(tests: tests, scores: scores, measuredAt: nil, network: nil, language: .fr)
        XCTAssertEqual(model.rows.map(\.phrase), ["Jusqu’à 720p sans coupure", "Échec de la mesure", "Non mesuré", "Non mesuré"])
        XCTAssertEqual(model.rows.map(\.score), [40, nil, nil, nil])
        XCTAssertTrue(model.rows.allSatisfy { $0.detail == nil })
        XCTAssertNil(model.overall)
        XCTAssertEqual(model.overallNote, "Note globale à partir de 2 usages notés")
        let english = ExperienceShareCardBuilder.model(tests: tests, scores: scores, measuredAt: nil, network: nil, language: .en)
        XCTAssertEqual(english.rows.map(\.phrase), ["Up to 720p without stalling", "Measurement failed", "Not measured", "Not measured"])
    }

    /// Réserve d'Alexandre : aucun résultat ne se coupe, même moyen ou faible. Chaque phrase
    /// tient en 2 lignes de 14 px dans sa colonne et fait 60 caractères au plus.
    func testWorstCasesHoldInTwoLines() throws {
        XCTAssertTrue(SQShareFonts.areEmbedded, "sans Sora, la mesure ne vaut rien")
        var phrases: [String] = []
        for vector in try vectors() {
            for language in ExperienceShareLanguage.allCases {
                let tests = vector["tests"] as? [String: Any] ?? [:]
                phrases += sharePhrases(tests, language)
            }
        }
        // Pires cas au-delà des vecteurs : grands nombres, quatre chiffres de coupures.
        let worst: [String: Any] = [
            "videoLadder": ["state": "measured", "rungs": [["quality": "480p", "state": "measured", "stalls": [["atPlaybackMs": 1]]]]],
            "videoAdaptive": ["state": "measured", "stalls": Array(repeating: ["atPlaybackMs": 1], count: 1_000)],
            "webPage": ["state": "measured", "openings": [["state": "measured", "totalMs": 59_999], ["state": "failed"], ["state": "failed"]]],
            "gameAndCalls": ["state": "measured", "medianMs": 99_999, "jitterMs": 9_999, "spikeCount": 300],
            "upload": ["state": "measured", "items": [["kind": "photo", "totalMs": 599_999], ["kind": "video", "totalMs": 599_999]]],
        ]
        for language in ExperienceShareLanguage.allCases {
            phrases += sharePhrases(worst, language)
            phrases += ExperiencePresentation.texts.keys.filter { $0.hasPrefix("experience.state.") || $0.hasPrefix("experience.local.") }
                .map { ExperiencePresentation.label($0, language) }
        }
        for phrase in phrases {
            XCTAssertLessThanOrEqual(phrase.count, 60, phrase)
            XCTAssertLessThanOrEqual(ExperienceShareCardRenderer.phraseLines(phrase).count, 2, phrase)
            XCTAssertFalse(phrase.contains("…"), phrase)
        }

        let columns = ExperienceShareCardRenderer.columns(width: 1_200)
        XCTAssertEqual(columns.phrase, 408.5, accuracy: 1, "≈ 409 de la maquette")
        // Le réseau et la légende de la note globale passent à la ligne dans la colonne gauche.
        let network = ExperienceShareCardRenderer.wrap(
            [.init("Bouygues Telecom", [.font: ExperienceShareCardRenderer.networkFont]),
             .init("\u{00A0}· 5G NSA", [.font: ExperienceShareCardRenderer.networkFont])],
            maxWidth: columns.left - 14
        )
        XCTAssertLessThanOrEqual(network.count, 2)
        XCTAssertFalse(network.dropFirst().contains { $0.first?.text.hasPrefix("\u{00A0}·") == true }, "« · » reste avec l'opérateur")
        for note in ["Note globale à partir de 2 usages notés", "Overall score from 2 rated uses", "Moyenne des 3 usages notés"] {
            let lines = ExperienceShareCardRenderer.wrap([.init(note, [.font: ExperienceShareCardRenderer.noteFont])], maxWidth: columns.left)
            XCTAssertLessThanOrEqual(lines.count, 2, note)
        }
    }

    func testTheImageIsTheMockupSizeExportedTwice() throws {
        let tests = try XCTUnwrap(try vectors().first?["tests"] as? [String: Any])
        let model = ExperienceShareCardBuilder.model(
            tests: tests, scores: ExperienceScores(tests: tests), measuredAt: Date(timeIntervalSince1970: 1_793_200_000),
            network: ExperienceShareCardBuilder.networkLine(connectionType: "cellular", technology: "5G", operatorKey: "orange", language: .fr),
            language: .fr
        )
        XCTAssertEqual(model.rows.map(\.label), ["Vidéo", "Web", "Jeu et appels", "Envoi"])
        XCTAssertEqual(model.network?.name, "Orange")
        XCTAssertEqual(model.network?.detail, "5G")
        XCTAssertNotNil(model.overall)
        XCTAssertEqual(model.overallNote, "Moyenne des 4 usages")
        let image = ExperienceShareCardBuilder.renderImage(model)
        XCTAssertEqual(image.size, CGSize(width: 2_400, height: 1_260))
    }

    /// Planche de contrôle : `SQ_SHARE_RENDER_DIR=… ` écrit l'image de chaque vecteur, en français et en anglais.
    func testWritesTheVectorImagesWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["SQ_SHARE_RENDER_DIR"] else { throw XCTSkip("SQ_SHARE_RENDER_DIR absent") }
        for (index, vector) in try vectors().enumerated() {
            let tests = vector["tests"] as? [String: Any] ?? [:]
            for language in ExperienceShareLanguage.allCases {
                let model = ExperienceShareCardBuilder.model(
                    tests: tests, scores: ExperienceScores(tests: tests), measuredAt: Date(timeIntervalSince1970: 1_793_200_000),
                    network: ExperienceShareCardBuilder.networkLine(
                        connectionType: "cellular", technology: index == 1 ? "5G NSA" : "5G",
                        operatorKey: index == 1 ? "bouygues" : "orange", language: language),
                    language: language
                )
                let data = try XCTUnwrap(ExperienceShareCardBuilder.renderImage(model).pngData())
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("vector\(index + 1)-\(language.rawValue).png"))
            }
        }
    }

    func testNetworkLineNeverNamesAnUnknownOperator() {
        XCTAssertEqual(ExperienceShareCardBuilder.networkLine(connectionType: "wifi", technology: nil, operatorKey: "orange", language: .fr)?.name, "Wi-Fi")
        let unknown = ExperienceShareCardBuilder.networkLine(connectionType: "cellular", technology: "4G", operatorKey: "zz-unknown", language: .en)
        XCTAssertEqual(unknown?.name, "4G")
        XCTAssertNil(unknown?.barColor)
        XCTAssertNil(ExperienceShareCardBuilder.networkLine(connectionType: "unknown", technology: nil, operatorKey: nil, language: .fr))
    }
}
