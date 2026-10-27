import CryptoKit
import XCTest
@testable import SignalQuest

/// Révision 15 (E2EE-AUTO §7.3) : sous une époque marquée, TEXT, EDIT et DELETE
/// partent en enveloppe v3 en `message`, `notifyUserId` vide (vecteur
/// `message-delivery-v1`, mêmes clés, `fk` et nonce que `message-envelope-v3`).
final class E2EEAutoMessageDeliveryTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/message-delivery-v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func str(_ dictionary: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(dictionary[key] as? String, "clé \(key)")
    }

    private func b64(_ dictionary: [String: Any], _ key: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: str(dictionary, key)), "clé \(key)")
    }

    /// Lu à l'octet, puis recomposé par l'app sous une époque marquée : même
    /// AAD, même chiffré, même `frankTag` ; la signature tirée ici se vérifie.
    func testMarkedEpochSendsTextEditAndDeleteAsV3Messages() throws {
        let v = try vector()
        let conversationId = try str(v, "conversationId"), senderDeviceId = try str(v, "senderDeviceId")
        let epochKey = try b64(v, "epochKeyB64")
        let signing = try P256.Signing.PrivateKey(rawRepresentation: b64(v, "senderSigningPrivateRawB64"))
        let sender = try P256.Signing.PublicKey(x963Representation: b64(v, "senderSigningPublicX963B64"))
        XCTAssertEqual(signing.publicKey.x963Representation, sender.x963Representation)
        let epoch = E2EEV2StoredEpochKey(
            conversationId: conversationId, epochId: "epoch_vector_000000000001",
            epochNumber: try XCTUnwrap(Int(str(v, "epochNumber"))),
            keyCommitmentB64: try str(v, "keyCommitmentB64"), epochKey: epochKey
        )
        let device = E2EEV2DeviceDescriptor(
            deviceId: senderDeviceId, platform: "ios", label: nil,
            publicIdentityKeyB64: try str(v, "senderSigningPublicX963B64"),
            publicSigningKeyB64: try str(v, "senderSigningPublicX963B64"),
            identityKeyAlgorithm: "P-256", signingKeyAlgorithm: "P-256", keyVersion: 1
        )
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.map { $0["case"] as? String }, ["textAsMessage", "editAsMessage", "deleteAsMessage"])
        for item in cases {
            let name = try str(item, "case")
            let wire = Data(try str(item, "wireJsonUtf8").utf8)
            let parsed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(wire), name)
            XCTAssertEqual(parsed.encoded, wire, "JSON canonique, à l'octet : \(name)")
            XCTAssertEqual(parsed.envelope.envelopeVersion, 3, name)
            XCTAssertEqual(parsed.envelope.delivery, .message, name)
            XCTAssertEqual(parsed.envelope.notifyUserId, "", name)
            XCTAssertEqual(parsed.envelope.aadB64, try str(item, "aadB64"), name)
            XCTAssertEqual(parsed.envelope.ciphertextB64, try str(item, "ciphertextB64"), name)
            XCTAssertEqual(parsed.envelope.frankTagB64, try str(item, "frankTagB64"), name)
            let context = parsed.context(conversationId: conversationId, senderDeviceId: senderDeviceId)
            XCTAssertEqual(
                try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: parsed.envelope),
                Data(try str(item, "signatureCanonicalUtf8").utf8), name
            )
            try E2EEV2MessageCryptoV2.verifySignature(
                context: context, envelope: parsed.envelope, signatureDerB64: try str(item, "signatureDerB64"), senderSigningKey: sender
            )
            let payload = Data(try str(item, "payloadUtf8").utf8)
            XCTAssertEqual(try E2EEV2MessageCryptoV2.decrypt(envelope: parsed.envelope, epochKey: epochKey, context: context).payloadBytes, payload, name)

            let composed = try E2EEV2MessageComposerV2.compose(
                payload: payload, conversationId: conversationId, clientRequestId: try str(item, "clientRequestId"),
                ttlSeconds: try XCTUnwrap(Int(str(v, "ttlSeconds"))), epoch: epoch, device: device,
                fk: b64(v, "fkB64"), nonce: b64(v, "nonceB64"), marked: true
            ) { try E2EEV2LowS.sign($0, with: signing) }
            XCTAssertEqual(composed.envelope, parsed.envelope, "recomposé à l'octet : \(name)")
            try E2EEV2MessageCryptoV2.verifySignature(
                context: context, envelope: composed.envelope, signatureDerB64: composed.senderSignatureB64, senderSigningKey: sender
            )

            let unmarked = try E2EEV2MessageComposerV2.compose(
                payload: payload, conversationId: conversationId, clientRequestId: try str(item, "clientRequestId"),
                ttlSeconds: 0, epoch: epoch, device: device, fk: b64(v, "fkB64"), nonce: b64(v, "nonceB64")
            ) { try E2EEV2LowS.sign($0, with: signing) }
            XCTAssertEqual(unmarked.envelope.envelopeVersion, 2, "sous une époque non marquée, rien ne change : \(name)")
        }
    }
}
