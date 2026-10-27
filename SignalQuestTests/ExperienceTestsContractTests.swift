import XCTest
@testable import SignalQuest

/// Tests d'expérience v3 : les vecteurs du contrat `experience-tests-v1` (copie à
/// l'octet de `contracts/experience-tests/v1-highlights.json`, commit 52297c820).
final class ExperienceTestsContractTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let tests: [String: JSONValue]
            let expected: [String: JSONValue]
            let published: Bool
        }
        let contract: String
        let cases: [Case]
    }

    private func vectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/experience-tests/v1-highlights.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testHighlightsAndPublicationMatchEveryVector() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors.contract, "experience-tests-v1")
        XCTAssertEqual(vectors.cases.count, 5)
        for vector in vectors.cases {
            XCTAssertEqual(ExperienceHighlights(tests: vector.tests), ExperienceHighlights(served: vector.expected), vector.name)
            XCTAssertEqual(ExperienceHighlights.isPublishable(tests: vector.tests), vector.published, vector.name)
        }
    }

    /// Ce que visent les deux contre-épreuves du contrat : une médiane paire
    /// arrondie au plus proche (1931, 1251) ou une marche coupée retenue (1080p)
    /// s'écarteraient de ces valeurs.
    func testVectorsPinTheFloorMedianAndTheStallRule() throws {
        let first = try XCTUnwrap(try vectors().cases.first)
        let expected = ExperienceHighlights(served: first.expected)
        XCTAssertEqual(expected.pageMedianMs, 1930, "1800 et 2061 : moyenne 1930,5 arrondie à l'entier inférieur")
        XCTAssertEqual(expected.uploadPhotoMs, 1250, "1200 et 1301 : moyenne 1250,5 arrondie à l'entier inférieur")
        XCTAssertEqual(expected.videoMaxQuality, "720p", "1080p a une coupure")
        XCTAssertEqual(ExperienceHighlights.median([40, 41]), 40)
        XCTAssertEqual(ExperienceHighlights.median([900, 3000, 1500]), 1500)
        XCTAssertNil(ExperienceHighlights.median([]))
    }

    func testFeedPostReadsItsServedHighlights() throws {
        let item = try JSONDecoder().decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"e1","kind":"experience","sourceType":"experience_test","sourceId":"ckexp1","author":{"id":"u1"},
         "text":"Vidéo jusqu'à 1080p","generated":true,"commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false,
         "metadata":{"experience":{"experienceTestId":"ckexp1","connectionType":"cellular","technology":"5G",
           "operatorKey":"ORANGE","marketCode":"FR","highlights":{"videoMaxQuality":"1080p","videoScore":null,
           "pageMedianMs":2061,"gameMedianMs":null,"gameProbeMethod":"tcp_connect","uploadPhotoMs":null}}}}
        """.utf8))
        let experience = try XCTUnwrap(FeedExperience(item: item))
        XCTAssertEqual(experience.testId, "ckexp1")
        XCTAssertEqual(experience.networkContext, "Orange · 5G")
        XCTAssertEqual(experience.highlights.feedMetrics.map(\.label), ["Vidéo sans coupure", "Page web"])
        XCTAssertNil(experience.highlights.gameProbeMethod, "no method without a game value")
        XCTAssertNil(experience.highlights.gameMethodNote)
        XCTAssertNil(item.cardText, "the French fallback text stays hidden")
        XCTAssertNil(FeedActivity(item: item))
    }

    func testDetailReadsTheWrappedResponseAndItsStates() throws {
        struct Response: Decodable { let experienceTest: ExperienceTestDetail? }
        let response = try JSONDecoder().decode(Response.self, from: Data("""
        {"experienceTest":{"id":"ckexp1","platform":"web","network":{"connectionType":"wifi"},
          "tests":{"upload":{"state":"failed"},"webPage":{"state":"measured","openings":[{"state":"measured","totalMs":900}]}},
          "highlights":{"videoMaxQuality":null,"videoScore":null,"pageMedianMs":900,"gameMedianMs":null,
            "gameProbeMethod":null,"uploadPhotoMs":null},"post":{"id":"p1","visibility":"friends"}},"requestId":"r1"}
        """.utf8))
        let detail = try XCTUnwrap(response.experienceTest)
        XCTAssertEqual(detail.highlights.pageMedianMs, 900)
        XCTAssertNil(detail.location)
        XCTAssertEqual(detail.states.map(\.test), [.webPage, .upload])
        XCTAssertEqual(detail.states.map(\.state), ["measured", "failed"])
    }

    func testWaitingTimeSwitchesToSecondsAboveOneSecond() {
        XCTAssertEqual(ExperienceHighlights.waitingTime(850), "850 ms")
        XCTAssertTrue(ExperienceHighlights.waitingTime(2061).hasSuffix(" s"))
    }

    func testWaitingTimeRoundsHalfUpLikeTheShareImage() {
        // Méthode §10 : d = (ms + 50) ÷ 100, en entiers ; un arrondi au pair donnerait 1,2 s.
        let decimal = Locale.current.decimalSeparator ?? ","
        XCTAssertEqual(ExperienceHighlights.waitingTime(1_250), "1\(decimal)3 s")
        XCTAssertEqual(ExperienceHighlights.waitingTime(12_449), "12\(decimal)4 s")
        XCTAssertEqual(ExperienceHighlights.waitingTime(9_960), "10\(decimal)0 s")
        XCTAssertEqual(ExperienceHighlights.waitingTime(990), "990 ms")
    }
}
