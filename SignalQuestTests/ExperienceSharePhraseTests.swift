import XCTest
@testable import SignalQuest

/// Image de partage d'un test d'expérience (méthode v3, §10) : phrases rejouées à l'octet sur
/// les vecteurs communs, et rien ne se coupe dans la mise en page de la maquette.
final class ExperienceSharePhraseTests: XCTestCase {
    private func vectors() throws -> [[String: Any]] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "experience-share-phrases-v1-vectors", withExtension: "json")
            ?? bundle.url(forResource: "experience-share-phrases-v1-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, "experience-share-phrases-v1")
        return try XCTUnwrap(object["cases"] as? [[String: Any]])
    }

    func testSharedPhraseVectors() throws {
        let cases = try vectors()
        XCTAssertEqual(cases.count, 5)
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let tests = vector["tests"] as? [String: Any] ?? [:]
            let expected = try XCTUnwrap(vector["expected"] as? [String: [String: String]], name)
            for language in ExperienceShareLanguage.allCases {
                let phrases = try XCTUnwrap(expected[language.rawValue], name)
                for use in ExperienceSharePhrases.Use.allCases {
                    XCTAssertEqual(ExperienceSharePhrases.phrase(use, tests: tests, language: language), phrases[use.rawValue],
                                   "\(name) · \(language.rawValue) · \(use.rawValue)")
                }
            }
        }
    }

    func testNumbersUseTheContractSpaces() {
        XCTAssertEqual(ExperienceSharePhrases.duration(990, .fr), "990\u{00A0}ms")
        XCTAssertEqual(ExperienceSharePhrases.duration(1_250, .fr), "1,3\u{00A0}s")
        XCTAssertEqual(ExperienceSharePhrases.duration(12_449, .en), "12.4\u{00A0}s")
        XCTAssertEqual(ExperienceSharePhrases.duration(1_234_560, .fr), "1\u{202F}234,6\u{00A0}s")
        XCTAssertEqual(ExperienceSharePhrases.integer(1_000, .fr), "1\u{202F}000")
        XCTAssertEqual(ExperienceSharePhrases.integer(1_000, .en), "1,000")
    }

    func testUseStateAndVideoDetail() {
        let tests: [String: Any] = [
            "videoLadder": ["state": "measured", "rungs": [["quality": "720p", "state": "measured", "stalls": []]]],
            "videoAdaptive": ["state": "interrupted"],
            "webPage": ["state": "failed"],
        ]
        XCTAssertEqual(ExperienceSharePhrases.state(.video, tests: tests), "measured")
        XCTAssertEqual(ExperienceSharePhrases.state(.webPage, tests: tests), "failed")
        XCTAssertEqual(ExperienceSharePhrases.state(.upload, tests: tests), "not_tested")
        let scores = ExperienceScores(tests: tests)
        XCTAssertEqual(ExperienceSharePhrases.videoDetail(tests: tests, scores: scores, language: .fr), "Échelle 40 · Adaptative interrompue")
        XCTAssertEqual(ExperienceSharePhrases.videoDetail(tests: tests, scores: scores, language: .en), "Ladder 40 · Adaptive interrupted")
        let model = ExperienceShareCardBuilder.model(tests: tests, scores: scores, measuredAt: nil, network: nil, language: .fr)
        XCTAssertEqual(model.rows.map(\.phrase), ["Jusqu’en 720p sans coupure", "Échec du test", "Test non lancé", "Test non lancé"])
        XCTAssertNil(model.overall)
        XCTAssertEqual(model.overallNote, "Note globale à partir de 2 usages notés")
    }

    /// Réserve d'Alexandre : aucun résultat ne se coupe, même moyen ou faible. Chaque phrase
    /// tient en 2 lignes de 14 px dans sa colonne et fait 60 caractères au plus.
    func testWorstCasesHoldInTwoLines() throws {
        XCTAssertTrue(SQShareFonts.areEmbedded, "sans Sora, la mesure ne vaut rien")
        var phrases: [String] = []
        for vector in try vectors() {
            for language in ExperienceShareLanguage.allCases {
                let tests = vector["tests"] as? [String: Any] ?? [:]
                phrases += ExperienceSharePhrases.Use.allCases.map { ExperienceSharePhrases.phrase($0, tests: tests, language: language) }
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
            phrases += ExperienceSharePhrases.Use.allCases.map { ExperienceSharePhrases.phrase($0, tests: worst, language: language) }
            phrases += ["failed", "interrupted", "not_tested"].map { ExperienceSharePhrases.stateText($0, language) }
        }
        for phrase in phrases {
            XCTAssertLessThanOrEqual(phrase.count, 60, phrase)
            XCTAssertLessThanOrEqual(ExperienceShareCardRenderer.phraseLines(phrase).count, 2, phrase)
            XCTAssertFalse(phrase.contains("…"), phrase)
        }

        // La ligne de détail de la Vidéo ne passe pas à la ligne : elle tient dans la colonne.
        let columns = ExperienceShareCardRenderer.columns(width: 1_200)
        XCTAssertEqual(columns.phrase, 408.5, accuracy: 1, "≈ 409 de la maquette")
        let detailFont = SQShareFonts.display(size: 12, weight: 600)
        for detail in ["Échelle en échec · Adaptative interrompue", "Ladder interrupted · Adaptive interrupted"] {
            XCTAssertLessThanOrEqual((detail as NSString).size(withAttributes: [.font: detailFont]).width, columns.phrase, detail)
        }
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
