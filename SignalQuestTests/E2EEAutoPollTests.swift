import XCTest
@testable import SignalQuest

/// Sondages chiffrés (E2EE-AUTO §7.7, lot P4) : création, puis décompte du fil à
/// partir des votes et clôtures reçus en annotations.
final class E2EEAutoPollTests: XCTestCase {
    private let alice = "user_alice_01J7ABCD23456789"
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let carla = "user_carla_01J7ABCD23456789"
    private let pollRef = String(repeating: "P", count: 42) + "A"

    func testNewPollUsesRandomIdsAndAMillisecondDeadline() throws {
        let deadline = Date(timeIntervalSince1970: 1_790_000_000.1234)
        let body = try XCTUnwrap(E2EEAutoContentR17.newPoll(
            question: "On se retrouve où ?", labels: ["Antenne", "Gare", "Mairie"], multipleChoice: true, closesAt: deadline
        ))
        guard case .poll(let question, let options, let multiple, let closesAt) = body else { return XCTFail("POLL attendu") }
        XCTAssertEqual(question, "On se retrouve où ?")
        XCTAssertTrue(multiple)
        XCTAssertEqual(options.map(\.label), ["Antenne", "Gare", "Mairie"])
        XCTAssertEqual(Set(options.map(\.id)).count, 3)
        XCTAssertTrue(options.allSatisfy { E2EEAutoContentR17.isOptionId($0.id) })
        XCTAssertEqual(closesAt, "2026-09-21T14:13:20.123Z")
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: 1, counter: 1, replyToRef: nil, mentions: [], body: .r17(body)).encoded()
        XCTAssertEqual(try E2EEV2ContentPayloadV2.parse(payload).body, .r17(body), "la charge se relit")
        // Bornes du contrat.
        XCTAssertNil(E2EEAutoContentR17.newPoll(question: "Q", labels: ["Seule"], multipleChoice: false, closesAt: nil))
        XCTAssertNil(E2EEAutoContentR17.newPoll(question: "Q", labels: (1...21).map(String.init), multipleChoice: false, closesAt: nil))
        XCTAssertNil(E2EEAutoContentR17.newPoll(question: "", labels: ["A", "B"], multipleChoice: false, closesAt: nil))
        XCTAssertNil(E2EEAutoContentR17.newPoll(question: "Q", labels: ["A", String(repeating: "é", count: 513)], multipleChoice: false, closesAt: nil))
        XCTAssertNotNil(E2EEAutoContentR17.newPoll(question: "Q", labels: (1...20).map(String.init), multipleChoice: false, closesAt: nil))
    }

    func testTwoPersonPollCountsVotesAndOnlyTheAuthorCloses() throws {
        let (poll, ids) = try makePoll(author: alice, multiple: false)
        let events = [
            try event(.pollVote(targetRef: pollRef, optionIds: [ids[0]]), from: bruno, sequence: 2),
            try event(.pollVote(targetRef: pollRef, optionIds: [ids[1]]), from: alice, sequence: 3),
            // Bruno n'est pas l'auteur et une conversation à deux n'a pas d'administrateur.
            try event(.pollClose(targetRef: pollRef), from: bruno, sequence: 4),
            try event(.pollVote(targetRef: pollRef, optionIds: [ids[1]]), from: bruno, sequence: 5),
        ]
        let open = try present(poll, events: events, own: alice, isGroup: false)
        XCTAssertNil(open.closedAt)
        XCTAssertEqual(open.options.map(\.count), [0, 2])
        XCTAssertEqual(open.totalVotes, 2)
        XCTAssertEqual(open.votesByMe, [ids[1]])
        XCTAssertEqual(open.createdById, alice)
        XCTAssertEqual(open.pollId, pollRef)
        // Clôture de l'autrice : retenue ; un vote après elle ne compte plus.
        let closed = try present(poll, events: [
            events[0], try event(.pollClose(targetRef: pollRef), from: alice, sequence: 3), events[3],
        ], own: bruno, isGroup: false)
        XCTAssertNotNil(closed.closedAt)
        XCTAssertEqual(closed.options.map(\.count), [1, 0])
        XCTAssertEqual(closed.votesByMe, [ids[0]])
    }

    func testGroupCloseFollowsTheAdminsOfItsEpoch() throws {
        let (poll, ids) = try makePoll(author: alice, multiple: true)
        let vote = try event(.pollVote(targetRef: pollRef, optionIds: ids), from: carla, sequence: 2)
        let close = try event(.pollClose(targetRef: pollRef), from: bruno, sequence: 3, epoch: 4)
        let byAdmin = try present(poll, events: [vote, close], own: carla, isGroup: true) { $0 == 4 ? [self.bruno] : [] }
        XCTAssertNotNil(byAdmin.closedAt, "admin à l'époque de la clôture")
        XCTAssertEqual(byAdmin.options.map(\.count), [1, 1])
        let undecidable = try present(poll, events: [vote, close], own: carla, isGroup: true) { _ in nil }
        XCTAssertNil(undecidable.closedAt, "chaîne locale en retard : la clôture attend")
        let notAdmin = try present(poll, events: [vote, close], own: carla, isGroup: true) { _ in [self.alice] }
        XCTAssertNil(notAdmin.closedAt)
    }

    // MARK: Aides

    private func makePoll(author: String, multiple: Bool) throws -> (E2EEV2MessageStoreV2.Stored, [String]) {
        let body = try XCTUnwrap(E2EEAutoContentR17.newPoll(
            question: "Quel opérateur ?", labels: ["Orange", "Free"], multipleChoice: multiple, closesAt: nil
        ))
        guard case .poll(_, let options, _, _) = body else { throw XCTSkip("POLL") }
        return (try stored(.r17(body), ref: pollRef, from: author, sequence: 1, epoch: 1), options.map(\.id))
    }

    private func event(_ body: E2EEAutoContentR17.Body, from sender: String, sequence: Int64, epoch: Int = 1) throws -> E2EEV2MessageStoreV2.Stored {
        try stored(.r17(body), ref: String(repeating: "E", count: 41) + String(sequence) + "A", from: sender, sequence: sequence, epoch: epoch)
    }

    private func stored(_ body: E2EEV2ContentPayloadV2.Body, ref: String, from sender: String, sequence: Int64, epoch: Int) throws -> E2EEV2MessageStoreV2.Stored {
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: 1_790_000_000_000, counter: sequence, replyToRef: nil, mentions: [], body: body).encoded()
        return E2EEV2MessageStoreV2.Stored(
            messageRef: ref, envelopeId: "env_\(sequence)", sequence: sequence, senderUserId: sender, senderDeviceId: "device_\(sender)",
            clientRequestId: "request_\(sequence)", epochNumber: epoch, serverTimeMs: 1_790_000_000_000 + sequence * 1_000,
            serverTagB64: "", keyId: "", frankTagB64: "", kind: body.kind, targetRef: nil, replyToRef: nil,
            sentAtMs: 1_790_000_000_000, expiresAtMs: nil, payloadB64: payload.base64EncodedString(), fkB64: nil,
            text: nil, editedAtMs: nil, deleted: false
        )
    }

    private func present(
        _ poll: E2EEV2MessageStoreV2.Stored, events: [E2EEV2MessageStoreV2.Stored], own: String, isGroup: Bool,
        admins: @escaping (Int) -> Set<String>? = { _ in nil }
    ) throws -> MessagePoll {
        let body = try XCTUnwrap(E2EEV2MessageStoreV2.r17Body(poll))
        return try XCTUnwrap(E2EEV2ThreadPresenter.poll(
            body, stored: poll, events: events, ownUserId: own, isGroup: isGroup, groupAdmins: admins, nowMs: 1_790_000_100_000
        ))
    }
}
