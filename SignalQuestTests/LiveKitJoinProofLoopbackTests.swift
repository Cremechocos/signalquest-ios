#if canImport(LiveKit) && DEBUG
import CoreVideo
import CryptoKit
import LiveKit
import XCTest
@testable import SignalQuest

/// Banc local du jalon A (plan 3, lot 8) : des appareils iOS rejoignent un vrai
/// serveur LiveKit en mode développement, sur la boucle locale, et échangent
/// leurs preuves de jonction sur le canal de données chiffré (spec §10.4).
///
/// Lancé seulement avec `TEST_RUNNER_SQ_LIVEKIT_LOOPBACK_URL=ws://127.0.0.1:7880`
/// et `livekit-server --dev` (clé `devkey`, secret `secret`). Pas de micro ni de
/// caméra au simulateur : les médias se limitent à une piste vidéo d'images
/// synthétiques.
final class LiveKitJoinProofLoopbackTests: XCTestCase {
    private struct Device {
        let userId: String
        let deviceId: String
        let key: P256.Signing.PrivateKey

        /// Identité LiveKit d'un appareil dans un appel chiffré (§10.4).
        var identity: String { E2EEV2CallJoinProof.livekitIdentity(userId: userId, deviceId: deviceId) }
    }

    private final class RawDataRecorder: NSObject, RoomDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        private var type: EncryptionType?
        private var sender: String?

        var count: Int { lock.lock(); defer { lock.unlock() }; return stored }
        var lastType: EncryptionType? { lock.lock(); defer { lock.unlock() }; return type }
        var lastSender: String? { lock.lock(); defer { lock.unlock() }; return sender }

        func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
            lock.lock(); defer { lock.unlock() }
            stored += 1
            type = encryptionType
            sender = participant?.identity?.stringValue
        }
    }

    @MainActor
    private final class Recorder {
        var losses: [E2EEV2CallTrustLoss] = []
        var data: [(sender: String?, payload: Data, topic: String)] = []
    }

    @MainActor
    func testTwoDevicesProveEachOtherThenExchangeData() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice"), bruno = device("bruno")
        let directory = [alice, bruno]

        let (aliceClient, _) = try await join(url, call, as: alice, trusting: directory)
        let (brunoClient, brunoLog) = try await join(url, call, as: bruno, trusting: directory)

        try await waitUntil("preuves échangées") { aliceClient.isE2EEVerified && brunoClient.isE2EEVerified }
        try await aliceClient.publishData(Data("bonjour".utf8), topic: "sq.test.hello")
        try await waitUntil("donnée d'un participant prouvé") {
            brunoLog.data.contains { $0.topic == "sq.test.hello" && $0.sender == alice.identity }
        }
        XCTAssertFalse(brunoLog.data.contains { $0.topic == E2EEV2CallJoinProof.topic }, "Une preuve n'atteint jamais l'app")
        XCTAssertEqual(aliceClient.state, .connected)
        XCTAssertEqual(brunoClient.state, .connected)
    }

    @MainActor
    func testUnknownDeviceEndsTheCallAtOnce() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice"), mallory = device("mallory")

        let (aliceClient, aliceLog) = try await join(url, call, as: alice, trusting: [alice])
        let (malloryClient, malloryLog) = try await join(url, call, as: mallory, trusting: [alice, mallory])

        try await waitUntil("appel coupé par une preuve d'un appareil inconnu", timeout: 8) {
            aliceLog.losses == [.joinProof]
        }
        XCTAssertTrue(malloryLog.losses.isEmpty, "La preuve de Mallory est bien partie : \(malloryLog.losses)")
        XCTAssertTrue(malloryClient.isE2EEVerified, "Mallory, lui, a reçu et accepté la preuve d'Alice")
        XCTAssertEqual(aliceClient.state, .ended)
        XCTAssertFalse(aliceClient.isE2EEVerified)
    }

    @MainActor
    func testParticipantWithoutProofEndsTheCallAfterTenSeconds() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice")

        let (aliceClient, aliceLog) = try await join(url, call, as: alice, trusting: [alice])
        // Même clé de trame, mais aucune preuve envoyée.
        _ = try await join(url, call, as: nil, identity: "lk_silent", trusting: [])

        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(aliceLog.losses.isEmpty, "Le délai de 10 secondes n'est pas écoulé")
        XCTAssertFalse(aliceClient.isE2EEVerified, "Pas de cadenas sans preuve")
        try await waitUntil("appel coupé faute de preuve", timeout: 9) { aliceLog.losses == [.joinProof] }
        XCTAssertEqual(aliceClient.state, .ended)
    }

    @MainActor
    func testUnencryptedDataEndsTheCall() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice")

        let (aliceClient, aliceLog) = try await join(url, call, as: alice, trusting: [alice])
        let plain = LiveKitClient()
        addTeardownBlock { await plain.disconnect() }
        await plain.connect(
            url: url, token: try token(identity: "lk_plain", room: call.roomName), room: call.roomName,
            video: false, managesAudioSession: false, e2eeSession: nil, mediaSetupMode: .localQADataOnly
        )
        try await waitUntil("client en clair connecté") { plain.state == .connected }
        // Un paquet envoyé avant que le serveur annonce son émetteur peut se perdre.
        for _ in 0..<16 where aliceLog.losses.isEmpty {
            try await plain.publishData(Data("en clair".utf8), topic: "sq.test.plain")
            try await Task.sleep(for: .milliseconds(500))
        }

        try await waitUntil("paquet en clair refusé", timeout: 8) { aliceLog.losses == [.verification] }
        XCTAssertFalse(aliceLog.data.contains { $0.topic == "sq.test.plain" }, "Rien de ce paquet n'atteint l'app")
        XCTAssertEqual(aliceClient.state, .ended)
    }

    /// Une piste vidéo publiée en clair par un appareil connu de l'appel y met
    /// fin dès son arrivée, avant le délai de la preuve de jonction : rien n'en
    /// est rendu (spec §10.4).
    @MainActor
    func testUnencryptedVideoTrackEndsTheCall() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice"), bruno = device("bruno")
        let (aliceClient, aliceLog) = try await join(url, call, as: alice, trusting: [alice, bruno])

        // Bruno, connu d'Alice, rejoint sans chiffrement et publie une piste vidéo.
        let plain = Room()
        addTeardownBlock { await plain.disconnect() }
        try await plain.connect(url: url.absoluteString, token: try token(identity: bruno.identity, room: call.roomName))
        let track = await LocalVideoTrack.createBufferTrack(name: "sq-test-clair", source: .camera)
        let capturer = try XCTUnwrap(track.capturer as? BufferCapturer)
        let frame = try pixelBuffer()
        // Le SDK attend les dimensions de la première image avant de publier.
        let feeder = Task { @MainActor in
            while !Task.isCancelled {
                capturer.capture(frame)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { feeder.cancel() }
        _ = try await plain.localParticipant.publish(videoTrack: track)

        try await waitUntil("piste en clair refusée", timeout: 9) { !aliceLog.losses.isEmpty }
        XCTAssertEqual(aliceLog.losses.first, .verification, "Coupé par la piste en clair, pas par le délai de preuve")
        XCTAssertEqual(aliceClient.state, .ended)
        XCTAssertFalse(aliceClient.isE2EEVerified)
    }

    /// Une reconnexion complète réarme le marqueur SIF dans le SDK : un appel
    /// chiffré prend fin. Une reconnexion rapide le laisse continuer.
    @MainActor
    func testFullReconnectEndsAnEncryptedCallButAQuickOneDoesNot() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice"), bruno = device("bruno")
        let directory = [alice, bruno]
        let (aliceClient, aliceLog) = try await join(url, call, as: alice, trusting: directory)
        let (brunoClient, brunoLog) = try await join(url, call, as: bruno, trusting: directory)
        try await waitUntil("preuves échangées") { aliceClient.isE2EEVerified && brunoClient.isE2EEVerified }

        try await brunoClient.debugSimulate(.quickReconnect)
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(brunoLog.losses.isEmpty, "Reconnexion rapide : l'appel continue (\(brunoLog.losses))")
        XCTAssertEqual(brunoClient.state, .connected)

        try await aliceClient.debugSimulate(.fullReconnect)
        try await waitUntil("appel coupé par la reconnexion complète", timeout: 8) { aliceLog.losses == [.reconnected] }
        XCTAssertEqual(aliceClient.state, .ended)
    }

    /// Un arrivant tardif dans un appel à deux déjà prouvé : les trois se
    /// prouvent, grâce aux rediffusions, sans couper l'appel.
    @MainActor
    func testLateJoinerIsProvenByEveryone() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice"), bruno = device("bruno"), carla = device("carla")
        let directory = [alice, bruno, carla]

        let (aliceClient, aliceLog) = try await join(url, call, as: alice, trusting: directory)
        let (brunoClient, brunoLog) = try await join(url, call, as: bruno, trusting: directory)
        try await waitUntil("appel à deux prouvé") { aliceClient.isE2EEVerified && brunoClient.isE2EEVerified }
        try await Task.sleep(for: .seconds(3))

        let (carlaClient, carlaLog) = try await join(url, call, as: carla, trusting: directory)
        try await waitUntil("appel à trois prouvé", timeout: 15) {
            aliceClient.isE2EEVerified && brunoClient.isE2EEVerified && carlaClient.isE2EEVerified
        }
        XCTAssertEqual(aliceLog.losses + brunoLog.losses + carlaLog.losses, [], "Aucune coupure")
    }

    /// Deux appareils du même compte dans le même appel : l'identité porte
    /// l'appareil, aucun n'éjecte l'autre (spec v0.4.3).
    @MainActor
    func testTwoDevicesOfTheSameAccountShareTheCall() async throws {
        let url = try loopbackURL()
        let call = try makeCall()
        let alice = device("alice")
        let brunoPhone = Device(userId: "user_bruno_01J7ABCD", deviceId: "device_bruno_ios_01J7ABCD", key: P256.Signing.PrivateKey())
        let brunoTablet = Device(userId: "user_bruno_01J7ABCD", deviceId: "device_bruno_ipad_01J7ABCD", key: P256.Signing.PrivateKey())
        let directory = [alice, brunoPhone, brunoTablet]

        let (aliceClient, aliceLog) = try await join(url, call, as: alice, trusting: directory)
        let (phoneClient, _) = try await join(url, call, as: brunoPhone, trusting: directory)
        let (tabletClient, _) = try await join(url, call, as: brunoTablet, trusting: directory)
        try await waitUntil("trois appareils prouvés", timeout: 15) {
            aliceClient.isE2EEVerified && phoneClient.isE2EEVerified && tabletClient.isE2EEVerified
        }
        XCTAssertEqual(aliceLog.losses, [])
        XCTAssertEqual(phoneClient.state, .connected, "Le téléphone n'a pas été éjecté par la tablette")
    }

    /// Diagnostic du banc : deux `Room` LiveKit nues, sans le client de l'app,
    /// avec puis sans chiffrement du canal de données.
    @MainActor
    func testRawRoomsExchangeData() async throws {
        let url = try loopbackURL()
        for encrypted in [false, true] {
            let roomName = "sq-raw-\(encrypted ? "e2ee" : "plain")-\(UUID().uuidString.prefix(6))"
            let received = RawDataRecorder()
            func options() -> RoomOptions {
                guard encrypted else { return RoomOptions() }
                let provider = BaseKeyProvider(options: E2EEV2LiveKitSession.keyProviderOptions)
                provider.setKey(key: "cle-de-banc-partagee-0123456789abcdef0123456789", index: 0)
                return RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: provider, encryptionType: .gcm))
            }
            let sender = Room(roomOptions: options())
            let receiver = Room(delegate: received, roomOptions: options())
            addTeardownBlock { await sender.disconnect(); await receiver.disconnect() }
            try await receiver.connect(url: url.absoluteString, token: try token(identity: "raw_receiver", room: roomName))
            try await sender.connect(url: url.absoluteString, token: try token(identity: "raw_sender", room: roomName))
            for attempt in 1...20 {
                try await sender.localParticipant.publish(
                    data: Data("essai \(attempt)".utf8),
                    options: DataPublishOptions(topic: "sq.test.raw", reliable: true)
                )
                if received.count > 0 { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            print("BANC-BRUT encrypted=\(encrypted) reçus=\(received.count) type=\(received.lastType.map { "\($0.rawValue)" } ?? "-") émetteur=\(received.lastSender ?? "-")")
            XCTAssertGreaterThan(received.count, 0, "Données reçues (chiffrement : \(encrypted))")
        }
    }

    // MARK: - Outils

    private struct Call {
        let roomName: String
        let epochKey: Data
        let descriptor: E2EEV2CallDescriptor
    }

    private func loopbackURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["SQ_LIVEKIT_LOOPBACK_URL"] ?? environment["TEST_RUNNER_SQ_LIVEKIT_LOOPBACK_URL"] else {
            throw XCTSkip("Banc LiveKit local non demandé (SQ_LIVEKIT_LOOPBACK_URL)")
        }
        guard let url = URL(string: raw), ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
            throw XCTSkip("Le banc n'accepte que la boucle locale")
        }
        if environment["SQ_LIVEKIT_LOOPBACK_DEBUG"] == "1" || environment["TEST_RUNNER_SQ_LIVEKIT_LOOPBACK_DEBUG"] == "1" {
            LiveKitSDK.setLogger(PrintLogger(minLevel: .debug, colors: false))
        }
        return url
    }

    private func makeCall() throws -> Call {
        var epochKey = Data(count: 32)
        _ = epochKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let descriptor = E2EEV2CallDescriptor(
            conversationId: "conversation_loopback_01J7ABCD",
            callId: try E2EEV2CallDescriptorFactory.newCallId(),
            callerDeviceId: "device_alice_ios_01J7ABCD",
            epochId: "epoch_loopback_01J7ABCD",
            epochNumber: 1,
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey),
            callNonceB64: try E2EEV2CallDescriptorFactory.newCallNonceB64(),
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        return Call(roomName: "sq-loopback-\(UUID().uuidString.prefix(8))", epochKey: epochKey, descriptor: descriptor)
    }

    private func device(_ name: String) -> Device {
        Device(userId: "user_\(name)_01J7ABCD", deviceId: "device_\(name)_ios_01J7ABCD", key: P256.Signing.PrivateKey())
    }

    /// `device` nil : même clé de trame, sans preuve de jonction.
    @MainActor
    private func join(
        _ url: URL,
        _ call: Call,
        as device: Device?,
        identity explicitIdentity: String? = nil,
        trusting directory: [Device]
    ) async throws -> (LiveKitClient, Recorder) {
        let identity = explicitIdentity ?? device?.identity ?? "lk_\(UUID().uuidString.prefix(8))"
        let known = Dictionary(uniqueKeysWithValues: directory.map {
            ("\($0.userId)/\($0.deviceId)", $0.key.publicKey.x963Representation)
        })
        let join = device.map { device in
            let raw = device.key.rawRepresentation
            return E2EEV2CallJoinConfiguration(
                context: .init(
                    conversationId: call.descriptor.conversationId,
                    callId: call.descriptor.callId,
                    callNonceB64: call.descriptor.callNonceB64
                ),
                userId: device.userId,
                deviceId: device.deviceId,
                sign: { try E2EEV2LowS.sign($0, with: P256.Signing.PrivateKey(rawRepresentation: raw)) },
                deviceSigningKey: { user, deviceId in
                    known["\(user)/\(deviceId)"].flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
                }
            )
        }
        let session = try E2EEV2LiveKitSession.make(epochKey: call.epochKey, descriptor: call.descriptor, join: join)
        let client = LiveKitClient()
        let log = Recorder()
        client.onE2EETrustLost = { log.losses.append($0) }
        client.onDataReceived = { sender, payload, topic in log.data.append((sender, payload, topic)) }
        addTeardownBlock { await client.disconnect() }
        await client.connect(
            url: url, token: try token(identity: identity, room: call.roomName), room: call.roomName,
            video: false, managesAudioSession: false, e2eeSession: session, mediaSetupMode: .localQADataOnly
        )
        XCTAssertEqual(client.state, .connected, "Connexion de \(identity)")
        return (client, log)
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attributes, &buffer)
        return try XCTUnwrap(buffer)
    }

    /// Jeton du mode développement de livekit-server (HS256, `devkey`/`secret`).
    private func token(identity: String, room: String) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": "devkey", "sub": identity, "name": identity, "nbf": now - 10, "exp": now + 600,
            "video": ["room": room, "roomJoin": true, "canPublish": true, "canSubscribe": true, "canPublishData": true],
        ] as [String: Any], options: [.sortedKeys])
        let signingInput = "\(base64URL(header)).\(base64URL(claims))"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8), using: SymmetricKey(data: Data("secret".utf8))
        )
        return "\(signingInput).\(base64URL(Data(signature)))"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @MainActor
    private func waitUntil(_ label: String, timeout: TimeInterval = 12, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Délai dépassé : \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
