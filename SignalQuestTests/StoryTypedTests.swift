import XCTest
@testable import SignalQuest

/// Le serveur décide qu'une story est VIDE en inspectant la présence de
/// `attachRadio` / `metadata`. Un `false` explicite au lieu d'une absence fait
/// donc basculer la validation du mauvais côté — un défaut qui ne se voit qu'au
/// 400 renvoyé, sur une story sans texte ni image.
final class StoryTypedTests: XCTestCase {

    private func encoded(attachRadio: Bool?) throws -> [String: Any] {
        let body = CreateStoryRequest(
            text: nil, mediaUrl: nil, thumbnailUrl: nil, mediaKind: nil,
            durationSeconds: 10, visibility: "friends", ttlHours: 24,
            hiddenUserIds: nil, background: nil,
            attachRadio: attachRadio, metadata: nil
        )
        let data = try JSONEncoder().encode(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Une story « signal » doit envoyer la clé.
    func testAttachRadioIsSentWhenEnabled() throws {
        let json = try encoded(attachRadio: true)
        XCTAssertEqual(json["attachRadio"] as? Bool, true)
    }

    /// Et surtout : la clé doit être ABSENTE quand l'option est désactivée, pas
    /// présente à `false`.
    func testAttachRadioIsOmittedWhenDisabled() throws {
        let json = try encoded(attachRadio: nil)
        XCTAssertNil(json["attachRadio"], "Un `false` explicite fausserait la validation serveur")
    }

    /// Les durées de vie hors bornes doivent être ramenées dans 1…72 : le
    /// serveur répondrait 400 sinon.
    func testTtlIsClampedToTheServerRange() throws {
        for (input, expected) in [(0, 1), (1, 1), (24, 24), (72, 72), (999, 72)] {
            let body = CreateStoryRequest(
                text: "x", mediaUrl: nil, thumbnailUrl: nil, mediaKind: nil,
                durationSeconds: 10, visibility: "friends",
                ttlHours: min(72, max(1, input)),
                hiddenUserIds: nil, background: nil, attachRadio: nil, metadata: nil
            )
            XCTAssertEqual(body.ttlHours, expected, "ttl \(input)")
        }
    }
}
