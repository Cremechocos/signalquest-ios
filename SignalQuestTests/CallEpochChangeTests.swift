import XCTest
@testable import SignalQuest

/// IOS-CALL-2 (plan 3, jalon A) : un appel chiffré garde l'époque de son
/// descripteur et prend fin quand la conversation change de clé (spec §10.3).
final class CallEpochChangeTests: XCTestCase {
    private let conversationId = "conversation_1234567890123456"

    func testStoreAnnouncesOnlyANewerCurrentEpoch() throws {
        let store = E2EEV2EpochKeyStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        let recorder = AdvanceRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: E2EEV2EpochEvents.didAdvance, object: nil, queue: nil
        ) { note in
            if let advance = E2EEV2EpochEvents.advance(from: note) { recorder.append(advance) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(try put(store, epochNumber: 2))
        XCTAssertTrue(try put(store, epochNumber: 1), "Une époque plus ancienne rejoint l'historique")
        XCTAssertTrue(try put(store, epochNumber: 2), "La même époque, livrée deux fois")
        XCTAssertTrue(try put(store, epochNumber: 3))

        let advances = recorder.values.filter { $0.conversationId == conversationId }
        XCTAssertEqual(advances.map(\.epochNumber), [2, 3])
        XCTAssertEqual(Set(advances.map(\.ownerNamespace)), ["account-a"])
    }

    func testCallEndsOnlyWhenItsConversationMovesPastTheCallEpoch() {
        let advance = E2EEV2EpochEvents.Advance(
            conversationId: conversationId, epochNumber: 5, ownerNamespace: "account-a"
        )
        func ends(_ conversation: String? = nil, epoch: Int? = 4, encrypted: Bool = true) -> Bool {
            E2EEV2CallEpochPolicy.endsCall(
                conversationId: conversation ?? conversationId,
                callEpochNumber: epoch,
                requiresE2EE: encrypted,
                advance: advance
            )
        }
        XCTAssertTrue(ends())
        XCTAssertFalse(ends(epoch: 5), "L'époque de l'appel, annoncée de nouveau")
        XCTAssertFalse(ends(epoch: 6), "Une annonce en retard sur l'appel")
        XCTAssertFalse(ends("conversation_6543210987654321"), "Une autre conversation")
        XCTAssertFalse(ends(encrypted: false), "Un appel protégé pendant le transport seulement")
        XCTAssertFalse(ends(epoch: nil), "Une sonnerie pas encore rapprochée du serveur")
    }

    private func put(_ store: E2EEV2EpochKeyStore, epochNumber: Int) throws -> Bool {
        let key = Data(repeating: UInt8(epochNumber), count: 32)
        return try store.put(
            recordInput: .init(
                conversationId: conversationId,
                epochId: "epoch_00000000000000\(epochNumber)",
                epochNumber: epochNumber,
                keyCommitmentB64: E2EEV2EpochCrypto.keyCommitment(key)
            ),
            epochKey: key,
            ownerNamespace: "account-a"
        )
    }
}

private final class AdvanceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [E2EEV2EpochEvents.Advance] = []

    func append(_ advance: E2EEV2EpochEvents.Advance) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(advance)
    }

    var values: [E2EEV2EpochEvents.Advance] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
