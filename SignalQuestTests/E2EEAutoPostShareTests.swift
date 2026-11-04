import XCTest
@testable import SignalQuest

/// Carte d'une publication partagée dans une conversation v2 (E2EE-AUTO §7.7, `CARD` `POST`) :
/// l'instantané que l'app construit doit valoir la carte en clair du serveur, tenir les
/// bornes du contrat et se relire à l'identique.
final class E2EEAutoPostShareTests: XCTestCase {
    private func item(text: String = "Belle antenne", status: String = "active", _ extra: String = "") throws -> UnifiedSocialFeedItem {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let escaped = String(data: try JSONEncoder().encode(text), encoding: .utf8) ?? "\"\""
        return try decoder.decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"post-cmh1post00000000000000001","kind":"speedtest","sourceType":"post","sourceId":"cmh1post00000000000000001",
         "createdAt":"2026-09-20T08:15:00Z","author":{"id":"cmh1user00000000000000001","name":"Alice","handle":"@alice"},
         "text":\(escaped),"status":"\(status)",
         "commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false\(extra)}
        """.utf8))
    }

    private func reread(_ card: E2EEAutoMediaOutbox.Card) throws -> E2EEAutoContentR17.Body {
        let record = E2EEAutoMediaOutbox.Record(
            clientRequestId: "r", conversationId: "c", isGroup: false, participantIds: [], caption: nil, mentions: [],
            replyToRef: nil, ttlSeconds: 0, createdAtMs: 0, entries: [], voice: nil, card: card
        )
        let body = try XCTUnwrap(record.body)
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: 1, counter: 1, replyToRef: nil, mentions: [], body: .r17(body)).encoded()
        XCTAssertEqual(try E2EEV2ContentPayloadV2.parse(payload).body, .r17(body), "la charge se relit")
        return body
    }

    func testSpeedtestPostBecomesACardWithoutURL() throws {
        let card = try XCTUnwrap(E2EEAutoPostShare.card(try item(
            #","signal":{"type":"speedtest","downloadMbps":842.5,"uploadMbps":95.123,"pingMs":18,"technology":"5G","operator":"Free Mobile","detectedTechs":[],"mapPoints":[]}"#
        )))
        XCTAssertEqual(card.postId, "cmh1post00000000000000001")
        XCTAssertEqual(card.authorId, "cmh1user00000000000000001")
        XCTAssertEqual(card.authorHandle, "alice", "sans « @ »")
        XCTAssertEqual(card.postedAt, "2026-09-20T08:15:00.000Z")
        XCTAssertEqual(card.measure, .speedtest(downloadMbps: "842.5", uploadMbps: "95.12", pingMs: "18", technology: "5G", operator: "Free Mobile"))
        guard case .card(let post) = try reread(card) else { return XCTFail("CARD attendu") }
        XCTAssertNil(post.image)
        let shown = E2EEAutoPostShare.shareCardData(post)
        XCTAssertNil(shown.url)
        XCTAssertNil(shown.imageUrl)
        XCTAssertNil(shown.socialPostId, "jamais rechargée en direct du serveur")
        XCTAssertEqual(shown.speedtest?.downloadMbps, 842.5)
    }

    func testSessionAndSignalMeasures() throws {
        let session = try XCTUnwrap(E2EEAutoPostShare.card(try item(
            #","signal":{"type":"session","pointsCount":412,"distanceMeters":12345.6,"durationSeconds":1800.4,"detectedTechs":["4G","5G"],"mapPoints":[]}"#
        )))
        XCTAssertEqual(session.measure, .session(points: 412, distanceMeters: 12346, durationSeconds: 1800, technologies: ["4G", "5G"]))
        _ = try reread(session)
        let signal = try XCTUnwrap(E2EEAutoPostShare.card(try item(
            #","signal":{"type":"signal","rsrp":-97.4,"band":"n78","siteLabel":"Grenoble Bastille","operator":"Orange","technology":"5G","detectedTechs":[],"mapPoints":[]}"#
        )))
        XCTAssertEqual(signal.measure, .signal(rsrp: -97, band: "n78", site: "Grenoble Bastille", operator: "Orange", technology: "5G"))
        _ = try reread(signal)
        // Zone privée : le site n'est pas nommé, comme dans la carte en clair.
        let hidden = try XCTUnwrap(E2EEAutoPostShare.card(try item(
            #","signal":{"type":"signal","rsrp":-97,"siteLabel":"Chez moi","detailsHidden":true,"detectedTechs":[],"mapPoints":[]}"#
        )))
        XCTAssertEqual(hidden.measure, .signal(rsrp: -97, band: nil, site: nil, operator: nil, technology: nil))
    }

    func testTextIsCutAt280CharactersAndPrivatePostsAreNotShared() throws {
        let long = String(repeating: "é ", count: 400)
        let card = try XCTUnwrap(E2EEAutoPostShare.card(try item(text: long)))
        XCTAssertEqual(card.text?.count, E2EEAutoPostShare.maxTextCharacters - 1, "coupée sur une espace, puis rognée")
        let dense = try XCTUnwrap(E2EEAutoPostShare.card(try item(text: String(repeating: "é", count: 400))))
        XCTAssertEqual(dense.text?.count, E2EEAutoPostShare.maxTextCharacters)
        _ = try reread(card)
        XCTAssertNil(E2EEAutoPostShare.card(try item(#","metadata":{"authorOnlyReason":"private_zone"}"#)))
        XCTAssertNil(E2EEAutoPostShare.card(try item(status: "deleted")))
        XCTAssertNotNil(E2EEAutoPostShare.card(try item("")))
    }

    func testFixedTwoDecimals() {
        XCTAssertEqual(E2EEAutoPostShare.fixed2(842.5), "842.5")
        XCTAssertEqual(E2EEAutoPostShare.fixed2(842.0), "842")
        XCTAssertEqual(E2EEAutoPostShare.fixed2(0.004), "0")
        XCTAssertEqual(E2EEAutoPostShare.fixed2(1.006), "1.01")
        XCTAssertEqual(E2EEAutoPostShare.fixed2(12.07), "12.07")
        XCTAssertNil(E2EEAutoPostShare.fixed2(-1))
        XCTAssertNil(E2EEAutoPostShare.fixed2(.nan))
        XCTAssertNil(E2EEAutoPostShare.fixed2(10_000_000))
    }

    func testPreviewImageIsAJPEGWithinTheCardBounds() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2_400, height: 1_600), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }())
        // Bruit : la pire image pour le JPEG, qui doit quand même tenir sous 512 Kio.
        let image = renderer.image { context in
            var generator = SystemRandomNumberGenerator()
            for x in stride(from: 0, to: 2_400, by: 8) {
                for y in stride(from: 0, to: 1_600, by: 8) {
                    UIColor(white: CGFloat.random(in: 0...1, using: &generator), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        let source = try XCTUnwrap(E2EEAutoPostShare.preview(image))
        XCTAssertEqual(source.mimeType, "image/jpeg")
        XCTAssertLessThanOrEqual(source.data.count, Int(E2EEAutoContentR17.maxPostImageBytes))
        XCTAssertLessThanOrEqual(max(source.width ?? .max, source.height ?? .max), E2EEAutoContentR17.maxPreviewSide)
        XCTAssertNil(source.thumbnail)
    }
}
