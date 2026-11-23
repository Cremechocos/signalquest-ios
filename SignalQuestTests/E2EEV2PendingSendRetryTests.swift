import Foundation
import XCTest
@testable import SignalQuest

/// Reprise automatique des textes chiffrés v2 (QA-066, règle d'Android).
@MainActor
final class E2EEV2PendingSendRetryTests: XCTestCase {
    private let owner = "user:" + String(repeating: "c", count: 64)

    private func failure(_ status: Int?, _ code: String? = nil, kind: E2EEV2TransportFailureKind? = nil) -> E2EEV2MessageSendResultV2 {
        let kind = kind ?? status.map { E2EEV2TransportFailurePolicy.classify(statusCode: $0, code: code) } ?? .retryable
        return .failure(E2EEV2TransportFailure(kind: kind, statusCode: status, code: code, message: "test"))
    }

    private func store() -> MessageDraftStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2EEV2PendingSendRetryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MessageDraftStore(rootURL: root, keyStore: InMemoryTokenStore())
    }

    private func pending(_ id: String, conversation: String = "conv-1", text: String? = nil, at ms: Int64) -> MessageDraftStore.PendingV2Send {
        .init(
            clientRequestId: id, conversationId: conversation, isGroup: false, participantIds: ["u1", "u2"],
            text: text ?? "Texte \(id)", replyToRef: nil, ttlSeconds: 0, createdAtMs: ms
        )
    }

    func testOnlyOutagesAreReplayedAndTheRequestLimitIsARefusal() {
        typealias D = E2EEV2PendingSendDisposition
        XCTAssertEqual(D(.alreadyAccepted(messageRef: "r")), .delivered)
        // Sans réponse : coupure, appareil verrouillé, inscription en cours.
        XCTAssertEqual(D(failure(nil, kind: .retryable)), .transient)
        XCTAssertEqual(D(failure(503)), .transient)
        XCTAssertEqual(D(failure(500)), .transient)
        XCTAssertEqual(D(failure(408)), .transient)
        XCTAssertEqual(D(failure(429)), .transient)
        XCTAssertEqual(D(failure(429, "RATE_LIMITED")), .transient)
        XCTAssertEqual(D(.needsEpoch), .transient)
        XCTAssertEqual(D(.needsRotation), .transient)
        // La limite quotidienne de demandes est aussi un 429 : elle ne se lève pas en réessayant.
        XCTAssertEqual(D(failure(429, MessageRequestLimitError.code)), .refused)
        XCTAssertEqual(D(failure(429, MessageRequestLimitError.code, kind: .retryable)), .refused)
        XCTAssertEqual(D(failure(403, MessageRequestLimitError.pendingCode)), .refused)
        XCTAssertEqual(D(failure(401)), .refused)
        // Cette app doit se mettre à jour : la bulle reste renvoyable, comme sur Android.
        XCTAssertEqual(D(failure(426, "E2EE_UPDATE_REQUIRED")), .awaitingUpdate)
        XCTAssertEqual(EncryptedConversationSurfaces.v2AwaitingUpdateReason(failure(426, "E2EE_UPDATE_REQUIRED")),
                       String(localized: "Mise à jour requise"))
        XCTAssertEqual(D(failure(403, "E2EE_V2_PREVIEW_REQUIRED")), .refused)
        XCTAssertEqual(D(failure(400, "E2EE_INVALID")), .refused)
        XCTAssertEqual(D(failure(nil, kind: .localState)), .refused)
        // Pendant une panne : annuaire des appareils illisible, liste périmée, synchronisation en attente.
        XCTAssertEqual(D(.failure(E2EEV2TransportFailure(kind: .retryable, message: "e2ee-v2-device-directory-unavailable"))), .transient)
        XCTAssertEqual(D(.failure(E2EEV2DeviceListReread.failure(["u2"]))), .transient)
        XCTAssertEqual(D(.failure(E2EEV2TransportFailure(kind: .localState, message: "e2ee-membership-behind"))), .transient)
        XCTAssertEqual(D(.failure(E2EEV2TransportFailure(kind: .localState, message: "e2ee-sync-state-unavailable"))), .refused)
        XCTAssertEqual(D(.membersNotTrusted(["u2"])), .refused)
        XCTAssertEqual(D(.capabilityMissing(["reactions"])), .awaitingUpdate)
        // L'avis de l'écran verrouillé suit la même règle.
        XCTAssertFalse(PushNotificationService.replyNeedsFailureNotice(failure(503)))
        XCTAssertTrue(PushNotificationService.replyNeedsFailureNotice(failure(429, MessageRequestLimitError.code)))
    }

    func testAPassStopsOnAnOutageAndHandsRefusalsBackToTheDraft() async throws {
        let store = store()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        for entry in [
            pending("old", at: nowMs - AppServices.pendingV2MaxAgeMs - 1),
            pending("a", at: nowMs - 6_000),
            pending("limit", conversation: "conv-2", text: "Salut !", at: nowMs - 5_000),
            pending("update", at: nowMs - 4_000),
            pending("held", at: nowMs - 3_500),
            pending("down", at: nowMs - 3_000),
            pending("after", at: nowMs - 2_000),
        ] { try await store.stageV2Send(entry, ownerScopeId: owner) }
        try await store.save("Déjà écrit", conversationId: "conv-2", ownerScopeId: owner)

        let scheduler = E2EEV2PendingSendScheduler { _ in false }
        // Un écran envoie ce texte lui-même : le passage le saute.
        XCTAssertTrue(scheduler.reserve("held"))
        let collected = Collected()
        let observer = NotificationCenter.default.addObserver(
            forName: E2EEV2PendingSendScheduler.didResolve, object: nil, queue: nil
        ) { note in
            if let resolution = note.object as? E2EEV2PendingSendScheduler.Resolution {
                MainActor.assumeIsolated { collected.items.append(resolution) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var sent: [String] = []
        let outcomes: [String: E2EEV2MessageSendResultV2] = [
            "a": .alreadyAccepted(messageRef: "ref-a"),
            "limit": failure(429, MessageRequestLimitError.code),
            "update": .capabilityMissing(["reactions"]),
            "down": failure(503),
        ]
        let transient = await AppServices.replayPendingV2Sends(
            store: store, ownerScopeId: owner, now: now, reservations: scheduler, isCurrent: { true }
        ) { entry in
            sent.append(entry.clientRequestId)
            return outcomes[entry.clientRequestId] ?? .alreadyAccepted(messageRef: "x")
        }

        XCTAssertTrue(transient)
        // La limite n'arrête rien ; la panne arrête le passage avant « after ».
        XCTAssertEqual(sent, ["a", "limit", "update", "down"])
        let left = await store.pendingV2Sends(ownerScopeId: owner)
        XCTAssertEqual(left.map(\.clientRequestId), ["update", "held", "down", "after"])
        XCTAssertNotNil(left.first?.failureReason)
        let draft = await store.text(conversationId: "conv-2", ownerScopeId: owner)
        XCTAssertEqual(draft, "Salut !\nDéjà écrit")
        let resolutions = collected.items
        XCTAssertEqual(resolutions.map(\.clientRequestId), ["a", "limit", "update"])
        XCTAssertEqual(resolutions.first?.outcome, .delivered)
        guard case .refused(let reason)? = resolutions.dropFirst().first?.outcome else {
            return XCTFail("limit doit être rendu à l'auteur")
        }
        XCTAssertFalse(reason.isEmpty)
        // Un message laissé « Non envoyé » n'est plus rejoué seul.
        scheduler.release("held")
        sent = []
        let again = await AppServices.replayPendingV2Sends(
            store: store, ownerScopeId: owner, now: now, reservations: scheduler, isCurrent: { true }
        ) { entry in
            sent.append(entry.clientRequestId)
            return .alreadyAccepted(messageRef: "x")
        }
        XCTAssertFalse(again)
        XCTAssertEqual(sent, ["held", "down", "after"])
    }

    func testTheRetryWaitsFifteenSecondsThenDoublesUpToFiveMinutes() async throws {
        let clock = Clock()
        let count = Counter()
        let scheduler = E2EEV2PendingSendScheduler(sleep: { clock.record($0) }) { _ in
            count.value += 1
            return count.value < 8
        }
        await scheduler.runNow()
        for _ in 0..<1_000 where count.value < 8 || scheduler.isArmed {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(count.value, 8)
        XCTAssertFalse(scheduler.isArmed)
        XCTAssertEqual(clock.recorded, [15, 30, 60, 120, 240, 300, 300].map { Duration.seconds($0) })
        XCTAssertEqual(scheduler.nextDelay, .seconds(15))
    }

    func testAnOutageSeenByTheScreenArmsTheFirstRetryOnce() async throws {
        let clock = Clock()
        let scheduler = E2EEV2PendingSendScheduler(sleep: { wait in
            clock.record(wait)
            try? await Task.sleep(for: .seconds(3_600))
        }) { _ in false }
        scheduler.scheduleRetry()
        scheduler.scheduleRetry()
        for _ in 0..<1_000 where clock.recorded.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(clock.recorded, [.seconds(15)])
        XCTAssertTrue(scheduler.isArmed)
        // Le retour du réseau n'attend pas : l'essai part tout de suite et désarme l'attente.
        await scheduler.runNow()
        XCTAssertFalse(scheduler.isArmed)
        XCTAssertEqual(scheduler.nextDelay, .seconds(15))
        XCTAssertEqual(clock.recorded, [.seconds(15)])
    }

    func testARefusedTextGoesAboveWhatWasAlreadyWritten() async throws {
        XCTAssertEqual(MessageDraftStore.merged("Salut", before: ""), "Salut")
        XCTAssertEqual(MessageDraftStore.merged("Salut", before: "  \n"), "Salut")
        XCTAssertEqual(MessageDraftStore.merged("Salut", before: "Ça va ?"), "Salut\nÇa va ?")
        let store = store()
        try await store.prependToDraft("Salut", conversationId: "c", ownerScopeId: owner)
        try await store.prependToDraft("   ", conversationId: "c", ownerScopeId: owner)
        try await store.prependToDraft("Tu es là ?", conversationId: "c", ownerScopeId: owner)
        let draft = await store.text(conversationId: "c", ownerScopeId: owner)
        XCTAssertEqual(draft, "Tu es là ?\nSalut")
    }

    @MainActor private final class Collected { var items: [E2EEV2PendingSendScheduler.Resolution] = [] }
    @MainActor private final class Counter { var value = 0 }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Duration] = []
        func record(_ wait: Duration) { lock.lock(); waits.append(wait); lock.unlock() }
        var recorded: [Duration] { lock.lock(); defer { lock.unlock() }; return waits }
    }
}
