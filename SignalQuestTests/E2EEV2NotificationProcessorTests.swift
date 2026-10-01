import CryptoKit
import Security
import SwiftUI
import XCTest
@testable import SignalQuest

final class E2EEV2NotificationProcessorTests: XCTestCase {
    private let envelopeId = "envelope_notification_fixture_01"
    private let conversationId = "conversation_notification_fixture"
    private let senderId = "sender_notification_fixture_01"
    private let senderDeviceId = "device_sender_notification_fixture"
    private let recipientDeviceId = "device_recipient_notification_fixture"
    private let recipientId = "recipient_notification_fixture_01"
    private let owner = "user:" + String(repeating: "a", count: 64)
    private let now = Date(timeIntervalSince1970: 1_787_832_000)

    private struct Fixture: Sendable {
        let context: E2EEV2NotificationContext
        let conversation: E2EEV2NotificationConversation
        let descriptor: E2EEV2DeviceDescriptor
        let data: Data
        let now: Date
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class AccountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: E2EEV2NotificationAccountSnapshot?
        init(_ value: E2EEV2NotificationAccountSnapshot?) { self.value = value }
        func get() -> E2EEV2NotificationAccountSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: E2EEV2NotificationAccountSnapshot?) { lock.lock(); self.value = value; lock.unlock() }
    }

    private enum StorageFailure: Error { case unavailable }
    private final class FailingTokenStore: TokenStore, @unchecked Sendable {
        let memory = InMemoryTokenStore()
        let reads = Counter()
        var failRemoval = false
        var failWrite = false
        var failReadPrefix: String?
        func string(for key: String) throws -> String? {
            reads.increment()
            if let failReadPrefix, key.hasPrefix(failReadPrefix) { throw StorageFailure.unavailable }
            return try memory.string(for: key)
        }
        func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
            if failWrite { throw StorageFailure.unavailable }
            try memory.set(value, for: key, accessibility: accessibility)
        }
        func remove(_ key: String) throws {
            if failRemoval { throw StorageFailure.unavailable }
            try memory.remove(key)
        }
        func keys(withPrefix prefix: String) throws -> [String] { try memory.keys(withPrefix: prefix) }
        func removeAll() throws {
            if failRemoval { throw StorageFailure.unavailable }
            try memory.removeAll()
        }
    }

    private final class FailingActivationStore: E2EEV2NotificationActivationStoring, @unchecked Sendable {
        let memory = E2EEV2NotificationMemoryActivationStore()
        var failRevocation = false
        func revision() throws -> String? { memory.revision() }
        func activate(revision: String) throws { memory.activate(revision: revision) }
        func revoke() throws {
            if failRevocation { throw StorageFailure.unavailable }
            memory.revoke()
        }
    }

    /// Appelle `beforeEntryWrite` une fois, juste avant d'écrire une entrée.
    private final class InterceptingTokenStore: TokenStore, @unchecked Sendable {
        private let memory = InMemoryTokenStore()
        var beforeEntryWrite: (() -> Void)?
        func string(for key: String) throws -> String? { try memory.string(for: key) }
        func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
            if key.hasPrefix("notification-conversation-v1:"), let hook = beforeEntryWrite {
                beforeEntryWrite = nil
                hook()
            }
            try memory.set(value, for: key, accessibility: accessibility)
        }
        func remove(_ key: String) throws { try memory.remove(key) }
        func keys(withPrefix prefix: String) throws -> [String] { try memory.keys(withPrefix: prefix) }
        func removeAll() throws { try memory.removeAll() }
    }

    func testRuntimeGatePrecedesContextKeysAndNetwork() async throws {
        let calls = Counter()
        let request = try XCTUnwrap(E2EEV2OpaqueNotificationRequest(envelopeId: envelopeId, recipientOwnerScope: owner))
        let result = await E2EEV2NotificationProcessor.processRuntime(
            request: request,
            apiBaseURL: URL(string: "https://api.example.test")!,
            dependencies: .init(
                loadContext: { calls.increment(); return nil },
                isCurrent: { _ in calls.increment(); return false },
                loadConversation: { _ in calls.increment(); return nil },
                claimShown: { _, _, _, _ in calls.increment(); return false },
                fetch: { _ in calls.increment(); return Data() }
            )
        )
        XCTAssertEqual(result, .generic(.activationBlocked))
        XCTAssertEqual(calls.count, 0)
    }

    func testUnsignedFetchAndVerifiedMessageProduceLocalPreview() async throws {
        let fixture = try fixture()
        let store = try store(fixture)
        let result = await process(fixture, store: store) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/api/e2ee/v2/envelopes/envelope_notification_fixture_01/fetch")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: E2EEV2ProtocolWire.protocolVersionHeader), "2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=fixture.jwt.signature")
            XCTAssertNil(request.value(forHTTPHeaderField: E2EEV2SignedRequest.headerSignature), "Aucune clé d'appareil pour signer (§2.6)")
            return fixture.data
        }
        guard case .preview(let preview) = result else { return XCTFail("Expected verified local preview: \(result)") }
        XCTAssertEqual(preview.presentation.title, "Test Sender")
        XCTAssertEqual(preview.presentation.body, "Contenu privé de test")
        XCTAssertEqual(preview.conversationId, conversationId)
        XCTAssertEqual(preview.contextRevisionId, fixture.context.revisionId)
    }

    func testMirrorHoldsNoDevicePrivateKey() throws {
        let fixture = try fixture()
        let context = String(decoding: try JSONEncoder().encode(fixture.context), as: UTF8.self)
        let entry = String(decoding: try JSONEncoder().encode(fixture.conversation), as: UTF8.self)
        for text in [context, entry] {
            XCTAssertFalse(text.lowercased().contains("private"), text)
        }
        let recipientIdentity = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let recipientSigning = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        for secret in [recipientIdentity.rawRepresentation, recipientSigning.rawRepresentation] {
            XCTAssertFalse(context.contains(secret.base64EncodedString()) || entry.contains(secret.base64EncodedString()))
        }
    }

    func testUnknownConversationUncertifiedSenderOrOldEpochStaysGeneric() async throws {
        let base = try self.fixture()
        let empty = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try empty.saveContractPreview(base.context, now: now)
        let unknown = await process(base, store: empty) { _ in base.data }
        XCTAssertEqual(unknown, .generic(.contextUnavailable), "Conversation sans entrée : rien à déchiffrer")

        let stranger = try self.fixture()
        let strangerStore = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try strangerStore.saveContractPreview(stranger.context, now: now)
        try strangerStore.saveConversationContractPreview(entry(stranger.conversation,
            signingKeys: [E2EEV2NotificationConversation.signingKeyName(userId: senderId, deviceId: senderDeviceId):
                P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()]
        ), now: now)
        let forged = await process(stranger, store: strangerStore) { _ in stranger.data }
        XCTAssertEqual(forged, .generic(.invalidDelivery), "Signature d'une autre clé que la certifiée")

        let outsider = try self.fixture()
        let outsiderStore = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try outsiderStore.saveContractPreview(outsider.context, now: now)
        try outsiderStore.saveConversationContractPreview(entry(outsider.conversation,
            epochs: outsider.conversation.epochs.map { .init(epochNumber: $0.epochNumber, keyB64: $0.keyB64, memberIds: [recipientId], replacedAtMs: $0.replacedAtMs) }
        ), now: now)
        let notMember = await process(outsider, store: outsiderStore) { _ in outsider.data }
        XCTAssertEqual(notMember, .generic(.invalidDelivery), "L'émetteur n'est pas membre de l'époque")

        let old = try self.fixture(replacedAt: now.addingTimeInterval(-25 * 3_600))
        let oldStore = try store(old)
        let late = await process(old, store: oldStore) { _ in old.data }
        XCTAssertEqual(late, .generic(.invalidDelivery), "Époque remplacée depuis plus de 24 heures")
    }

    func testConversationEntriesNeedAnActiveContextAndDieWithRevocation() throws {
        let fixture = try fixture(), memory = InMemoryTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: memory)
        XCTAssertThrowsError(try store.saveConversationContractPreview(fixture.conversation, now: now), "Pas de contexte, pas d'entrée")
        XCTAssertFalse(try store.saveConversationRuntime(fixture.conversation, now: now), "Verrou fermé : rien n'est écrit")
        try store.saveContractPreview(fixture.context, now: now)
        try store.saveConversationContractPreview(fixture.conversation, now: now)
        XCTAssertEqual(try store.conversation(conversationId, now: now), fixture.conversation)
        try memory.set("{}", for: "active-notification-context-v1", accessibility: .afterFirstUnlock)
        try store.revoke()
        XCTAssertNil(try store.conversation(conversationId, now: now))
        XCTAssertTrue(try memory.keys(withPrefix: "").isEmpty, "Contexte, entrées et ancien contexte v1 effacés")
    }

    func testWrongAccountNeverFetches() async throws {
        let fixture = try fixture(), store = try store(fixture), calls = Counter()
        let request = try XCTUnwrap(E2EEV2OpaqueNotificationRequest(
            envelopeId: envelopeId, recipientOwnerScope: "user:" + String(repeating: "b", count: 64)
        ))
        let result = await E2EEV2NotificationProcessor.processContractPreview(
            request: request, apiBaseURL: URL(string: "https://api.example.test")!,
            dependencies: .init(
                loadContext: { try store.load(now: fixture.now) },
                isCurrent: { try store.isCurrent($0, now: fixture.now) },
                loadConversation: { try store.conversation($0, now: fixture.now) },
                claimShown: { try store.claimShown(conversationId: $0, deviceId: $1, counter: $2, floor: $3, now: fixture.now) },
                fetch: { _ in calls.increment(); return fixture.data },
                now: { fixture.now }
            )
        )
        XCTAssertEqual(result, .generic(.wrongAccount))
        XCTAssertEqual(calls.count, 0)
    }

    func testRevocationWhileFetchingNeverReturnsClearPreview() async throws {
        let fixture = try fixture(), store = try store(fixture)
        let result = await process(fixture, store: store) { _ in
            try store.revoke()
            return fixture.data
        }
        XCTAssertEqual(result, .generic(.staleContext))
    }

    func testSenderOnlyDoesNotExposeText() async throws {
        let fixture = try fixture(privacy: .senderOnly), store = try store(fixture)
        let result = await process(fixture, store: store) { _ in fixture.data }
        guard case .preview(let preview) = result else { return XCTFail("Expected sender-only preview") }
        XCTAssertEqual(preview.presentation.title, "Test Sender")
        XCTAssertEqual(preview.presentation.body, String(localized: "Nouveau message chiffré"))
        XCTAssertFalse(preview.presentation.body.contains("Contenu privé"))
    }

    func testExpiredMessageStaysGeneric() async throws {
        let fixture = try fixture(createdAt: now.addingTimeInterval(-120), ttlSeconds: 60), store = try store(fixture)
        let result = await process(fixture, store: store) { _ in fixture.data }
        XCTAssertEqual(result, .generic(.expired))
    }

    func testTamperedCiphertextIsNeverDisplayed() async throws {
        let fixture = try fixture(), store = try store(fixture)
        let text = String(decoding: fixture.data, as: UTF8.self)
        let marker = #""ciphertextB64":""#
        let start = try XCTUnwrap(text.range(of: marker)).upperBound
        let end = try XCTUnwrap(text[start...].firstIndex(of: "\""))
        var ciphertext = try XCTUnwrap(Data(base64Encoded: String(text[start..<end])))
        ciphertext[0] ^= 0x01
        let tampered = Data(text.replacingCharacters(in: start..<end, with: ciphertext.base64EncodedString()).utf8)
        let result = await process(fixture, store: store) { _ in tampered }
        XCTAssertEqual(result, .generic(.invalidDelivery))
    }

    func testOversizedResponseIsRejectedBeforeParsing() async throws {
        let fixture = try fixture(), store = try store(fixture)
        let result = await process(fixture, store: store) { _ in
            Data(repeating: 32, count: E2EEV2WireLimits.maxJSONResponseBytes + 1)
        }
        XCTAssertEqual(result, .generic(.invalidDelivery))
    }

    // MARK: Jamais deux fois, jamais trop vieux, jamais pour un autre (§2.6, §3.4, §4.2)

    func testTheSameSignedMessageIsShownOnlyOnce() async throws {
        let fixture = try fixture(), store = try store(fixture)
        let first = await process(fixture, store: store) { _ in fixture.data }
        guard case .preview = first else { return XCTFail("Premier affichage : \(first)") }
        // Le serveur le remet sous un autre identifiant, qui n'est pas signé.
        let otherId = "envelope_notification_fixture_02"
        let replayed = Data(String(decoding: fixture.data, as: UTF8.self).replacingOccurrences(of: envelopeId, with: otherId).utf8)
        let second = await process(fixture, store: store, envelopeId: otherId) { _ in replayed }
        XCTAssertEqual(second, .generic(.replayed))
    }

    func testWhatTheExtensionShowedSurvivesTheAppsRewrite() async throws {
        let fixture = try fixture(), store = try store(fixture)
        guard case .preview = await process(fixture, store: store, fetch: { _ in fixture.data }) else {
            return XCTFail("Premier affichage")
        }
        // L'app retire puis réécrit l'entrée sans avoir reçu ce message.
        try store.removeConversation(conversationId)
        try store.saveConversationContractPreview(fixture.conversation, now: now)
        let otherId = "envelope_notification_fixture_03"
        let replayed = Data(String(decoding: fixture.data, as: UTF8.self).replacingOccurrences(of: envelopeId, with: otherId).utf8)
        let again = await process(fixture, store: store, envelopeId: otherId) { _ in replayed }
        XCTAssertEqual(again, .generic(.replayed))
    }

    func testTwoSimultaneousDeliveriesShowOnce() async throws {
        let fixture = try fixture(), store = try store(fixture)
        let owner = self.owner, otherId = "envelope_notification_fixture_04"
        let copy = Data(String(decoding: fixture.data, as: UTF8.self).replacingOccurrences(of: envelopeId, with: otherId).utf8)
        let deliveries = [(envelopeId, fixture.data), (otherId, copy)]
        let results = await withTaskGroup(of: E2EEV2NotificationProcessingResult.self) { group in
            for (id, data) in deliveries {
                group.addTask {
                    await E2EEV2NotificationProcessor.processContractPreview(
                        request: E2EEV2OpaqueNotificationRequest(envelopeId: id, recipientOwnerScope: owner)!,
                        apiBaseURL: URL(string: "https://api.example.test")!,
                        dependencies: .init(
                            loadContext: { try store.load(now: fixture.now) },
                            isCurrent: { try store.isCurrent($0, now: fixture.now) },
                            loadConversation: { try store.conversation($0, now: fixture.now) },
                            claimShown: {
                                try store.claimShown(conversationId: $0, deviceId: $1, counter: $2, floor: $3, now: fixture.now)
                            },
                            fetch: { _ in
                                try await Task.sleep(nanoseconds: 20_000_000)
                                return data
                            },
                            now: { fixture.now }
                        )
                    )
                }
            }
            var all: [E2EEV2NotificationProcessingResult] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results.filter { if case .preview = $0 { return true } else { return false } }.count, 1)
        XCTAssertTrue(results.contains(.generic(.replayed)))
    }

    func testAnUnreadableShownRecordKeepsTheNotificationGeneric() async throws {
        let fixture = try fixture(), tokens = FailingTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: tokens)
        try store.saveContractPreview(fixture.context, now: now)
        try store.saveConversationContractPreview(fixture.conversation, now: now)
        tokens.failReadPrefix = "notification-shown-v1:"
        let result = await process(fixture, store: store) { _ in fixture.data }
        guard case .generic = result else { return XCTFail("Lecture en échec : rien de montré, \(result)") }
    }

    func testAMessageTheAppAlreadyReceivedIsNeverShown() async throws {
        let base = try fixture()
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try store.saveContractPreview(base.context, now: now)
        try store.saveConversationContractPreview(entry(base.conversation, counters: [senderDeviceId: 1]), now: now)
        let result = await process(base, store: store) { _ in base.data }
        XCTAssertEqual(result, .generic(.replayed), "Compteur déjà reçu par l'app")
    }

    func testTheAnnouncedConversationMustBeTheSignedOne() async throws {
        let fixture = try fixture(conversation: "conversation_notification_other"), store = try store(fixture)
        let result = await process(fixture, store: store) { _ in fixture.data }
        XCTAssertEqual(result, .generic(.invalidDelivery), "Signé pour une autre conversation que celle annoncée")
    }

    func testADepartedMemberIsShownForTwentyFourHoursOnly() async throws {
        let base = try fixture()
        let cases: [(TimeInterval?, Bool)] = [(nil, false), (3_600, true), (25 * 3_600, false)]
        for (departedAgo, shown) in cases {
            let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
            try store.saveContractPreview(base.context, now: now)
            try store.saveConversationContractPreview(entry(
                base.conversation, latestMemberIds: [recipientId],
                departures: departedAgo.map { [senderId: ms(now.addingTimeInterval(-$0))] } ?? [:]
            ), now: now)
            let result = await process(base, store: store) { _ in base.data }
            if shown {
                guard case .preview = result else { return XCTFail("Parti depuis une heure : \(result)") }
            } else {
                XCTAssertEqual(result, .generic(.invalidDelivery), "Départ : \(String(describing: departedAgo))")
            }
        }
    }

    func testAMessageSignedTooLongAgoOrInTheFutureStaysGeneric() async throws {
        for created in [now.addingTimeInterval(-49 * 3_600), now.addingTimeInterval(20 * 60)] {
            let fixture = try fixture(createdAt: created), store = try store(fixture)
            let result = await process(fixture, store: store) { _ in fixture.data }
            XCTAssertEqual(result, .generic(.outdated), "Signé le \(created)")
        }
    }

    func testEphemeralEditAndDeletePreviewsNeverShowTheirText() async throws {
        let target = E2EEV2MessageRef.make(
            conversationId: conversationId, senderDeviceId: senderDeviceId, clientRequestId: "request_notification_target"
        )
        let cases: [(Int, E2EEV2ContentPayloadV2.Body, String)] = [
            (60, .text("Contenu privé de test"), String(localized: "Message éphémère chiffré")),
            (0, .edit(targetRef: target, text: "Texte privé modifié"), String(localized: "Message chiffré modifié")),
            (0, .delete(targetRef: target), String(localized: "Message chiffré supprimé")),
        ]
        for (ttl, body, expected) in cases {
            let fixture = try fixture(ttlSeconds: ttl, body: body), store = try store(fixture)
            let result = await process(fixture, store: store) { _ in fixture.data }
            guard case .preview(let preview) = result else { return XCTFail("Aperçu : \(result)") }
            XCTAssertEqual(preview.presentation.body, expected)
            XCTAssertFalse(preview.presentation.body.contains("privé"))
        }
    }

    func testSenderOnlyMirrorsNoEpochKey() throws {
        let keyed = try fixture(), senderOnly = try fixture(privacy: .senderOnly)
        XCTAssertTrue(senderOnly.conversation.epochs.allSatisfy { $0.keyB64 == nil })
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try store.saveContractPreview(senderOnly.context, now: now)
        XCTAssertThrowsError(try store.saveConversationContractPreview(keyed.conversation, now: now),
                             "Aucune clé d'époque sans l'aperçu complet")
        try store.saveConversationContractPreview(senderOnly.conversation, now: now)
        let full = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try full.saveContractPreview(keyed.context, now: now)
        XCTAssertThrowsError(try full.saveConversationContractPreview(senderOnly.conversation, now: now),
                             "Aperçu complet : toutes les clés")
    }

    func testAnOldEntryIsNotUsedAndLeaves() async throws {
        let base = try fixture(), memory = InMemoryTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: memory)
        try store.saveContractPreview(base.context, now: now)
        try store.saveConversationContractPreview(entry(base.conversation, writtenAtMs: ms(now.addingTimeInterval(-25 * 3_600))), now: now)
        let result = await process(base, store: store) { _ in base.data }
        XCTAssertEqual(result, .generic(.contextUnavailable), "Écrite il y a plus de 24 heures")
        XCTAssertTrue(try memory.keys(withPrefix: "notification-conversation-v1:").isEmpty, "Croisée trop vieille, elle part")
    }

    func testTheCurrentEpochMustBeTheMostRecent() throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.conversation.isStructurallyValid)
        let older = entry(fixture.conversation, epochs: fixture.conversation.epochs.map {
            .init(epochNumber: $0.replacedAtMs == nil ? 6 : $0.epochNumber, keyB64: $0.keyB64,
                  memberIds: $0.memberIds, replacedAtMs: $0.replacedAtMs)
        })
        XCTAssertFalse(older.isStructurallyValid)
    }

    func testAnEntryOfAnotherSessionIsUnreadable() throws {
        let fixture = try fixture(), memory = InMemoryTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: memory)
        try store.saveContractPreview(fixture.context, now: now)
        let foreign = entry(fixture.conversation, sessionId: "00000000-0000-4000-8000-0000000000ff")
        XCTAssertThrowsError(try store.saveConversationContractPreview(foreign, now: now))
        let key = "notification-conversation-v1:" + SHA256.hash(data: Data(conversationId.utf8)).map { String(format: "%02x", $0) }.joined()
        try memory.set(String(decoding: try JSONEncoder().encode(foreign), as: UTF8.self), for: key, accessibility: .afterFirstUnlock)
        XCTAssertNil(try store.conversation(conversationId, now: now))
    }

    func testEntriesLeftByAPreviousSessionNeverComeBack() throws {
        let fixture = try fixture(), tokens = FailingTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: tokens)
        try store.saveContractPreview(fixture.context, now: now)
        try store.saveConversationContractPreview(fixture.conversation, now: now)
        // Déconnexion : le marqueur est révoqué, mais rien ne s'efface du trousseau.
        tokens.failRemoval = true
        try store.revoke()
        XCTAssertFalse(try tokens.keys(withPrefix: "notification-conversation-v1:").isEmpty, "L'entrée est restée")
        let next = E2EEV2NotificationContext(
            version: E2EEV2NotificationContext.currentVersion, revisionId: "00000000-0000-4000-8000-000000000003",
            ownerScopeId: "user:" + String(repeating: "b", count: 64), sessionId: "00000000-0000-4000-8000-000000000004",
            authToken: "other.jwt.signature", expiresAtMs: fixture.context.expiresAtMs,
            deviceId: "device_other_notification_fixture", privacy: .full, senderNames: [:]
        )
        // Un autre compte active ses aperçus : rien ne s'active tant qu'elle reste,
        XCTAssertThrowsError(try store.saveContractPreview(next, now: now))
        XCTAssertNil(try store.load(now: now))
        // puis elle part avant l'activation.
        tokens.failRemoval = false
        try store.saveContractPreview(next, now: now)
        XCTAssertTrue(try tokens.keys(withPrefix: "notification-conversation-v1:").isEmpty)
        XCTAssertNil(try store.conversation(conversationId, now: now))
    }

    func testARevocationDuringTheWriteTakesTheEntryAway() throws {
        let fixture = try fixture(), tokens = InterceptingTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: tokens)
        try store.saveContractPreview(fixture.context, now: now)
        tokens.beforeEntryWrite = { try? store.revoke() }
        XCTAssertThrowsError(try store.saveConversationContractPreview(fixture.conversation, now: now))
        XCTAssertTrue(try tokens.keys(withPrefix: "notification-conversation-v1:").isEmpty,
                      "Écrite après la révocation, l'entrée repart aussitôt")
    }

    func testExtensionNotificationsAreClearedWithTheAppOnes() {
        XCTAssertTrue(E2EEV2NotificationScope.isEncryptedNotification(identifier: "e2ee-v2:owner:session:envelope", userInfo: [:]))
        XCTAssertTrue(E2EEV2NotificationScope.isEncryptedNotification(
            identifier: "6F2A1C3E-APNS", userInfo: ["type": "e2ee_v2_envelope", "envelopeId": envelopeId]
        ), "Posée par l'extension sous l'identifiant APNs")
        XCTAssertFalse(E2EEV2NotificationScope.isEncryptedNotification(identifier: "6F2A1C3E-APNS", userInfo: ["type": "message_new"]))
    }

    func testTheNetworkReadAcceptsOnlyABoundedAnswerAtTheExactAddress() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.test/api/e2ee/v2/envelopes/\(envelopeId)/fetch"))
        let request = URLRequest(url: url)
        defer { MockURLProtocol.requestHandler = nil }
        func answer(status: Int = 200, at address: URL? = nil, body: Data = Data("{}".utf8)) async -> Data? {
            MockURLProtocol.requestHandler = { _ in
                (HTTPURLResponse(url: address ?? url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, body)
            }
            return try? await E2EEV2NotificationNetwork.fetch(request, protocolClasses: [MockURLProtocol.self])
        }
        let ok = await answer()
        XCTAssertEqual(ok, Data("{}".utf8))
        let refused = await answer(status: 503)
        XCTAssertNil(refused, "Seul un 200")
        let elsewhere = await answer(at: URL(string: "https://api.example.test/api/e2ee/v2/envelopes/other/fetch"))
        XCTAssertNil(elsewhere, "Seulement à l'adresse demandée")
        let oversized = await answer(body: Data(repeating: 32, count: E2EEV2WireLimits.maxJSONResponseBytes + 1))
        XCTAssertNil(oversized, "Jamais plus de 512 Kio")
    }

    func testNotificationMirrorIsDormantAndRevocable() throws {
        let fixture = try fixture(), memory = InMemoryTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: memory)
        XCTAssertFalse(try store.saveRuntime(fixture.context, now: now))
        XCTAssertFalse(try store.saveConversationRuntime(fixture.conversation, now: now))
        XCTAssertTrue(try memory.keys(withPrefix: "").isEmpty)
        try store.saveContractPreview(fixture.context, now: now)
        XCTAssertEqual(try store.load(now: now), fixture.context)
        XCTAssertTrue(try store.isCurrent(fixture.context, now: now))
        try store.revoke()
        XCTAssertNil(try store.load(now: now))
    }

    func testSharedAccessDoesNotBecomeTheAppsDefaultKeychainGroup() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("SignalQuestApp/SignalQuest.entitlements"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let groups = try XCTUnwrap(plist["keychain-access-groups"] as? [String])
        XCTAssertEqual(groups.first, "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)")
        XCTAssertEqual(groups.last, "$(AppIdentifierPrefix)$(SQ_NOTIFICATION_KEYCHAIN_GROUP)")
        let widget = try String(contentsOf: repository.appendingPathComponent("SignalQuestWidget/SignalQuestWidget.entitlements"))
        XCTAssertFalse(widget.contains("SQ_NOTIFICATION_KEYCHAIN_GROUP"))
    }

    func testServiceExtensionAlertDoesNotUseLegacyLocalNotificationPath() {
        XCTAssertTrue(E2EEV2NotificationDeliveryPolicy.usesServiceExtension([
            "type": "e2ee_v2_envelope", "aps": ["mutable-content": 1],
        ]))
        XCTAssertFalse(E2EEV2NotificationDeliveryPolicy.usesServiceExtension([
            "type": "e2ee_v2_envelope", "aps": ["content-available": 1],
        ]))
        XCTAssertFalse(E2EEV2NotificationDeliveryPolicy.usesServiceExtension([
            "type": "message_new", "aps": ["mutable-content": 1],
        ]))
    }

    @MainActor
    func testOpaqueFallbackTapOpensInboxWithoutInventingAConversation() {
        let router = AppRouter()
        router.handle(type: "e2ee_v2_envelope", conversationId: nil, postId: nil)
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertTrue(router.openMessagesInbox)
        XCTAssertNil(router.openConversationId)
    }

    func testContextBridgeGatePrecedesEveryDependency() async throws {
        let fixture = try fixture(), calls = Counter(), coordinator = E2EEV2NotificationContextCoordinator()
        let result = await coordinator.refreshRuntime(reason: .foreground, dependencies: .init(
            snapshot: { calls.increment(); return nil },
            approval: { _ in calls.increment(); return .unavailable },
            senderNames: { _ in calls.increment(); return [:] },
            prepare: { _, _, _ in calls.increment(); return fixture.context },
            loadExisting: { calls.increment(); return nil },
            persist: { _ in calls.increment(); return false },
            revoke: { calls.increment() }
        ))
        XCTAssertEqual(result, .dormant)
        XCTAssertEqual(calls.count, 0)
    }

    func testNoticeRequiredBeforeTheMirrorIsWritten() async throws {
        let fixture = try fixture(), store = try store(fixture), calls = Counter()
        let state = AccountBox(account(fixture, notice: false))
        let result = await E2EEV2NotificationContextCoordinator().refreshContractPreview(
            reason: .foreground,
            dependencies: bridgeDependencies(fixture, state: state, store: store, approval: { _ in
                calls.increment(); return .approved(fixture.descriptor)
            })
        )
        XCTAssertEqual(result, .awaitingNotice)
        XCTAssertEqual(calls.count, 0)
        XCTAssertNil(try store.load(now: now))
    }

    func testApprovedContextPublishesOnceWithoutRotatingUnchangedRevision() async throws {
        let fixture = try fixture(), state = AccountBox(account(fixture))
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        let coordinator = E2EEV2NotificationContextCoordinator()
        let dependencies = bridgeDependencies(fixture, state: state, store: store)
        let first = await coordinator.refreshContractPreview(reason: .foreground, dependencies: dependencies)
        let revision = try XCTUnwrap(store.load(now: now)).revisionId
        let second = await coordinator.refreshContractPreview(reason: .foreground, dependencies: dependencies)
        XCTAssertEqual(first, .ready)
        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(try store.load(now: now)?.revisionId, revision)
    }

    func testChangedAccountDuringApprovalCannotPublish() async throws {
        let fixture = try fixture(), state = AccountBox(account(fixture))
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        let result = await E2EEV2NotificationContextCoordinator().refreshContractPreview(reason: .foreground,
            dependencies: bridgeDependencies(fixture, state: state, store: store, approval: { _ in
                state.set(nil)
                return .approved(fixture.descriptor)
            }))
        XCTAssertEqual(result, .stale)
        XCTAssertNil(try store.load(now: now))
    }

    func testCredentialRefreshReusesOnlyTheSameSessionMirrorWithoutOriginalKeyAccess() async throws {
        let fixture = try fixture(), calls = Counter()
        let oldAccount = account(fixture, expiry: Int64(now.timeIntervalSince1970 * 1_000) - 1_000)
        let oldContext = Self.context(fixture.context, account: oldAccount,
            descriptor: fixture.descriptor, names: fixture.context.senderNames)
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try store.saveContractPreview(oldContext, now: now.addingTimeInterval(-7_200))
        XCTAssertNil(try store.load(now: now))
        let newAccount = account(fixture, token: "renewed.fixture.signature")
        let state = AccountBox(newAccount)
        let result = await E2EEV2NotificationContextCoordinator().refreshContractPreview(reason: .credentials,
            dependencies: bridgeDependencies(fixture, state: state, store: store, approval: { _ in
                calls.increment(); return .unavailable
            }))
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(calls.count, 0)
        let renewed = try XCTUnwrap(store.load(now: now))
        XCTAssertEqual(renewed.authToken, newAccount.authToken)
        XCTAssertEqual(renewed.deviceId, oldContext.deviceId)
    }

    func testNewLocalSessionCannotReusePreviousMirror() async throws {
        let fixture = try fixture(), calls = Counter(), store = try store(fixture)
        let state = AccountBox(account(fixture, sessionId: UUID().uuidString))
        let result = await E2EEV2NotificationContextCoordinator().refreshContractPreview(reason: .credentials,
            dependencies: bridgeDependencies(fixture, state: state, store: store, approval: { _ in
                calls.increment(); return .notApproved
            }))
        XCTAssertEqual(result, .notApproved)
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(try store.load(now: now))
    }

    func testPrivacyChangeWhileLoadingNamesPreventsKeyPreparation() async throws {
        let fixture = try fixture(), state = AccountBox(account(fixture)), hidden = account(fixture, privacy: .hidden)
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        let result = await E2EEV2NotificationContextCoordinator().refreshContractPreview(reason: .foreground,
            dependencies: bridgeDependencies(fixture, state: state, store: store, names: { _ in
                state.set(hidden)
                return fixture.context.senderNames
            }))
        XCTAssertEqual(result, .stale)
        XCTAssertNil(try store.load(now: now))
    }

    func testNewPreparationSupersedesAnOlderSuspendedRequest() async throws {
        let fixture = try fixture(), state = AccountBox(account(fixture))
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        let coordinator = E2EEV2NotificationContextCoordinator()
        let latest = bridgeDependencies(fixture, state: state, store: store)
        let older = bridgeDependencies(fixture, state: state, store: store, approval: { _ in
            let result = await coordinator.refreshContractPreview(reason: .foreground, dependencies: latest)
            XCTAssertEqual(result, .ready)
            return .approved(fixture.descriptor)
        })
        let result = await coordinator.refreshContractPreview(reason: .foreground, dependencies: older)
        XCTAssertEqual(result, .stale)
        XCTAssertNotNil(try store.load(now: now))
    }

    func testRejectedDeviceRevokesButTemporaryNetworkFailurePreservesExistingContext() async throws {
        let fixture = try fixture(), state = AccountBox(account(fixture)), store = try store(fixture)
        let coordinator = E2EEV2NotificationContextCoordinator()
        let unavailable = await coordinator.refreshContractPreview(reason: .foreground,
            dependencies: bridgeDependencies(fixture, state: state, store: store, approval: { _ in .unavailable }))
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertNotNil(try store.load(now: now))
        let rejected = await coordinator.refreshContractPreview(reason: .foreground,
            dependencies: bridgeDependencies(fixture, state: state, store: store, approval: { _ in .notApproved }))
        XCTAssertEqual(rejected, .notApproved)
        XCTAssertNil(try store.load(now: now))
    }

    func testSessionClaimsRejectWrongUserExpiredAndNonSessionTokens() throws {
        func token(_ payload: [String: Any]) throws -> String {
            "header.\(try JSONSerialization.data(withJSONObject: payload).base64URLEncodedNoPadding()).signature"
        }
        let expiry = Int64(now.timeIntervalSince1970) + 3_600
        let valid = try token(["userId": "user-a", "exp": expiry, "kind": "session"])
        XCTAssertEqual(E2EEV2NotificationSessionClaims.expirationMs(token: valid, expectedUserId: "user-a", now: now), expiry * 1_000)
        XCTAssertNil(E2EEV2NotificationSessionClaims.expirationMs(token: valid, expectedUserId: "user-b", now: now))
        let invalidPayloads: [[String: Any]] = [
            ["userId": "user-a", "exp": 1],
            ["userId": "user-a", "exp": expiry, "pendingTwoFactor": true],
            ["userId": "user-a", "exp": expiry, "scope": "realtime"],
            ["userId": "user-a", "exp": true],
        ]
        for payload in invalidPayloads {
            XCTAssertNil(E2EEV2NotificationSessionClaims.expirationMs(token: try token(payload), expectedUserId: "user-a", now: now))
        }
    }

    func testActivationMarkerSurvivesRecreationAndContainsNoSecret() throws {
        let fixture = try fixture(), tokens = InMemoryTokenStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sq-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("active")
        let store = E2EEV2NotificationContextStore(tokenStore: tokens,
            activationStore: E2EEV2NotificationFileActivationStore(url: url))
        try store.saveContractPreview(fixture.context, now: now)
        XCTAssertEqual(try String(contentsOf: url), fixture.context.revisionId)
        let restored = E2EEV2NotificationContextStore(tokenStore: tokens,
            activationStore: E2EEV2NotificationFileActivationStore(url: url))
        XCTAssertEqual(try restored.load(now: now), fixture.context)
        try restored.revoke()
        XCTAssertNil(try store.load(now: now))
    }

    func testMarkerRevocationBlocksReadsEvenWhenKeychainRemovalFails() throws {
        let fixture = try fixture(), tokens = FailingTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: tokens)
        try store.saveContractPreview(fixture.context, now: now)
        tokens.failRemoval = true
        try store.revoke()
        XCTAssertFalse(try tokens.keys(withPrefix: "").isEmpty, "Fixture proves the Keychain copy remains")
        XCTAssertNil(try store.load(now: now), "Revoked marker must make that copy unusable")
    }

    func testFailedWriteCannotReactivateTheOldMirror() throws {
        let fixture = try fixture(), tokens = FailingTokenStore()
        let store = E2EEV2NotificationContextStore(tokenStore: tokens)
        try store.saveContractPreview(fixture.context, now: now)
        tokens.failWrite = true
        XCTAssertThrowsError(try store.saveContractPreview(fixture.context, now: now))
        XCTAssertNil(try store.load(now: now))
    }

    func testFailureOfBothRevocationStoresIsNotReportedAsHidden() async throws {
        let fixture = try fixture(), tokens = FailingTokenStore(), activation = FailingActivationStore()
        let store = E2EEV2NotificationContextStore(tokenStore: tokens, activationStore: activation)
        try store.saveContractPreview(fixture.context, now: now)
        tokens.failRemoval = true
        activation.failRevocation = true
        let state = AccountBox(account(fixture, privacy: .hidden))
        let result = await E2EEV2NotificationContextCoordinator().refreshContractPreview(reason: .preferences,
            dependencies: bridgeDependencies(fixture, state: state, store: store))
        XCTAssertEqual(result, .unavailable)
    }

    @MainActor
    func testNoticeRendersAtCompactAndAccessibilitySizes() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = repository.appendingPathComponent("build/qa/e2ee-preview-notice")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cases: [(String, CGFloat, DynamicTypeSize, ColorScheme)] = [
            ("light", 390.0, DynamicTypeSize.large, ColorScheme.light),
            ("dark", 390.0, DynamicTypeSize.large, ColorScheme.dark),
            ("large-text", 320.0, DynamicTypeSize.accessibility3, ColorScheme.light),
            ("error", 320.0, DynamicTypeSize.large, ColorScheme.light),
        ]
        for (name, width, size, scheme) in cases {
            let error = name == "error"
                ? String(localized: "Impossible de modifier les aperçus. Réessaie ou désactive les notifications dans les Réglages iOS.")
                : nil
            let content = E2EEV2NotificationPreviewNoticeContent(selected: .full, errorMessage: error, onChoose: { _ in })
                .padding(SQSpace.xl).frame(width: width)
                .background(SQColor.bg)
                .environment(\.dynamicTypeSize, size).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, width, accuracy: 0.1)
            XCTAssertGreaterThan(image.size.height, 150)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private func account(_ fixture: Fixture, notice: Bool = true, privacy: E2EEV2NotificationPrivacy? = nil,
                         token: String? = nil, expiry: Int64? = nil, sessionId: String? = nil) -> E2EEV2NotificationAccountSnapshot {
        .init(ownerScopeId: owner, localOwnerScopeId: "user:fixture-user", ownerNamespace: "fixture-namespace",
            sessionId: sessionId ?? fixture.context.sessionId, authToken: token ?? fixture.context.authToken,
            expiresAtMs: expiry ?? fixture.context.expiresAtMs, privacy: privacy ?? fixture.context.privacy,
            noticeAcknowledged: notice)
    }

    private static func context(_ base: E2EEV2NotificationContext, account: E2EEV2NotificationAccountSnapshot,
                                descriptor: E2EEV2DeviceDescriptor, names: [String: String]) -> E2EEV2NotificationContext {
        .init(version: E2EEV2NotificationContext.currentVersion, revisionId: UUID().uuidString.lowercased(),
            ownerScopeId: account.ownerScopeId, sessionId: account.sessionId, authToken: account.authToken,
            expiresAtMs: account.expiresAtMs, deviceId: descriptor.deviceId, privacy: account.privacy, senderNames: names)
    }

    private func bridgeDependencies(_ fixture: Fixture, state: AccountBox, store: E2EEV2NotificationContextStore,
        approval: (@Sendable (E2EEV2NotificationAccountSnapshot) async -> E2EEV2NotificationDeviceApproval)? = nil,
        names: (@Sendable (E2EEV2NotificationAccountSnapshot) async -> [String: String])? = nil
    ) -> E2EEV2NotificationContextBridgeDependencies {
        .init(snapshot: { state.get() }, approval: approval ?? { _ in .approved(fixture.descriptor) },
            senderNames: names ?? { _ in fixture.context.senderNames },
            prepare: { account, descriptor, names in Self.context(fixture.context, account: account, descriptor: descriptor, names: names) },
            loadExisting: { try store.loadForCredentialRefresh() },
            persist: { try store.saveContractPreview($0, now: fixture.now); return true },
            revoke: { try store.revoke() }, now: { fixture.now })
    }

    private func process(
        _ fixture: Fixture,
        store: E2EEV2NotificationContextStore,
        envelopeId requested: String? = nil,
        fetch: @escaping @Sendable (URLRequest) async throws -> Data
    ) async -> E2EEV2NotificationProcessingResult {
        await E2EEV2NotificationProcessor.processContractPreview(
            request: E2EEV2OpaqueNotificationRequest(envelopeId: requested ?? envelopeId, recipientOwnerScope: owner)!,
            apiBaseURL: URL(string: "https://api.example.test")!,
            dependencies: .init(
                loadContext: { try store.load(now: fixture.now) },
                isCurrent: { try store.isCurrent($0, now: fixture.now) },
                loadConversation: { try store.conversation($0, now: fixture.now) },
                claimShown: { try store.claimShown(conversationId: $0, deviceId: $1, counter: $2, floor: $3, now: fixture.now) },
                fetch: fetch, now: { fixture.now }
            )
        )
    }

    /// La même entrée, quelques champs changés.
    private func entry(
        _ base: E2EEV2NotificationConversation,
        conversationId: String? = nil,
        ownerScopeId: String? = nil,
        sessionId: String? = nil,
        writtenAtMs: Int64? = nil,
        epochs: [E2EEV2NotificationConversation.Epoch]? = nil,
        latestMemberIds: [String]? = nil,
        departures: [String: Int64]? = nil,
        counters: [String: Int]? = nil,
        signingKeys: [String: String]? = nil
    ) -> E2EEV2NotificationConversation {
        .init(
            version: base.version, conversationId: conversationId ?? base.conversationId,
            ownerScopeId: ownerScopeId ?? base.ownerScopeId, sessionId: sessionId ?? base.sessionId,
            writtenAtMs: writtenAtMs ?? base.writtenAtMs, epochs: epochs ?? base.epochs,
            latestMemberIds: latestMemberIds ?? base.latestMemberIds, departures: departures ?? base.departures,
            counters: counters ?? base.counters, signingKeys: signingKeys ?? base.signingKeys
        )
    }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private func store(_ fixture: Fixture) throws -> E2EEV2NotificationContextStore {
        let store = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try store.saveContractPreview(fixture.context, now: now)
        try store.saveConversationContractPreview(fixture.conversation, now: now)
        return store
    }

    private func fixture(
        privacy: E2EEV2NotificationPrivacy = .full,
        createdAt: Date? = nil,
        replacedAt: Date? = nil,
        ttlSeconds: Int = 0,
        body: E2EEV2ContentPayloadV2.Body = .text("Contenu privé de test"),
        conversation announced: String? = nil
    ) throws -> Fixture {
        let recipientIdentity = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let recipientSigning = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let senderSigning = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let epochKey = Data(repeating: 4, count: 32)
        let created = createdAt ?? now
        let payload = try E2EEV2ContentPayloadV2(
            sentAtMs: Int64(created.timeIntervalSince1970 * 1_000), counter: 1, replyToRef: nil, mentions: [],
            body: body
        ).encoded()
        let signed = try E2EEV2MessageComposerV2.compose(
            payload: payload, conversationId: conversationId, clientRequestId: "request_notification_fixture", ttlSeconds: ttlSeconds,
            epoch: E2EEV2StoredEpochKey(
                conversationId: conversationId, epochId: "epoch_notification_fixture_01", epochNumber: 7,
                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey), epochKey: epochKey
            ),
            device: .init(
                deviceId: senderDeviceId, platform: "android", label: nil,
                publicIdentityKeyB64: recipientIdentity.publicKey.x963Representation.base64EncodedString(),
                publicSigningKeyB64: senderSigning.publicKey.x963Representation.base64EncodedString(),
                identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
                signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
            ),
            fk: Data(repeating: 5, count: 32), nonce: Data(repeating: 8, count: 12),
            sign: { try E2EEV2LowS.sign($0, with: senderSigning) }
        )
        let message: E2EEV2JSON = .object([
            "envelopeId": .string(envelopeId), "sequence": .string("1"),
            "senderUserId": .string(senderId), "senderDeviceId": .string(senderDeviceId), "envelope": signed.json,
            "serverTagB64": .string(Data(repeating: 9, count: 32).base64EncodedString()),
            "serverTimeMs": .string(String(Int64(created.timeIntervalSince1970 * 1_000))), "keyId": .string("server_tag_key_01J7ABCD"),
        ])
        let descriptor = E2EEV2DeviceDescriptor(
            deviceId: recipientDeviceId, platform: "ios", label: nil,
            publicIdentityKeyB64: recipientIdentity.publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: recipientSigning.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
        )
        let context = E2EEV2NotificationContext(
            version: E2EEV2NotificationContext.currentVersion, revisionId: "00000000-0000-4000-8000-000000000001",
            ownerScopeId: owner, sessionId: "00000000-0000-4000-8000-000000000002", authToken: "fixture.jwt.signature",
            expiresAtMs: Int64(now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
            deviceId: recipientDeviceId, privacy: privacy, senderNames: [senderId: "Test Sender"]
        )
        // Clés d'époque seulement avec l'aperçu complet.
        let keyed = privacy == .full
        let conversation = E2EEV2NotificationConversation(
            version: E2EEV2NotificationConversation.currentVersion, conversationId: announced ?? conversationId,
            ownerScopeId: owner, sessionId: context.sessionId, writtenAtMs: Int64(now.timeIntervalSince1970 * 1_000),
            epochs: [
                .init(epochNumber: 8, keyB64: keyed ? Data(repeating: 6, count: 32).base64EncodedString() : nil,
                      memberIds: [senderId, recipientId], replacedAtMs: nil),
                .init(epochNumber: 7, keyB64: keyed ? epochKey.base64EncodedString() : nil, memberIds: [senderId, recipientId],
                      replacedAtMs: Int64((replacedAt ?? now.addingTimeInterval(-60)).timeIntervalSince1970 * 1_000)),
            ],
            latestMemberIds: [senderId, recipientId], departures: [:], counters: [:],
            signingKeys: [
                E2EEV2NotificationConversation.signingKeyName(userId: senderId, deviceId: senderDeviceId):
                    senderSigning.publicKey.x963Representation.base64EncodedString(),
            ]
        )
        let data = E2EEV2CanonicalJSON.encode(.object(["conversationId": .string(announced ?? conversationId), "message": message]))
        return Fixture(context: context, conversation: conversation, descriptor: descriptor, data: data, now: now)
    }
}
