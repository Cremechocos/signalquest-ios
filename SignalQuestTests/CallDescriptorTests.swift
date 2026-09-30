import CryptoKit
import XCTest
@testable import SignalQuest

/// IOS-CALL-1 (plan 3, jalon A) : descripteur d'appel signé par l'appareil
/// appelant, relayé tel quel par le serveur dans `e2eeV2` (spec §10.1, D.11).
final class CallDescriptorTests: XCTestCase {
    private struct Vector {
        let callerKey: P256.Signing.PrivateKey
        let descriptor: String
        let signatureB64: String
        let e2eeV2Json: Data
        let createdAtMs: Int64
        let negatives: [[String: Any]]
    }

    private let conversationId = "conversation_01J7ABCD23456789"
    private let callId = "call_01J7ABCD23456789XY"
    private let callerDeviceId = "device_alice_ios_01J7ABCD2345"

    func testRelayedE2EEV2KeyIsReadStrictly() throws {
        let vector = try loadVector()
        let value = try JSONDecoder().decode(JSONValue.self, from: vector.e2eeV2Json)
        let parsed = try XCTUnwrap(E2EEV2SignedCallDescriptor.parse(value))
        XCTAssertEqual(parsed.signed.canonical, vector.descriptor)
        XCTAssertEqual(parsed.descriptor.callId, callId)
        XCTAssertEqual(E2EEV2SignedCallDescriptor.parse(parsed.jsonValue), parsed, "Aller-retour du corps d'initiation")

        guard case .object(var object) = value else { return XCTFail("objet attendu") }
        var extra = object
        extra["e2ee"] = .bool(true)
        XCTAssertNil(E2EEV2SignedCallDescriptor.parse(.object(extra)), "Exactement trois clés")
        object["callerDeviceId"] = .string("device_mallory_ios_01J7ABCD")
        XCTAssertNil(E2EEV2SignedCallDescriptor.parse(.object(object)), "L'appareil annoncé est celui que le descripteur signe")
    }

    func testCallerDescriptorIsSignedAndAcceptedByTheCallee() throws {
        let callerKey = P256.Signing.PrivateKey()
        let callId = try E2EEV2CallDescriptorFactory.newCallId()
        XCTAssertTrue(E2EEV2Canonical.isOpaque(callId), "Format opaque de l'annexe A.1")
        XCTAssertNotEqual(callId, try E2EEV2CallDescriptorFactory.newCallId())
        let nonce = try E2EEV2CallDescriptorFactory.newCallNonceB64()
        XCTAssertEqual(Data(base64Encoded: nonce)?.count, 32)

        let signed = try E2EEV2CallDescriptorFactory.make(
            conversationId: conversationId, callId: callId, callerDeviceId: callerDeviceId,
            epochId: "epoch_01J7ABCD23456789", epochNumber: 3, keyCommitmentB64: commitment(3),
            callNonceB64: nonce, createdAtMs: 1_790_000_000_000,
            sign: { try E2EEV2LowS.sign($0, with: callerKey) }
        )
        let result = E2EEV2CallDescriptorCheck.verify(
            signed, conversationId: conversationId, callId: callId,
            callerSigningKey: { $0 == self.callerDeviceId ? callerKey.publicKey : nil },
            latestEpoch: .init(epochId: "epoch_01J7ABCD23456789", epochNumber: 3, keyCommitmentB64: commitment(3)),
            nonces: E2EEV2CallNonceLedger(fileURL: nil), nowMs: 1_790_000_002_000, ringing: true
        )
        XCTAssertEqual(try result.get().callNonceB64, nonce)

        XCTAssertThrowsError(try E2EEV2CallDescriptorFactory.make(
            conversationId: conversationId, callId: "court", callerDeviceId: callerDeviceId,
            epochId: "epoch_01J7ABCD23456789", epochNumber: 3, keyCommitmentB64: commitment(3),
            callNonceB64: nonce, createdAtMs: 1_790_000_000_000,
            sign: { try E2EEV2LowS.sign($0, with: callerKey) }
        ), "Jamais un descripteur que l'appelé refuserait")
    }

    func testCalleeRefusesWhatSection10Point1Refuses() throws {
        let vector = try loadVector()
        let signed = try XCTUnwrap(E2EEV2SignedCallDescriptor.parse(
            try JSONDecoder().decode(JSONValue.self, from: vector.e2eeV2Json)
        ))
        let latest = E2EEV2CallDescriptorCheck.LocalEpoch(
            epochId: signed.descriptor.epochId,
            epochNumber: signed.descriptor.epochNumber,
            keyCommitmentB64: signed.descriptor.keyCommitmentB64
        )
        let callerKey = vector.callerKey.publicKey
        func check(
            conversation: String? = nil, call: String? = nil,
            key: P256.Signing.PublicKey? = nil, noKey: Bool = false,
            epoch: E2EEV2CallDescriptorCheck.LocalEpoch? = nil, noEpoch: Bool = false,
            nonces: E2EEV2CallNonceLedger = E2EEV2CallNonceLedger(fileURL: nil),
            now: Int64? = nil, ringing: Bool = true
        ) -> Result<E2EEV2CallDescriptor, E2EEV2CallDescriptorCheck.Failure> {
            E2EEV2CallDescriptorCheck.verify(
                signed,
                conversationId: conversation ?? conversationId,
                callId: call ?? callId,
                callerSigningKey: { _ in noKey ? nil : key ?? callerKey },
                latestEpoch: noEpoch ? nil : epoch ?? latest,
                nonces: nonces,
                nowMs: now ?? vector.createdAtMs + 1_000,
                ringing: ringing
            )
        }

        XCTAssertNoThrow(try check().get())
        XCTAssertEqual(check(conversation: "conversation_01J7ABCD99999999").failure, .otherCall)
        XCTAssertEqual(check(call: "call_01J7ABCD23456789ZZ").failure, .otherCall)
        XCTAssertEqual(check(noKey: true).failure, .untrustedCaller, "Appareil appelant non certifié")
        XCTAssertEqual(check(key: P256.Signing.PrivateKey().publicKey).failure, .invalidSignature)
        XCTAssertEqual(check(now: vector.createdAtMs + 61_000).failure, .expired, "Sonnerie de plus de 60 s")
        XCTAssertNoThrow(try check(now: vector.createdAtMs + 600_000, ringing: false).get(), "Jonction tardive d'un appel actif")
        let newer = E2EEV2CallDescriptorCheck.LocalEpoch(
            epochId: "epoch_01J7ABCD99999999", epochNumber: latest.epochNumber + 1, keyCommitmentB64: commitment(9)
        )
        XCTAssertEqual(check(epoch: newer).failure, .notLatestEpoch, "Pas la plus récente époque connue")
        XCTAssertEqual(check(noEpoch: true).failure, .notLatestEpoch)

        let nonces = E2EEV2CallNonceLedger(fileURL: nil)
        XCTAssertTrue(nonces.claim(signed.descriptor.callNonceB64, callId: "call_01J7ABCD23456789AA", nowMs: vector.createdAtMs))
        XCTAssertEqual(check(nonces: nonces).failure, .replayedNonce, "Un nonce déjà vu pour un autre appel")

        for negative in vector.negatives {
            let name = negative["case"] as? String ?? "cas négatif"
            let descriptor = negative["descriptorUtf8"] as? String ?? vector.descriptor
            let signature = negative["signatureDerB64"] as? String ?? vector.signatureB64
            let now = (negative["nowMs"] as? String).flatMap(Int64.init) ?? vector.createdAtMs + 1_000
            let candidate = E2EEV2SignedCallDescriptor.parse(.object([
                "descriptor": .string(descriptor),
                "signatureB64": .string(signature),
                "callerDeviceId": .string(callerDeviceId),
            ]))
            guard let candidate else { continue } // refusé dès la lecture
            let result = E2EEV2CallDescriptorCheck.verify(
                candidate, conversationId: conversationId, callId: callId,
                callerSigningKey: { _ in callerKey }, latestEpoch: latest,
                nonces: E2EEV2CallNonceLedger(fileURL: nil), nowMs: now, ringing: true
            )
            XCTAssertNotNil(result.failure, name)
        }
    }

    func testNonceLedgerSurvivesARelaunchAndForgetsAfterAWeek() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallNonces-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let nonce = Data(repeating: 7, count: 32).base64EncodedString()
        let start: Int64 = 1_790_000_000_000

        XCTAssertTrue(E2EEV2CallNonceLedger(fileURL: file).claim(nonce, callId: "call_A", nowMs: start))
        let relaunched = E2EEV2CallNonceLedger(fileURL: file)
        XCTAssertTrue(relaunched.claim(nonce, callId: "call_A", nowMs: start + 1_000), "Notification relivrée")
        XCTAssertFalse(relaunched.claim(nonce, callId: "call_B", nowMs: start + 2_000), "Réveil par PushKit : le nonce reste connu")
        XCTAssertTrue(
            relaunched.claim(nonce, callId: "call_B", nowMs: start + E2EEV2CallNonceLedger.retentionMs),
            "Oublié au bout de sept jours"
        )
    }

    #if canImport(LiveKit)
    func testFrameKeyV2ComesFromTheSignedDescriptorAndItsNonce() throws {
        let url = vectorURL("call-frame-key-v2")
        let v = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        let epochKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(v["epochKeyB64"])))
        let descriptor = E2EEV2CallDescriptor(
            conversationId: try XCTUnwrap(v["conversationId"]),
            callId: try XCTUnwrap(v["callId"]),
            callerDeviceId: callerDeviceId,
            epochId: "epoch_01J7ABCD23456789",
            epochNumber: try XCTUnwrap(Int(try XCTUnwrap(v["epochNumber"]))),
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey),
            callNonceB64: try XCTUnwrap(v["callNonceB64"]),
            createdAtMs: 1_790_000_000_000
        )
        let session = try E2EEV2LiveKitSession.make(epochKey: epochKey, descriptor: descriptor, join: nil)
        XCTAssertEqual(session.keyProvider.exportKey(index: 0), Data(try XCTUnwrap(v["livekitPassphrase"]).utf8))

        let otherEpoch = E2EEV2CallDescriptor(
            conversationId: descriptor.conversationId, callId: descriptor.callId,
            callerDeviceId: callerDeviceId, epochId: descriptor.epochId, epochNumber: descriptor.epochNumber,
            keyCommitmentB64: commitment(9), callNonceB64: descriptor.callNonceB64, createdAtMs: descriptor.createdAtMs
        )
        XCTAssertThrowsError(
            try E2EEV2LiveKitSession.make(epochKey: epochKey, descriptor: otherEpoch, join: nil),
            "La clé d'époque doit être celle que le descripteur désigne"
        )
    }
    #endif

    // MARK: - Outils

    private func commitment(_ seed: UInt8) -> String {
        (try? E2EEV2EpochCrypto.keyCommitment(Data(repeating: seed, count: 32))) ?? ""
    }

    private func vectorURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-v2/\(name).json")
    }

    private func loadVector() throws -> Vector {
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL("call-descriptor-v1"))) as? [String: Any]
        )
        func string(_ key: String) throws -> String { try XCTUnwrap(json[key] as? String, key) }
        return Vector(
            callerKey: try P256.Signing.PrivateKey(
                rawRepresentation: try XCTUnwrap(Data(base64Encoded: try string("callerSigningPrivateRawB64")))
            ),
            descriptor: try string("descriptorUtf8"),
            signatureB64: try string("signatureDerB64"),
            e2eeV2Json: Data(try string("e2eeV2JsonUtf8").utf8),
            createdAtMs: try XCTUnwrap(Int64(try string("createdAtMs"))),
            negatives: try XCTUnwrap(json["negative"] as? [[String: Any]])
        )
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
