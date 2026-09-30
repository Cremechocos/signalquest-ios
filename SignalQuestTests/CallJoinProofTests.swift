import CryptoKit
import XCTest
@testable import SignalQuest

/// IOS-CALL-3 (plan 3, jalon A) : preuve de jonction d'un appel chiffré
/// (spec §10.4, vecteur `call-join-proof-v1`).
final class CallJoinProofTests: XCTestCase {
    // Champs de la preuve du vecteur.
    private let conversationId = "conversation_01J7ABCD23456789"
    private let callId = "call_01J7ABCD23456789XY"
    private let callNonceB64 = "kJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq8="
    private let identity = "lk_user_bruno_01J7ABCD23456789"
    private let userId = "user_bruno_01J7ABCD23456789"
    private let deviceId = "device_bruno_android_01J7ABCD"

    func testVectorProofBindsTheSenderToItsCertifiedDevice() throws {
        let vector = try loadVector()
        let verifier = makeVerifier(keys: [owner(deviceId): vector.publicKey])

        XCTAssertEqual(verifier.receive(vector.message, from: identity), .proven)
        XCTAssertTrue(verifier.isProven(identity))
        XCTAssertEqual(verifier.receive(vector.message, from: identity), .confirmed, "Une preuve renvoyée ne change rien")
    }

    func testVectorNegativeCasesEndTheCall() throws {
        let vector = try loadVector()
        XCTAssertFalse(vector.negatives.isEmpty)
        for (name, message) in vector.negatives {
            let verifier = makeVerifier(keys: [owner(deviceId): vector.publicKey])
            XCTAssertEqual(verifier.receive(message, from: identity), .rejected, name)
            XCTAssertFalse(verifier.isProven(identity), name)
        }
    }

    func testProofMustMatchTheCallTheSenderAndACertifiedDevice() throws {
        let vector = try loadVector()
        let keys = [owner(deviceId): vector.publicKey]
        XCTAssertEqual(
            makeVerifier(keys: keys).receive(vector.message, from: "lk_user_mallory_01J7ABCD2345"),
            .rejected, "L'identité signée doit être celle de l'émetteur du paquet"
        )
        let otherNonce = Data(repeating: 7, count: 32).base64EncodedString()
        for context in [
            E2EEV2CallJoinContext(conversationId: conversationId, callId: callId, callNonceB64: otherNonce),
            E2EEV2CallJoinContext(conversationId: conversationId, callId: "call_01J7ABCD2345678999", callNonceB64: callNonceB64),
            E2EEV2CallJoinContext(conversationId: "conversation_01J7ABCD99999999", callId: callId, callNonceB64: callNonceB64),
        ] {
            XCTAssertEqual(
                makeVerifier(context: context, keys: keys).receive(vector.message, from: identity),
                .rejected, "Une preuve d'un autre appel"
            )
        }
        XCTAssertEqual(
            makeVerifier(keys: [:]).receive(vector.message, from: identity),
            .rejected, "Un appareil que la pile v2 ne certifie pas"
        )
        XCTAssertEqual(
            makeVerifier(localDeviceId: deviceId, keys: keys).receive(vector.message, from: identity),
            .rejected, "L'appareil local ne rejoint qu'une fois"
        )
    }

    func testIdentityNeverSwitchesDeviceDuringTheCall() throws {
        let vector = try loadVector()
        let tabletKey = P256.Signing.PrivateKey()
        let tabletId = "device_bruno_tablet_01J7ABCD"
        let tablet = makeVerifier(localUserId: userId, localDeviceId: tabletId, signingKey: tabletKey, keys: [:])
        let tabletProof = try tablet.localProof(livekitIdentity: identity, joinedAtMs: 1_790_000_003_000)

        let verifier = makeVerifier(keys: [owner(deviceId): vector.publicKey, owner(tabletId): tabletKey.publicKey])
        XCTAssertEqual(verifier.receive(vector.message, from: identity), .proven)
        XCTAssertEqual(verifier.receive(tabletProof, from: identity), .rejected)
    }

    func testLocalProofIsAcceptedByTheOtherParticipants() throws {
        let aliceKey = P256.Signing.PrivateKey()
        let aliceUser = "user_alice_01J7ABCD23456789"
        let aliceDevice = "device_alice_ios_01J7ABCD2345"
        let alice = makeVerifier(localUserId: aliceUser, localDeviceId: aliceDevice, signingKey: aliceKey, keys: [:])
        let message = try alice.localProof(livekitIdentity: "lk_user_alice_01J7ABCD23456789", joinedAtMs: 1_790_000_001_000)

        let signed = try E2EEV2CallJoinProof.readMessage(message)
        XCTAssertEqual(E2EEV2CallJoinProof.message(signed), message, "JSON canonique, deux clés")
        let bruno = makeVerifier(localDeviceId: deviceId, keys: ["\(aliceUser)/\(aliceDevice)": aliceKey.publicKey])
        XCTAssertEqual(bruno.receive(message, from: "lk_user_alice_01J7ABCD23456789"), .proven)

        XCTAssertThrowsError(
            try alice.localProof(livekitIdentity: "", joinedAtMs: 1_790_000_001_000),
            "Jamais de preuve que les autres refuseraient"
        )
    }

    func testMissingProofTenSecondsAfterAnArrivalEndsTheCall() throws {
        let vector = try loadVector()
        let verifier = makeVerifier(keys: [owner(deviceId): vector.publicKey])
        let arrival = Date(timeIntervalSince1970: 1_790_000_000)

        verifier.expect(identity, at: arrival)
        verifier.expect(identity, at: arrival.addingTimeInterval(5))
        XCTAssertEqual(verifier.overdue(at: arrival.addingTimeInterval(9.9)), [])
        XCTAssertEqual(verifier.overdue(at: arrival.addingTimeInterval(10)), [identity], "Le délai part de la première arrivée")

        XCTAssertEqual(verifier.receive(vector.message, from: identity), .proven)
        XCTAssertEqual(verifier.overdue(at: arrival.addingTimeInterval(60)), [])

        verifier.expect("lk_user_carla_01J7ABCD23456789", at: arrival)
        verifier.remove("lk_user_carla_01J7ABCD23456789")
        XCTAssertEqual(verifier.overdue(at: arrival.addingTimeInterval(60)), [], "Parti avant son délai")
    }

    #if canImport(LiveKit)
    func testProvenCallShowsOnlyProvenParticipants() {
        let verification = E2EEV2LiveKitVerification(requiresJoinProof: true)
        verification.expectParticipant("local")
        verification.expect(participantID: "local", trackID: "local-audio")
        verification.update("local-audio", state: .ok)
        verification.expectParticipant("remote")
        verification.expect(participantID: "remote", trackID: "remote-audio")
        verification.update("remote-audio", state: .ok)
        XCTAssertFalse(verification.isVerified, "Pistes déchiffrées, mais aucun appareil prouvé")
        XCTAssertFalse(verification.isTrackVerified("remote-audio"), "Rien n'est joué d'un participant non prouvé")

        verification.markJoinProven("remote")
        XCTAssertTrue(verification.isTrackVerified("remote-audio"))
        XCTAssertFalse(verification.isVerified, "Notre propre preuve n'est pas encore partie")
        verification.markJoinProven("local")
        XCTAssertTrue(verification.isVerified)

        verification.markAllPending()
        XCTAssertFalse(verification.isVerified)
        verification.update("local-audio", state: .ok)
        verification.update("remote-audio", state: .ok)
        XCTAssertTrue(verification.isVerified, "Une reconnexion ne change pas l'appareil d'une identité")

        verification.markDataVerified("observer")
        XCTAssertFalse(verification.isVerified, "Un paquet quelconque ne prouve rien")
    }

    func testSessionRequiresProofsOnlyWithAJoinConfiguration() throws {
        let epochKey = Data((0..<32).map { UInt8($0) })
        let context = E2EEV2CallFrameKeyContext(
            conversationId: "conv_0123456789abcdef", epochNumber: 1, callId: "call_0123456789abcdef"
        )
        XCTAssertNil(try E2EEV2LiveKitSession.make(epochKey: epochKey, context: context).joinVerifier)
        let join = E2EEV2CallJoinConfiguration(
            context: .init(conversationId: conversationId, callId: callId, callNonceB64: callNonceB64),
            userId: userId,
            deviceId: deviceId,
            sign: { _ in Data() },
            deviceSigningKey: { _, _ in nil }
        )
        XCTAssertNotNil(try E2EEV2LiveKitSession.make(epochKey: epochKey, context: context, join: join).joinVerifier)
    }
    #endif

    // MARK: - Outils

    private struct Vector {
        let publicKey: P256.Signing.PublicKey
        let message: Data
        let negatives: [(String, Data)]
    }

    private func loadVector() throws -> Vector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-v2/call-join-proof-v1.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(json["signingPublicX963B64"] as? String)))
        )
        let message = Data(try XCTUnwrap(json["messageUtf8"] as? String).utf8)
        let negatives = try XCTUnwrap(json["negative"] as? [[String: Any]]).map { negative in
            (negative["case"] as? String ?? "cas négatif", Data(try XCTUnwrap(negative["messageUtf8"] as? String).utf8))
        }
        return Vector(publicKey: publicKey, message: message, negatives: negatives)
    }

    /// Clé de `keys` pour un appareil de Bruno.
    private func owner(_ device: String) -> String {
        "\(userId)/\(device)"
    }

    /// Vérificateur d'un participant ; `keys` associe « utilisateur/appareil »
    /// à la clé de signature que la pile v2 certifie.
    private func makeVerifier(
        context: E2EEV2CallJoinContext? = nil,
        localUserId: String = "user_alice_01J7ABCD23456789",
        localDeviceId: String = "device_alice_ios_01J7ABCD2345",
        signingKey: P256.Signing.PrivateKey? = nil,
        keys: [String: P256.Signing.PublicKey]
    ) -> E2EEV2CallJoinVerifier {
        let signingKeyRaw = signingKey?.rawRepresentation
        let publicKeys = keys.mapValues(\.x963Representation)
        return E2EEV2CallJoinVerifier(configuration: .init(
            context: context ?? .init(conversationId: conversationId, callId: callId, callNonceB64: callNonceB64),
            userId: localUserId,
            deviceId: localDeviceId,
            sign: { message in
                guard let signingKeyRaw else { throw E2EEV2CallFormatError.invalidSignature }
                return try E2EEV2LowS.sign(message, with: P256.Signing.PrivateKey(rawRepresentation: signingKeyRaw))
            },
            deviceSigningKey: { user, device in
                guard let raw = publicKeys["\(user)/\(device)"] else { return nil }
                return try? P256.Signing.PublicKey(x963Representation: raw)
            }
        ))
    }
}
