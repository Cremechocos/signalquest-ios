import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : la messagerie v2 d'une conversation, de bout en bout contre
/// un faux serveur (E.2, E.3) : relève, envoi précédé d'une rotation,
/// changements d'appartenance.
final class E2EEV2ConversationMessagingV2Tests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    func testRefreshReadsEveryPageAndKeepsItsCursor() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let server = try FakeV2Server(fixture, seeded: seeded, pageSize: 2)
        for (index, text) in ["Salut", "Tu viens ?", "À tout de suite"].enumerated() {
            server.add(try item(from: phone, seeded: seeded, counter: index + 1, text: text))
        }
        MockURLProtocol.requestHandler = server.handle
        let messaging = try makeMessaging(fixture)
        let owner = fixture.session.ownerScopeId

        let refreshed = await messaging.refresh(conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner)
        guard case .refreshed(let messages) = refreshed else { return XCTFail("Relève : \(refreshed)") }
        XCTAssertEqual(messages.snapshot.messages.map(\.text), ["Salut", "Tu viens ?", "À tout de suite"])
        XCTAssertEqual(messages.snapshot.cursor, 3)
        XCTAssertEqual(messages.missingByDevice, [:])
        XCTAssertEqual(server.listAfters, ["0", "2"], "Deux pages, la seconde après la première")

        let again = await messaging.refresh(conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner)
        guard case .refreshed(let same) = again else { return XCTFail("Seconde relève : \(again)") }
        XCTAssertEqual(same.snapshot.messages.count, 3)
        XCTAssertEqual(server.listAfters.last, "3", "Reprise au curseur gardé")
    }

    func testTheCursorStopsBeforeAMessageToReread() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let tablet = E2EEV2TestRemote(user: bruno, device: "device_bruno_tablet_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let server = try FakeV2Server(fixture, seeded: seeded, pageSize: 100)
        server.add(try item(from: phone, seeded: seeded, counter: 1, text: "Premier"))
        // Une tablette que l'annuaire local ne connaît pas encore : à relire.
        server.add(try item(from: tablet, seeded: seeded, counter: 1, text: "Depuis la tablette"))
        server.add(try item(from: phone, seeded: seeded, counter: 2, text: "Troisième"))
        MockURLProtocol.requestHandler = server.handle
        let messaging = try makeMessaging(fixture)
        let refreshed = await messaging.refresh(
            conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .refreshed(let messages) = refreshed else { return XCTFail("Relève : \(refreshed)") }
        XCTAssertEqual(messages.snapshot.cursor, 1, "Le curseur ne dépasse pas le message à relire")
        XCTAssertEqual(messages.snapshot.messages.map(\.text), ["Premier", "Troisième"])
        // Toujours inconnue (appareil révoqué, par exemple) : après trois arrêts, la relève passe.
        var cursors: [Int64] = []
        for _ in 0..<3 {
            guard case .refreshed(let next) = await messaging.refresh(
                conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
            ) else { return XCTFail("Relève suivante") }
            cursors.append(next.snapshot.cursor)
        }
        XCTAssertEqual(cursors, [1, 1, 3], "Rien ne bloque la conversation")
    }

    func testSendingRotatesFirstWhenADeviceWasAdded() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let tablet = E2EEV2TestRemote(user: bruno, device: "device_bruno_tablet_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        let server = try FakeV2Server(fixture, seeded: seeded, pageSize: 100)
        MockURLProtocol.requestHandler = server.handle
        let messaging = try makeMessaging(fixture)
        let result = await messaging.send(
            .init(body: .text("Salut à tes deux appareils"), replyToRef: nil, mentions: [], ttlSeconds: 0),
            clientRequestId: "message_01J7ABCD00000001", conversationId: seeded.conversationId, isGroup: false,
            devices: fixture.deviceSet(adding: [phone.device, tablet.device]), expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .sent = result else { return XCTFail("Envoyé après rotation : \(result)") }
        XCTAssertEqual(server.epochPosts, 1, "Une époque créée avant l'envoi")
        let sent = try XCTUnwrap(server.sentEnvelopes.last)
        XCTAssertEqual(sent.envelope.epochNumber, 2, "Chiffré sous l'époque qui inclut la tablette")
    }

    func testExcludingBrowsersRotatesAtOnce() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let server = try FakeV2Server(fixture, seeded: seeded, pageSize: 100)
        MockURLProtocol.requestHandler = server.handle
        let messaging = try makeMessaging(fixture)
        let result = await messaging.change(
            .excludeBrowsers(true), conversationId: seeded.conversationId, isGroup: false, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .applied(changeNumber: seeded.membership.changeNumber + 1))
        XCTAssertEqual(server.epochPosts, 1, "L'époque suivante suit le réglage, sans attendre un envoi")
        XCTAssertEqual(try fixture.states.currentEpoch(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace)?.excludesWeb, true)
    }

    func testARemainingMemberRotatesWhenItLearnsOfADeparture() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let carla = E2EEV2TestRemote(user: "user_carla_01J7ABCD23456789", device: "device_carla_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device, carla.device])
        let seeded = try fixture.seedGroup(with: [bruno, carla.device.userId], devices: devices)
        let server = try FakeV2Server(fixture, seeded: seeded, pageSize: 100)
        // Bruno part ; la chaîne du serveur le dit, aucune époque ne l'a suivi.
        let chain = try fixture.states.membershipChain(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace)
        let leave = E2EEV2MembershipChange(
            conversationId: seeded.conversationId, changeNumber: chain.count + 1, action: "LEAVE", targetUserId: bruno,
            actorUserId: bruno, actorDeviceId: phone.device.deviceId,
            previousChangeDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(chain.last?.canonical)), createdAtMs: 1_790_000_000_000
        )
        server.appendChange(try E2EEV2SignedString.sign(leave.canonical, with: phone.signing))
        MockURLProtocol.requestHandler = server.handle
        let messaging = try makeMessaging(fixture)
        let refreshed = await messaging.refresh(
            conversationId: seeded.conversationId, isGroup: true, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .refreshed = refreshed else { return XCTFail("Relève : \(refreshed)") }
        XCTAssertEqual(server.epochPosts, 1, "Le premier membre restant qui l'apprend crée l'époque suivante")
        let current = try XCTUnwrap(try fixture.states.currentEpoch(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertFalse(current.memberIds.contains(bruno), "Bruno ne reçoit plus rien de neuf")
    }

    func testTheNotificationMirrorFollowsOnlyWhatSucceeded() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let carla = E2EEV2TestRemote(user: "user_carla_01J7ABCD23456789", device: "device_carla_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device, carla.device])
        let seeded = try fixture.seedGroup(with: [bruno, carla.device.userId], devices: devices)
        let server = try FakeV2Server(fixture, seeded: seeded, pageSize: 100)
        for counter in 1...2 { server.add(try item(from: phone, seeded: seeded, counter: counter, text: "Message \(counter)")) }
        MockURLProtocol.requestHandler = server.handle
        let contextStore = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try contextStore.saveContractPreview(E2EEV2NotificationContext(
            version: E2EEV2NotificationContext.currentVersion, revisionId: UUID().uuidString.lowercased(),
            ownerScopeId: PushOwnerScope.id(for: fixture.user), sessionId: fixture.session.sessionId,
            authToken: "fixture.jwt.signature", expiresAtMs: Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
            deviceId: fixture.descriptor.deviceId, privacy: .full, senderNames: [:]
        ), now: Date())
        let messaging = try makeMessaging(fixture, notifications: contextStore)
        let refresh = {
            await messaging.refresh(
                conversationId: seeded.conversationId, isGroup: true, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
            )
        }

        guard case .refreshed = await refresh() else { return XCTFail("Relève") }
        let entry = try XCTUnwrap(try contextStore.conversation(seeded.conversationId))
        XCTAssertEqual(entry.counters[phone.device.deviceId], 2, "Rien de ce que l'app a reçu ne s'affichera")
        XCTAssertEqual(Set(entry.latestMemberIds), [fixture.user, bruno, carla.device.userId])
        XCTAssertEqual(entry.epochs.map(\.epochNumber), [1])

        server.failsList = true
        guard case .failure = await refresh() else { return XCTFail("Relève interrompue") }
        XCTAssertNil(try contextStore.conversation(seeded.conversationId), "Une relève interrompue ne laisse aucune entrée")
        server.failsList = false
        guard case .refreshed = await refresh() else { return XCTFail("Relève reprise") }
        XCTAssertNotNil(try contextStore.conversation(seeded.conversationId))

        server.failsSend = true
        let failed = await messaging.send(
            .init(body: .text("Ne partira pas"), replyToRef: nil, mentions: [], ttlSeconds: 0),
            clientRequestId: "message_01J7ABCD00000009", conversationId: seeded.conversationId, isGroup: true,
            devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .failure = failed else { return XCTFail("Envoi refusé : \(failed)") }
        XCTAssertNil(try contextStore.conversation(seeded.conversationId), "Un envoi échoué ne réécrit pas l'entrée")
        server.failsSend = false
        guard case .refreshed = await refresh() else { return XCTFail("Relève après l'échec") }

        let left = await messaging.change(
            .leave, conversationId: seeded.conversationId, isGroup: true, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .applied = left else { return XCTFail("Départ : \(left)") }
        XCTAssertNil(try contextStore.conversation(seeded.conversationId), "Conversation quittée : plus d'entrée")
    }

    // MARK: Aides

    private func makeMessaging(
        _ fixture: E2EEV2AccountFixture,
        notifications: E2EEV2NotificationContextStore? = nil
    ) throws -> E2EEV2ConversationMessagingV2 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("messaging-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        let ledger = try E2EEV2MessageLedgerStore(baseDirectory: directory.appendingPathComponent("ledger"))
        return E2EEV2ConversationMessagingV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            ledgerStore: ledger,
            messageStore: E2EEV2MessageStoreV2(rootURL: directory.appendingPathComponent("messages"), keyStore: InMemoryTokenStore()),
            notificationMirror: notifications.map {
                E2EEV2NotificationMirrorWriter(
                    keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: ledger, contextStore: $0, contractPreview: true
                )
            },
            expectedSession: fixture.session
        )
    }

    /// Un message de l'appareil distant sous l'époque 1, tel que la liste le remet (sans séquence).
    private func item(from remote: E2EEV2TestRemote, seeded: E2EEV2SeededConversation, counter: Int, text: String) throws -> FakeV2Server.Item {
        let clientRequestId = "message_\(remote.device.deviceId.suffix(8))_\(counter)_000000"
        let payload = try E2EEV2ContentPayloadV2(
            sentAtMs: Int64(Date().timeIntervalSince1970 * 1_000), counter: Int64(counter), replyToRef: nil, mentions: [], body: .text(text)
        ).encoded()
        let signed = try E2EEV2MessageComposerV2.compose(
            payload: payload, conversationId: seeded.conversationId, clientRequestId: clientRequestId, ttlSeconds: 0,
            epoch: E2EEV2StoredEpochKey(
                conversationId: seeded.conversationId, epochId: "epoch_seeded_000000000001", epochNumber: 1,
                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(seeded.epochKey), epochKey: seeded.epochKey
            ),
            device: E2EEV2DeviceDescriptor(
                deviceId: remote.device.deviceId, platform: remote.device.platform, label: nil,
                publicIdentityKeyB64: remote.device.identityKeyB64, publicSigningKeyB64: remote.device.signingKeyB64,
                identityKeyAlgorithm: "P256_ECDH", signingKeyAlgorithm: "P256_ECDSA_SHA256", keyVersion: 1
            ),
            fk: E2EEV2MessageComposerV2.randomBytes(32), nonce: E2EEV2MessageComposerV2.randomBytes(12),
            sign: { try E2EEV2LowS.sign($0, with: remote.signing) }
        )
        return .init(senderUserId: remote.device.userId, senderDeviceId: remote.device.deviceId, signed: signed)
    }
}

/// Faux serveur des routes v2 d'une conversation : chaîne, époques, liste et
/// envois, sur l'état qu'il garde.
private final class FakeV2Server: @unchecked Sendable {
    struct Item {
        let senderUserId: String
        let senderDeviceId: String
        let signed: E2EEV2SignedMessageEnvelopeV2
    }

    private let lock = NSLock()
    private let conversationId: String
    private let ownUserId: String
    private let ownDeviceId: String
    private let pageSize: Int
    private var chain: [E2EEV2SignedString]
    private var current: Data
    private var items: [Item] = []
    private var afters: [String] = []
    private var epochs = 0
    private var envelopes: [E2EEV2SignedMessageEnvelopeV2] = []
    private var listFails = false
    private var sendFails = false

    init(_ fixture: E2EEV2AccountFixture, seeded: E2EEV2SeededConversation, pageSize: Int) throws {
        conversationId = seeded.conversationId
        ownUserId = fixture.user
        ownDeviceId = fixture.descriptor.deviceId
        self.pageSize = pageSize
        chain = try fixture.states.membershipChain(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace)
        current = seeded.servedCurrent
    }

    var listAfters: [String] { lock.withLock { afters } }
    var epochPosts: Int { lock.withLock { epochs } }
    var sentEnvelopes: [E2EEV2SignedMessageEnvelopeV2] { lock.withLock { envelopes } }
    /// La liste répond 503 tant que c'est vrai.
    var failsList: Bool {
        get { lock.withLock { listFails } }
        set { lock.withLock { listFails = newValue } }
    }
    /// L'envoi répond 503 tant que c'est vrai.
    var failsSend: Bool {
        get { lock.withLock { sendFails } }
        set { lock.withLock { sendFails = newValue } }
    }

    func add(_ item: Item) { lock.withLock { items.append(item) } }
    func appendChange(_ change: E2EEV2SignedString) { lock.withLock { chain.append(change) } }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? ""
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let post = request.httpMethod == "POST"
        if path.hasSuffix("/membership"), !post {
            let after = query.first { $0.name == "after" }?.value.flatMap(Int.init) ?? 0
            let page = chain.dropFirst(after).map(E2EEV2MembershipChange.json)
            return respond(request, .object(["changes": .array(Array(page)), "hasMore": .bool(false)]))
        }
        if path.hasSuffix("/membership"), post {
            let body = try E2EEV2CanonicalJSON.parseStrict(E2EEV2AccountFixture.rawBody(request))
            let change = try XCTUnwrap(E2EEV2MembershipChange.signed(from: body))
            chain.append(change)
            return respond(request, .object(["changeNumber": .string(String(chain.count))]))
        }
        if path.hasSuffix("/epochs/current") {
            return E2EEV2AccountFixture.response(request, current)
        }
        if path.hasSuffix("/epochs"), post {
            let body = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(E2EEV2AccountFixture.rawBody(request)).objectValue)
            let number = try XCTUnwrap(body["epochNumber"]?.stringValue)
            let envelopes = try XCTUnwrap(body["envelopes"]?.arrayValue)
            let own = try XCTUnwrap(envelopes.first { $0.objectValue?["recipientDeviceId"]?.stringValue == ownDeviceId })
            let epoch: E2EEV2JSON = .object([
                "id": .string("epoch_fake_00000000000" + number), "epochNumber": .string(number), "status": .string("active"),
                "createdAt": .string("2026-10-01T06:30:00.000Z"),
            ])
            current = E2EEV2CanonicalJSON.encode(.object([
                "conversationId": .string(conversationId), "epoch": epoch,
                "manifest": try XCTUnwrap(body["manifest"]), "envelope": own,
            ]))
            epochs += 1
            return respond(request, .object(["epoch": epoch, "recipientCount": .string(String(envelopes.count))]))
        }
        if path.hasSuffix("/messages"), !post {
            if listFails { return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 503) }
            let after = query.first { $0.name == "after" }?.value ?? "0"
            afters.append(after)
            let start = Int(after) ?? 0
            let slice = Array(items.enumerated().dropFirst(start).prefix(pageSize))
            let messages: [E2EEV2JSON] = slice.map { index, item in
                .object([
                    "envelopeId": .string("envelope_fake_0000000\(index + 1)"), "sequence": .string(String(index + 1)),
                    "senderUserId": .string(item.senderUserId), "senderDeviceId": .string(item.senderDeviceId),
                    "envelope": item.signed.json, "serverTagB64": .string(Data(repeating: 9, count: 32).base64EncodedString()),
                    "serverTimeMs": .string(String(Int64(Date().timeIntervalSince1970 * 1_000))), "keyId": .string("server_tag_key_01J7ABCD"),
                ])
            }
            return respond(request, .object(["messages": .array(messages), "hasMore": .bool(start + slice.count < items.count)]))
        }
        if path.hasSuffix("/messages"), post {
            if sendFails { return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 503) }
            let signed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(E2EEV2AccountFixture.rawBody(request)))
            envelopes.append(signed)
            items.append(Item(senderUserId: ownUserId, senderDeviceId: ownDeviceId, signed: signed))
            return respond(request, .object([
                "envelopeId": .string("envelope_fake_0000000\(items.count)"), "clientRequestId": .string(signed.envelope.clientRequestId),
                "serverTagB64": .string(Data(repeating: 9, count: 32).base64EncodedString()),
                "serverTimeMs": .string(String(Int64(Date().timeIntervalSince1970 * 1_000))), "keyId": .string("server_tag_key_01J7ABCD"),
            ]))
        }
        XCTFail("Route inattendue : \(request.httpMethod ?? "") \(path)")
        return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 404)
    }

    private func respond(_ request: URLRequest, _ value: E2EEV2JSON) -> (HTTPURLResponse, Data) {
        E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(value))
    }
}
