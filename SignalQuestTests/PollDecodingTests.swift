import XCTest
@testable import SignalQuest

/// Vérifie les correctifs sondage : (1) un `metadata` renvoyé en OBJET JSON (cas
/// de la réponse de création) est ré-encodé en chaîne JSON valide et reste
/// parsable ; (2) le parsing des options + votes correspond au format backend.
final class PollDecodingTests: XCTestCase {

    /// Format EXACT renvoyé par `/messages` (metadata = chaîne JSON).
    private let pollMetadataString = """
    {"poll":{"pollId":"p1","question":"Meilleur opérateur ?","options":[{"id":"opt_1","text":"Orange"},{"id":"opt_2","text":"SFR"},{"id":"opt_3","text":"Free"}],"multiSelect":false,"createdById":"u_a","createdAt":"2026-06-11T18:31:46.505Z","closedAt":null,"endsAt":null,"votes":{"u_a":["opt_2"]}}}
    """

    func testPollMetadataParsesOptionsAndVotes() throws {
        let meta = try XCTUnwrap(PollMetadata.parse(fromMetadataJSON: pollMetadataString))
        let poll = meta.toPoll(currentUserId: "u_a")
        XCTAssertEqual(poll.question, "Meilleur opérateur ?")
        XCTAssertEqual(poll.options.map(\.text), ["Orange", "SFR", "Free"])
        XCTAssertEqual(poll.totalVotes, 1)
        XCTAssertEqual(poll.options.first { $0.id == "opt_2" }?.count, 1)
        XCTAssertEqual(poll.votesByMe, ["opt_2"])
    }

    /// Régression du bug : `/polls` (création) renvoie `metadata` en OBJET. Le
    /// décodeur de `MessageItem` doit le ré-encoder en chaîne JSON parsable
    /// (et NON `String(describing:)`), sinon le sondage ne s'affiche pas.
    func testMessageMetadataObjectIsReencodedAsValidJSON() throws {
        let json = """
        {"id":"m1","kind":"TEXT","content":"📊 Sondage","metadata":{"poll":{"pollId":"p2","question":"Q ?","options":[{"id":"opt_1","text":"A"},{"id":"opt_2","text":"B"}],"multiSelect":false,"votes":{}}}}
        """
        let message = try JSONDecoder.signalQuest.decode(MessageItem.self, from: Data(json.utf8))
        let metadata = try XCTUnwrap(message.metadata, "metadata objet non décodé")
        // La chaîne doit être du JSON valide reparsable (pas une description Swift).
        let meta = try XCTUnwrap(PollMetadata.parse(fromMetadataJSON: metadata), "metadata objet non reparsable")
        let poll = meta.toPoll(currentUserId: nil)
        XCTAssertEqual(poll.options.map(\.text), ["A", "B"])
    }
}
