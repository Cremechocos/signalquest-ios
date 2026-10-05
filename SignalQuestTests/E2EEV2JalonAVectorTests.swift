import XCTest
import CryptoKit
@testable import SignalQuest

/// Vecteurs de référence du jalon A (spec E2EE, annexe D, ticket COM-0).
///
/// - `testGenerateJalonAVectors` écrit les vecteurs dans `contracts/e2ee-v2/`,
///   seulement avec `SQ_E2EE_GENERATE_VECTORS=1` (passer
///   `TEST_RUNNER_SQ_E2EE_GENERATE_VECTORS=1` à xcodebuild). Clés et aléas sont
///   fixés ; l'ECDSA de CryptoKit reste aléatoire, donc une régénération change
///   les signatures : on ne régénère que volontairement.
/// - Les autres tests relisent chaque vecteur, recalculent tout ce qui est
///   déterministe, vérifient les signatures (validité et forme low-S, jamais
///   l'égalité) et rejouent les cas négatifs, qui doivent tous échouer.
final class E2EEV2JalonAVectorTests: XCTestCase {

    // MARK: Constantes des vecteurs

    private let userA = "user_alice_01J7ABCD23456789"
    private let userB = "user_bruno_01J7ABCD23456789"
    private let deviceA1 = "device_alice_ios_01J7ABCD2345"
    private let deviceA2 = "device_alice_web_01J7ABCD2345"
    private let deviceB1 = "device_bruno_android_01J7ABCD"
    private let conversationId = "conversation_01J7ABCD23456789"
    private let createdAtMs: Int64 = 1_790_000_000_000

    // MARK: Génération

    func testGenerateJalonAVectors() throws {
        guard ProcessInfo.processInfo.environment["SQ_E2EE_GENERATE_VECTORS"] == "1" else {
            throw XCTSkip("Génération des vecteurs : SQ_E2EE_GENERATE_VECTORS=1")
        }
        let vectors: [(String, VJ)] = [
            ("device-cert-v1", try buildDeviceCert()),
            ("device-list-v1", try buildDeviceList()),
            ("device-capabilities-v1", try buildCapabilities()),
            ("uik-wrap-v1", try buildUIKWrap()),
            ("epoch-manifest-v2", try buildEpochManifest()),
            ("epoch-binding-v1", try buildEpochBinding()),
            ("membership-change-v1", try buildMembership()),
            ("message-ref-v1", buildMessageRef()),
            ("message-envelope-v2", try buildMessageEnvelopeV2()),
            ("content-payload-v2", try buildContentPayloadV2()),
            ("franking-v1", buildFranking()),
            ("report-v1", try buildReport()),
            ("call-descriptor-v1", try buildCallDescriptor()),
            ("call-frame-key-v2", try buildCallFrameKey()),
            ("call-join-proof-v1", try buildJoinProof()),
            ("device-approval-v2", try buildApprovalV2()),
            ("safety-number-v1", try buildSafetyNumber()),
            ("identity-reset-v1", try buildIdentityReset()),
            ("capability-intersection-v1", buildCapabilityIntersection()),
        ]
        for (name, value) in vectors {
            try Data((render(value) + "\n").utf8).write(to: vectorURL(name))
        }
        try reissueLowS(name: "epoch-envelope-v1", path: ["signatureDerB64"])
        try reissueLowS(name: "recovery-epoch-envelope-v1", path: ["envelope", "signatureB64"])
        try reissueLowS(name: "signed-request-v1", path: ["signatureDerB64"])
        try regenerateMessageEnvelopeV1()
    }

    // MARK: Briques

    func testCanonicalJSONIsStrict() throws {
        let doc: E2EEV2JSON = .object(["b": .string("é\n\"/"), "a": .array([.null, .bool(true)])])
        let text = E2EEV2CanonicalJSON.encodeString(doc)
        XCTAssertEqual(text, #"{"a":[null,true],"b":"é\n\"/"}"#)
        XCTAssertEqual(try E2EEV2CanonicalJSON.parseCanonical(text), doc)
        XCTAssertThrowsError(try E2EEV2CanonicalJSON.parseCanonical(#"{"a":"1","a":"2"}"#)) {
            XCTAssertEqual($0 as? E2EEV2CanonicalJSONError, .duplicateKey)
        }
        XCTAssertThrowsError(try E2EEV2CanonicalJSON.parseCanonical(#"{"a":1}"#)) {
            XCTAssertEqual($0 as? E2EEV2CanonicalJSONError, .unsupportedNumber)
        }
        XCTAssertThrowsError(try E2EEV2CanonicalJSON.parseCanonical(#"{"a":"\ud800"}"#)) {
            XCTAssertEqual($0 as? E2EEV2CanonicalJSONError, .loneSurrogate)
        }
        XCTAssertThrowsError(try E2EEV2CanonicalJSON.parseCanonical(#"{"b":"1","a":"2"}"#)) {
            XCTAssertEqual($0 as? E2EEV2CanonicalJSONError, .notCanonical)
        }
        XCTAssertThrowsError(try E2EEV2CanonicalJSON.parseCanonical(#"{ "a":"1"}"#)) {
            XCTAssertEqual($0 as? E2EEV2CanonicalJSONError, .notCanonical)
        }
        // RFC 8785 : tri par unités de code UTF-16, pas par points de code.
        let order = E2EEV2CanonicalJSON.encodeString(.object(["\u{E000}": .null, "\u{1F600}": .null]))
        XCTAssertEqual(order, "{\"\u{1F600}\":null,\"\u{E000}\":null}")
    }

    func testLowSNormalisationKeepsSignatureValidAndRejectsHighS() throws {
        let key = try signingKey(0x31)
        let message = Data("SQ-E2EE-V2 low-S".utf8)
        for _ in 0..<16 {
            let low = try E2EEV2LowS.sign(message, with: key)
            XCTAssertTrue(E2EEV2LowS.isLowS(der: low))
            XCTAssertTrue(E2EEV2LowS.verify(derSignature: low, message: message, publicKey: key.publicKey))
            let high = try E2EEV2LowS.highSVariant(der: low)
            XCTAssertFalse(E2EEV2LowS.isLowS(der: high))
            // CryptoKit accepte le high-S : c'est notre vérificateur qui le refuse.
            XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: high), for: message))
            XCTAssertFalse(E2EEV2LowS.verify(derSignature: high, message: message, publicKey: key.publicKey))
            XCTAssertEqual(try E2EEV2LowS.normalize(der: high), low)
        }
    }

    func testHPKEMatchesRFC9180AppendixA3() throws {
        // RFC 9180 A.3 : DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-128-GCM.
        let ikmE = hex("4270e54ffd08d79d5928020af4686d8f6b7d35dbe470265f1f5aa22816ce860e")
        let ikmR = hex("668b37171f1072f3cf12ea8a236a45df23fc13b82af3609ad1e354f6ef817550")
        let skE = try E2EEV2HPKE.deriveKeyPair(ikm: ikmE)
        let skR = try E2EEV2HPKE.deriveKeyPair(ikm: ikmR)
        XCTAssertEqual(skE.rawRepresentation, hex("4995788ef4b9d6132b249ce59a77281493eb39af373d236a1fe415cb0c2d7beb"))
        XCTAssertEqual(skR.rawRepresentation, hex("f3ce7fdae57e1a310d87f1ebbde6f328be0a99cdbcadf4d6589cf29de4b8ffd2"))
        XCTAssertEqual(skR.publicKey.x963Representation, hex(
            "04fe8c19ce0905191ebc298a9245792531f26f0cece2460639e8bc39cb7f706a826a779b4cf969b8a0e539c7f62fb3d30ad6aa8f80e30f1d128aafd68a2ce72ea0"
        ))
        let (sharedSecret, enc) = try E2EEV2HPKE.encapsulate(recipient: skR.publicKey, ephemeral: skE)
        XCTAssertEqual(enc, hex(
            "04a92719c6195d5085104f469a8b9814d5838ff72b60501e2c4466e5e67b325ac98536d7b61a1af4b78e5b7f951c0900be863c403ce65c9bfcb9382657222d18c4"
        ))
        XCTAssertEqual(sharedSecret, hex("c0d26aeab536609a572b07695d933b589dcf363ff9d93c93adea537aeabb8cb8"))
        XCTAssertEqual(try E2EEV2HPKE.decapsulate(enc: enc, recipient: skR), sharedSecret)
        let info = hex("4f6465206f6e2061204772656369616e2055726e")
        let context = E2EEV2HPKE.keySchedule(sharedSecret: sharedSecret, info: info, aead: .aes128GCM)
        XCTAssertEqual(context.keyScheduleContext, hex(
            "00b88d4e6d91759e65e87c470e8b9141113e9ad5f0c8ceefc1e088c82e6980500798e486f9c9c09c9b5c753ac72d6005de254c607d1b534ed11d493ae1c1d9ac85"
        ))
        XCTAssertEqual(context.secret, hex("2eb7b6bf138f6b5aff857414a058a3f1750054a9ba1f72c2cf0684a6f20b10e1"))
        XCTAssertEqual(context.key, hex("868c066ef58aae6dc589b6cfdd18f97e"))
        XCTAssertEqual(context.baseNonce, hex("4e0bc5018beba4bf004cca59"))
        let sealed = try E2EEV2HPKE.seal(
            recipient: skR.publicKey,
            info: info,
            aad: hex("436f756e742d30"),
            plaintext: hex("4265617574792069732074727574682c20747275746820626561757479"),
            aead: .aes128GCM,
            ephemeral: skE
        )
        XCTAssertEqual(sealed.ciphertext, hex(
            "5ad590bb8baa577f8619db35a36311226a896e7342a6d836d8b7bcd2f20b6c7f9076ac232e3ab2523f39513434"
        ))
        XCTAssertEqual(
            try E2EEV2HPKE.open(enc: enc, recipient: skR, info: info, aad: hex("436f756e742d30"), ciphertext: sealed.ciphertext, aead: .aes128GCM),
            hex("4265617574792069732074727574682c20747275746820626561757479")
        )
    }

    func testHPKEAES256InteroperatesWithCryptoKit() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("HPKE de CryptoKit : iOS 17 et plus") }
        let recipient = P256.KeyAgreement.PrivateKey()
        let info = Data("SQ-E2EE-V2-REPORT\n1\ncontre-épreuve".utf8)
        let message = Data("signalement".utf8)
        // Notre chiffrement, ouvert par CryptoKit.
        let ours = try E2EEV2HPKE.seal(recipient: recipient.publicKey, info: info, aad: Data(), plaintext: message)
        var kitRecipient = try HPKE.Recipient(
            privateKey: recipient, ciphersuite: .P256_SHA256_AES_GCM_256, info: info, encapsulatedKey: ours.enc
        )
        XCTAssertEqual(try kitRecipient.open(ours.ciphertext), message)
        // Le chiffrement de CryptoKit, ouvert par nous.
        var kitSender = try HPKE.Sender(recipientKey: recipient.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info)
        let theirs = try kitSender.seal(message)
        XCTAssertEqual(
            try E2EEV2HPKE.open(enc: kitSender.encapsulatedKey, recipient: recipient, info: info, aad: Data(), ciphertext: theirs),
            message
        )
    }

    // MARK: Vérification des vecteurs

    func testDeviceCertVector() throws {
        let v = try load("device-cert-v1")
        let uik = try signingKey(fromB64: str(v, "uikPrivateRawB64"))
        XCTAssertEqual(uik.publicKey.x963Representation.base64EncodedString(), try str(v, "uikPublicX963B64"))
        let identity = try agreementKey(fromB64: str(v, "identityPrivateRawB64"))
        let signing = try signingKey(fromB64: str(v, "signingPrivateRawB64"))
        let certificate = E2EEV2DeviceCertificate(
            userId: try str(v, "userId"), deviceId: try str(v, "deviceId"), keyVersion: try int(v, "keyVersion"),
            identityKeyB64: identity.publicKey.x963Representation.base64EncodedString(),
            signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            platform: try str(v, "platform"), createdAtMs: try int64(v, "createdAtMs")
        )
        XCTAssertEqual(certificate.canonical, try str(v, "certificateUtf8"))
        XCTAssertEqual(certificate.fingerprint, try str(v, "fingerprint"))
        let signed = E2EEV2SignedString(canonical: try str(v, "certificateUtf8"), signatureB64: try str(v, "signatureDerB64"))
        XCTAssertEqual(try E2EEV2DeviceCertificate.verify(signed, uik: uik.publicKey), certificate)
        try forEachNegative(v) { neg in
            let key = try P256.Signing.PublicKey(x963Representation: b64(neg, "uikPublicX963B64", default: v))
            let candidate = E2EEV2SignedString(
                canonical: try str(neg, "certificateUtf8", default: v),
                signatureB64: try str(neg, "signatureDerB64", default: v)
            )
            XCTAssertThrowsError(try E2EEV2DeviceCertificate.verify(candidate, uik: key), caseName(neg))
        }
    }

    func testDeviceListVector() throws {
        let v = try load("device-list-v1")
        let uik = try P256.Signing.PublicKey(x963Representation: b64(v, "uikPublicX963B64"))
        let v1 = E2EEV2SignedString(canonical: try str(v, "listV1Utf8"), signatureB64: try str(v, "signatureV1DerB64"))
        let v2 = E2EEV2SignedString(canonical: try str(v, "listV2Utf8"), signatureB64: try str(v, "signatureV2DerB64"))
        let first = try E2EEV2DeviceList.verify(v1, entries: try strings(v, "entriesV1"), uik: uik, previousCanonical: nil)
        XCTAssertEqual(first.version, 1)
        XCTAssertEqual(E2EEV2DeviceList.digest(of: v1.canonical), try str(v, "digestV1"))
        let second = try E2EEV2DeviceList.verify(v2, entries: try strings(v, "entriesV2"), uik: uik, previousCanonical: v1.canonical)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(second.previousListDigest, try str(v, "digestV1"))
        try forEachNegative(v) { neg in
            let candidate = E2EEV2SignedString(canonical: try str(neg, "listUtf8"), signatureB64: try str(neg, "signatureDerB64"))
            let previous = neg["previousUtf8"] as? String
            XCTAssertThrowsError(
                try E2EEV2DeviceList.verify(candidate, entries: try strings(neg, "entries"), uik: uik, previousCanonical: previous),
                caseName(neg)
            )
        }
    }

    func testCapabilitiesVector() throws {
        let v = try load("device-capabilities-v1")
        let signing = try P256.Signing.PublicKey(x963Representation: b64(v, "signingPublicX963B64"))
        let document = try str(v, "documentUtf8")
        let parsed = try E2EEV2CapabilitiesDocument.parse(document: document)
        XCTAssertEqual(parsed.document, document)
        XCTAssertEqual(E2EEV2Canonical.sha256B64URL(Data(document.utf8)), try str(v, "documentSha256B64Url"))
        let canonical = E2EEV2CapabilitiesDocument.signatureCanonical(document: document)
        XCTAssertEqual(canonical, try str(v, "signatureCanonicalUtf8"))
        XCTAssertTrue(E2EEV2SignedString(canonical: canonical, signatureB64: try str(v, "signatureDerB64")).verify(with: signing))
        try forEachNegative(v) { neg in
            XCTAssertThrowsError(try E2EEV2CapabilitiesDocument.parse(document: str(neg, "documentUtf8")), caseName(neg))
        }
    }

    func testUIKWrapVector() throws {
        let v = try load("uik-wrap-v1")
        let uik = try signingKey(fromB64: str(v, "uikPrivateRawB64"))
        let approver = try signingKey(fromB64: str(v, "approverSigningPrivateRawB64"))
        let newDevice = try agreementKey(fromB64: str(v, "newDeviceAgreementPrivateRawB64"))
        let ephemeral = try agreementKey(fromB64: str(v, "ephemeralPrivateRawB64"))
        let rebuilt = try E2EEV2UIKWrapCrypto.wrap(
            uik: uik, userId: str(v, "userId"), approverDeviceId: str(v, "approverDeviceId"),
            newDeviceId: str(v, "newDeviceId"), newDeviceAgreementKey: newDevice.publicKey,
            approverSigningKey: approver, ephemeral: ephemeral, nonce: b64(v, "nonceB64")
        )
        XCTAssertEqual(rebuilt.aadB64, try str(v, "aadB64"))
        XCTAssertEqual(rebuilt.wrappedUikB64, try str(v, "wrappedUikB64"))
        XCTAssertEqual(
            E2EEV2UIKWrapCrypto.salt(userId: try str(v, "userId"), approverDeviceId: try str(v, "approverDeviceId"), newDeviceId: try str(v, "newDeviceId")).base64EncodedString(),
            try str(v, "saltB64")
        )
        let stored = try wrap(from: v)
        XCTAssertEqual(E2EEV2UIKWrapCrypto.signatureCanonical(stored), try str(v, "signatureCanonicalUtf8"))
        let opened = try E2EEV2UIKWrapCrypto.unwrap(
            stored, newDeviceAgreementKey: newDevice, approverSigningKey: approver.publicKey,
            expectedUIKB64: try str(v, "uikPublicX963B64")
        )
        XCTAssertEqual(opened.rawRepresentation, uik.rawRepresentation)
        try forEachNegative(v) { neg in
            XCTAssertThrowsError(try E2EEV2UIKWrapCrypto.unwrap(
                try wrap(from: v, overrides: neg), newDeviceAgreementKey: newDevice,
                approverSigningKey: approver.publicKey,
                expectedUIKB64: try str(neg, "expectedUikB64", default: v, fallbackKey: "uikPublicX963B64")
            ), caseName(neg))
        }
    }

    func testEpochManifestVector() throws {
        let v = try load("epoch-manifest-v2")
        let creator = try P256.Signing.PublicKey(x963Representation: b64(v, "creatorSigningPublicX963B64"))
        let recipients = try strings(v, "recipients")
        let rebuilt = E2EEV2EpochManifest.make(
            conversationId: try str(v, "conversationId"), epochNumber: try int(v, "epochNumber"),
            creatorUserId: try str(v, "creatorUserId"), creatorDeviceId: try str(v, "creatorDeviceId"),
            keyCommitmentB64: try str(v, "keyCommitmentB64"), recipients: recipients,
            excludesWeb: try str(v, "excludesWeb") == "1",
            membershipChangeNumber: try int(v, "membershipChangeNumber"),
            membershipDigest: try str(v, "membershipDigest"), createdAtMs: try int64(v, "createdAtMs")
        )
        XCTAssertEqual(rebuilt.canonical, try str(v, "manifestUtf8"))
        XCTAssertEqual(rebuilt.recipientsDigest, try str(v, "recipientsDigest"))
        XCTAssertEqual(try E2EEV2EpochCrypto.keyCommitment(b64(v, "epochKeyB64")), try str(v, "keyCommitmentB64"))
        let signed = E2EEV2SignedString(canonical: try str(v, "manifestUtf8"), signatureB64: try str(v, "signatureDerB64"))
        XCTAssertEqual(try E2EEV2EpochManifest.verify(signed, recipients: recipients, creatorSigningKey: creator), rebuilt)
        let wire = E2EEV2EpochManifest.json(signed, recipients: recipients)
        XCTAssertEqual(E2EEV2EpochManifest.signed(from: wire)?.manifest, signed)
        XCTAssertEqual(E2EEV2EpochManifest.signed(from: wire)?.recipients, recipients)
        try forEachNegative(v) { neg in
            let candidate = E2EEV2SignedString(
                canonical: try str(neg, "manifestUtf8", default: v),
                signatureB64: try str(neg, "signatureDerB64", default: v)
            )
            let negRecipients = (neg["recipients"] as? [String]) ?? recipients
            XCTAssertThrowsError(try E2EEV2EpochManifest.verify(candidate, recipients: negRecipients, creatorSigningKey: creator), caseName(neg))
        }
    }

    /// v0.4.7 : une époque engage l'état d'appartenance ; l'époque 1, sa genèse.
    func testEpochBindingVector() throws {
        let v = try load("epoch-binding-v1")
        var keys: [String: P256.Signing.PublicKey] = [:]
        for device in try XCTUnwrap(v["devices"] as? [[String: Any]]) {
            keys["\(try str(device, "userId"))/\(try str(device, "deviceId"))"] =
                try P256.Signing.PublicKey(x963Representation: b64(device, "signingPublicX963B64"))
        }
        func signedChain(_ items: [[String: Any]]) throws -> [E2EEV2SignedString] {
            try items.map { E2EEV2SignedString(canonical: try str($0, "changeUtf8"), signatureB64: try str($0, "signatureDerB64")) }
        }
        let chain = try signedChain(try XCTUnwrap(v["chain"] as? [[String: Any]]))
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for item in cases {
            let name = caseName(item)
            let outcome: String
            do {
                let signed = E2EEV2SignedString(canonical: try str(item, "manifestUtf8"), signatureB64: try str(item, "signatureDerB64"))
                let recipients = try strings(item, "recipients")
                let creatorFields = signed.canonical.components(separatedBy: "\n")
                let creatorKey = try XCTUnwrap(keys["\(creatorFields[4])/\(creatorFields[5])"], name)
                let manifest = try E2EEV2EpochManifest.verify(signed, recipients: recipients, creatorSigningKey: creatorKey)
                let caseChain = try (item["chain"] as? [[String: Any]]).map(signedChain) ?? chain
                let isGroup = try str(item, "isGroup", default: v) == "1"
                let genesisLength = manifest.epochNumber == 1 ? manifest.membershipChangeNumber : try int(v, "genesisLength")
                let previous = (item["previousMembershipChangeNumber"] as? String).flatMap(Int.init)
                do {
                    let state = try E2EEV2MembershipChain.apply(
                        Array(caseChain.prefix(manifest.membershipChangeNumber)),
                        conversationId: try str(v, "conversationId"), isGroup: isGroup,
                        genesisLength: genesisLength, signingKey: { keys["\($0)/\($1)"] }
                    )
                    try E2EEV2EpochBinding.check(
                        manifest, recipients: recipients, state: state, genesisLength: genesisLength,
                        previousMembershipChangeNumber: previous
                    )
                    outcome = "ok"
                } catch let failure as E2EEV2EpochBinding.Failure {
                    outcome = "\(failure)"
                } catch {
                    outcome = "invalidChain"
                }
            } catch {
                outcome = "invalidManifest"
            }
            XCTAssertEqual(outcome, try str(item, "expected"), name)
        }
    }

    func testMembershipChangeVector() throws {
        let v = try load("membership-change-v1")
        let actor = try P256.Signing.PublicKey(x963Representation: b64(v, "actorSigningPublicX963B64"))
        let chain = try XCTUnwrap(v["chain"] as? [[String: Any]])
        var previous: String?
        for link in chain {
            let signed = E2EEV2SignedString(canonical: try str(link, "changeUtf8"), signatureB64: try str(link, "signatureDerB64"))
            XCTAssertTrue(signed.verify(with: actor))
            let change = try E2EEV2MembershipChange.parse(signed.canonical, previousCanonical: previous)
            XCTAssertEqual(change.action, try str(link, "action"))
            previous = signed.canonical
        }
        try forEachNegative(v) { neg in
            XCTAssertThrowsError(
                try E2EEV2MembershipChange.parse(str(neg, "changeUtf8"), previousCanonical: neg["previousUtf8"] as? String),
                caseName(neg)
            )
        }
    }

    func testMessageRefVector() throws {
        let v = try load("message-ref-v1")
        XCTAssertEqual(
            E2EEV2MessageRef.make(conversationId: try str(v, "conversationId"), senderDeviceId: try str(v, "senderDeviceId"), clientRequestId: try str(v, "clientRequestId")),
            try str(v, "messageRef")
        )
    }

    func testMessageEnvelopeV2Vector() throws {
        let v = try load("message-envelope-v2")
        let context = try messageContextV2(v)
        let epochKey = try b64(v, "epochKeyB64")
        let payload = Data(try str(v, "payloadUtf8").utf8)
        XCTAssertEqual(E2EEV2MessageCryptoV2.saltCanonical(context), Data(try str(v, "saltCanonicalUtf8").utf8))
        XCTAssertEqual(try E2EEV2MessageCryptoV2.deriveMessageKey(epochKey: epochKey, context: context).base64EncodedString(), try str(v, "derivedKeyB64"))
        let envelope = try E2EEV2MessageCryptoV2.encrypt(
            payload: payload, fk: b64(v, "fkB64"), epochKey: epochKey, nonce: b64(v, "nonceB64"), context: context
        )
        XCTAssertEqual(envelope.frankTagB64, try str(v, "frankTagB64"))
        XCTAssertEqual(envelope.aadB64, try str(v, "aadB64"))
        XCTAssertEqual(envelope.ciphertextB64, try str(v, "ciphertextB64"))
        XCTAssertEqual(try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: envelope), Data(try str(v, "signatureCanonicalUtf8").utf8))
        let sender = try P256.Signing.PublicKey(x963Representation: b64(v, "senderSigningPublicX963B64"))
        try E2EEV2MessageCryptoV2.verifySignature(context: context, envelope: envelope, signatureDerB64: str(v, "signatureDerB64"), senderSigningKey: sender)
        let opened = try E2EEV2MessageCryptoV2.decrypt(envelope: envelope, epochKey: epochKey, context: context)
        XCTAssertEqual(opened.payloadBytes, payload)
        XCTAssertEqual(try b64(v, "ciphertextB64").count - 16, try int(v, "paddedClearLength"))
        let wire = Data(try str(v, "wireJsonUtf8").utf8)
        let parsed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(wire))
        XCTAssertEqual(parsed.envelope, envelope)
        XCTAssertEqual(parsed.senderSignatureB64, try str(v, "signatureDerB64"))
        XCTAssertEqual(parsed.encoded, wire, "JSON canonique, à l'octet")
        for neg in try XCTUnwrap(v["wireNegative"] as? [[String: Any]]) {
            let data = try b64(neg, "wireJsonB64")
            XCTAssertNil(E2EEV2SignedMessageEnvelopeV2.parse(data), caseName(neg))
            XCTAssertNil((try? E2EEV2CanonicalJSON.parseStrict(data)).flatMap(E2EEV2SignedMessageEnvelopeV2.parse), caseName(neg))
        }
        // JSON valide hors JCS : refusé comme corps d'envoi, relu une fois imbriqué.
        for neg in try XCTUnwrap(v["wireNonCanonical"] as? [[String: Any]]) {
            let data = try b64(neg, "wireJsonB64")
            XCTAssertNil(E2EEV2SignedMessageEnvelopeV2.parse(data), caseName(neg))
            XCTAssertEqual(E2EEV2SignedMessageEnvelopeV2.parse(try E2EEV2CanonicalJSON.parseStrict(data)), parsed, caseName(neg))
        }
        try forEachNegative(v) { neg in
            let candidate = envelopeV2(envelope, overrides: neg)
            let negContext = try messageContextV2(v, counterOverride: neg["contextCounter"] as? String)
            if let signature = neg["signatureDerB64"] as? String {
                XCTAssertThrowsError(try E2EEV2MessageCryptoV2.verifySignature(context: negContext, envelope: candidate, signatureDerB64: signature, senderSigningKey: sender), caseName(neg))
            } else {
                XCTAssertThrowsError(try E2EEV2MessageCryptoV2.decrypt(envelope: candidate, epochKey: epochKey, context: negContext), caseName(neg))
            }
        }
    }

    func testContentPayloadV2Vector() throws {
        let v = try load("content-payload-v2")
        for positive in try XCTUnwrap(v["valid"] as? [[String: Any]]) {
            let data = Data(try str(positive, "payloadUtf8").utf8)
            let payload = try E2EEV2ContentPayloadV2.parse(data)
            XCTAssertEqual(payload.body.kind, try str(positive, "kind"))
            XCTAssertEqual(try payload.encoded(), data)
        }
        try forEachNegative(v) { neg in
            XCTAssertThrowsError(try E2EEV2ContentPayloadV2.parse(Data(str(neg, "payloadUtf8").utf8)), caseName(neg))
        }
    }

    func testFrankingVector() throws {
        let v = try load("franking-v1")
        let frank = E2EEV2Franking.frankTag(
            fk: try b64(v, "fkB64"), conversationId: try str(v, "conversationId"), senderDeviceId: try str(v, "senderDeviceId"),
            clientRequestId: try str(v, "clientRequestId"), payload: Data(try str(v, "payloadUtf8").utf8)
        )
        XCTAssertEqual(frank.base64EncodedString(), try str(v, "frankTagB64"))
        let server = E2EEV2Franking.serverTag(
            ks: try b64(v, "ksB64"), frankTagB64: try str(v, "frankTagB64"), conversationId: try str(v, "conversationId"),
            envelopeId: try str(v, "envelopeId"), senderUserId: try str(v, "senderUserId"), senderDeviceId: try str(v, "senderDeviceId"),
            serverTimeMs: try int64(v, "serverTimeMs"), keyId: try str(v, "keyId")
        )
        XCTAssertEqual(server.base64EncodedString(), try str(v, "serverTagB64"))
    }

    func testReportVector() throws {
        let v = try load("report-v1")
        let moderation = try agreementKey(fromB64: str(v, "moderationPrivateRawB64"))
        let clear = try str(v, "clearUtf8")
        XCTAssertEqual(E2EEV2Report.info(clearJSON: clear).base64EncodedString(), try str(v, "infoB64"))
        let ephemeral = try E2EEV2HPKE.deriveKeyPair(ikm: b64(v, "ephemeralIkmB64"))
        let items = try E2EEV2Report.open(clearJSON: clear, enc: b64(v, "encB64"), sealed: b64(v, "sealedB64"), moderationKey: moderation)
        let resealed = try E2EEV2Report.seal(clearJSON: clear, items: items, moderationKey: moderation.publicKey, ephemeral: ephemeral)
        XCTAssertEqual(resealed.enc.base64EncodedString(), try str(v, "encB64"))
        XCTAssertEqual(resealed.sealed.base64EncodedString(), try str(v, "sealedB64"))
        XCTAssertEqual(String(decoding: E2EEV2Report.sealedJSON(items: items), as: UTF8.self), try str(v, "sealedPlaintextUtf8"))
        let parsed = try E2EEV2Report.parseClear(clear)
        for clearItem in parsed.items {
            let recomputed = E2EEV2Franking.serverTag(
                ks: try b64(v, "ksB64"), frankTagB64: clearItem.frankTagB64, conversationId: parsed.conversationId,
                envelopeId: clearItem.envelopeId, senderUserId: try str(v, "senderUserId"),
                senderDeviceId: try str(v, "senderDeviceId"), serverTimeMs: try int64(v, "serverTimeMs"), keyId: try str(v, "keyId")
            )
            XCTAssertEqual(recomputed.base64EncodedString(), clearItem.serverTagB64, "serverTag recalculé avec Ks")
        }
        for (item, clearItem) in zip(items, parsed.items) {
            XCTAssertTrue(E2EEV2Report.verifyFrankTag(
                item: item, clearItem: clearItem, conversationId: parsed.conversationId,
                senderDeviceId: try str(v, "senderDeviceId"), clientRequestId: try str(v, "clientRequestId")
            ))
        }
        try forEachNegative(v) { neg in
            XCTAssertThrowsError(try E2EEV2Report.open(
                clearJSON: try str(neg, "clearUtf8", default: v), enc: b64(v, "encB64"),
                sealed: b64(neg, "sealedB64", default: v), moderationKey: moderation
            ), caseName(neg))
        }
    }

    func testCallDescriptorVector() throws {
        let v = try load("call-descriptor-v1")
        let caller = try P256.Signing.PublicKey(x963Representation: b64(v, "callerSigningPublicX963B64"))
        let signed = E2EEV2SignedString(canonical: try str(v, "descriptorUtf8"), signatureB64: try str(v, "signatureDerB64"))
        let descriptor = try E2EEV2CallDescriptor.verify(signed, callerSigningKey: caller, nowMs: try int64(v, "createdAtMs") + 5_000, ringing: true)
        XCTAssertEqual(descriptor.canonical, signed.canonical)
        XCTAssertEqual(E2EEV2CanonicalJSON.encodeString(E2EEV2CallDescriptor.e2eeV2JSON(signed, callerDeviceId: descriptor.callerDeviceId)), try str(v, "e2eeV2JsonUtf8"))
        try forEachNegative(v) { neg in
            let candidate = E2EEV2SignedString(canonical: try str(neg, "descriptorUtf8", default: v), signatureB64: try str(neg, "signatureDerB64", default: v))
            let now = try ((neg["nowMs"] as? String).flatMap(Int64.init) ?? (int64(v, "createdAtMs") + 5_000))
            XCTAssertThrowsError(try E2EEV2CallDescriptor.verify(candidate, callerSigningKey: caller, nowMs: now, ringing: true), caseName(neg))
        }
    }

    func testCallFrameKeyV2Vector() throws {
        let v = try load("call-frame-key-v2")
        let key = try E2EEV2CallFrameKeyV2.derive(
            epochKey: b64(v, "epochKeyB64"), conversationId: str(v, "conversationId"), epochNumber: int(v, "epochNumber"),
            callId: str(v, "callId"), callNonceB64: str(v, "callNonceB64")
        )
        XCTAssertEqual(
            E2EEV2CallFrameKeyV2.saltCanonical(conversationId: try str(v, "conversationId"), epochNumber: try int(v, "epochNumber"), callId: try str(v, "callId"), callNonceB64: try str(v, "callNonceB64")),
            Data(try str(v, "saltCanonicalUtf8").utf8)
        )
        XCTAssertEqual(key.base64EncodedString(), try str(v, "frameKeyB64"))
        XCTAssertEqual(E2EEV2CallFrameKeyV2.livekitPassphrase(key), try str(v, "livekitPassphrase"))
        XCTAssertEqual(try str(v, "livekitPassphrase").count, 44)
    }

    func testCallJoinProofVector() throws {
        let v = try load("call-join-proof-v1")
        let signingKey = try P256.Signing.PublicKey(x963Representation: b64(v, "signingPublicX963B64"))
        let signed = try E2EEV2CallJoinProof.readMessage(Data(str(v, "messageUtf8").utf8))
        XCTAssertEqual(signed.canonical, try str(v, "proofUtf8"))
        XCTAssertTrue(signed.verify(with: signingKey))
        XCTAssertEqual(try E2EEV2CallJoinProof.parse(signed.canonical).canonical, signed.canonical)
        try forEachNegative(v) { neg in
            XCTAssertThrowsError(try {
                let candidate = try E2EEV2CallJoinProof.readMessage(Data(str(neg, "messageUtf8").utf8))
                guard candidate.verify(with: signingKey) else { throw E2EEV2CallFormatError.invalidSignature }
                _ = try E2EEV2CallJoinProof.parse(candidate.canonical)
            }(), caseName(neg))
        }
    }

    func testApprovalV2Vector() throws {
        let v = try load("device-approval-v2")
        let qr = E2EEV2ApprovalV2.QR(
            approvalId: try str(v, "approvalId"), pendingDeviceId: try str(v, "pendingDeviceId"),
            platform: try str(v, "platform"), fingerprint: try str(v, "fingerprint"),
            challengeB64Url: try str(v, "challengeB64Url"), expiresAtMs: try int64(v, "expiresAtMs")
        )
        XCTAssertEqual(qr.payload, try str(v, "qrPayload"))
        XCTAssertEqual(E2EEV2ApprovalV2.QR.parse(try str(v, "qrPayload")), qr)
        // SAS v3 : mise en gage, puis code sur les deux aléas.
        let commit = E2EEV2ApprovalV2.sasCommitment(
            userId: try str(v, "userId"), approvalId: try str(v, "approvalId"),
            pendingDeviceId: try str(v, "pendingDeviceId"), platform: try str(v, "platform"),
            fingerprint: try str(v, "fingerprint"), pendingNonceB64Url: try str(v, "pendingNonceB64Url")
        )
        XCTAssertEqual(commit, try str(v, "sasCommitB64Url"))
        XCTAssertEqual(
            E2EEV2ApprovalV2.sas(userId: try str(v, "userId"), pendingDeviceId: try str(v, "pendingDeviceId"), platform: try str(v, "platform"), fingerprint: try str(v, "fingerprint"), approvalId: try str(v, "approvalId"), pendingNonceB64Url: try str(v, "pendingNonceB64Url"), approverNonceB64Url: try str(v, "approverNonceB64Url")),
            try str(v, "sas")
        )
        let proximity = E2EEV2ApprovalV2.proximityCode(
            userId: try str(v, "userId"), approvalId: try str(v, "approvalId"),
            pendingDeviceId: try str(v, "pendingDeviceId"), platform: try str(v, "platform"),
            fingerprint: try str(v, "fingerprint"), challengeB64Url: try str(v, "challengeB64Url")
        )
        XCTAssertEqual(proximity, try str(v, "proximityCode"))
        XCTAssertTrue(E2EEV2ApprovalV2.proximityMatches(try str(v, "proximityTyped"), expected: proximity))
        try forEachNegative(v) { neg in
            if let payload = neg["qrPayload"] as? String {
                XCTAssertNil(E2EEV2ApprovalV2.QR.parse(payload), caseName(neg))
            } else if let nonce = neg["pendingNonceB64Url"] as? String {
                XCTAssertNotEqual(E2EEV2ApprovalV2.sasCommitment(
                    userId: try str(v, "userId"), approvalId: try str(v, "approvalId"),
                    pendingDeviceId: try str(v, "pendingDeviceId"), platform: try str(v, "platform"),
                    fingerprint: try str(v, "fingerprint"), pendingNonceB64Url: nonce
                ), commit, caseName(neg))
            } else {
                XCTAssertFalse(E2EEV2ApprovalV2.proximityMatches(try str(neg, "proximityTyped"), expected: proximity), caseName(neg))
            }
        }
    }

    func testSafetyNumberVector() throws {
        let v = try load("safety-number-v1")
        let uikA = try b64(v, "uikAPublicX963B64")
        let uikB = try b64(v, "uikBPublicX963B64")
        XCTAssertEqual(E2EEV2SafetyNumber.digits(uikX963: uikA, userId: try str(v, "userA")), try str(v, "digitsA"))
        XCTAssertEqual(E2EEV2SafetyNumber.digits(uikX963: uikB, userId: try str(v, "userB")), try str(v, "digitsB"))
        let pair = E2EEV2SafetyNumber.pair(userA: try str(v, "userA"), uikA: uikA, userB: try str(v, "userB"), uikB: uikB)
        XCTAssertEqual(pair, try str(v, "safetyNumber"))
        XCTAssertEqual(E2EEV2SafetyNumber.pair(userA: try str(v, "userB"), uikA: uikB, userB: try str(v, "userA"), uikB: uikA), pair)
        XCTAssertEqual(E2EEV2SafetyNumber.grouped(pair), try strings(v, "groups"))
        XCTAssertEqual(E2EEV2SafetyNumber.qrPayload(pair), try str(v, "qrPayload"))
    }

    func testIdentityResetVector() throws {
        let v = try load("identity-reset-v1")
        let signed = E2EEV2SignedString(canonical: try str(v, "resetUtf8"), signatureB64: try str(v, "signatureDerB64"))
        let reset = try E2EEV2IdentityReset.verify(signed)
        XCTAssertEqual(reset.previousUikFingerprint, try str(v, "previousUikFingerprint"))
        let objector = try P256.Signing.PublicKey(x963Representation: b64(v, "objectingSigningPublicX963B64"))
        let objection = E2EEV2SignedString(canonical: try str(v, "objectionUtf8"), signatureB64: try str(v, "objectionSignatureDerB64"))
        XCTAssertTrue(objection.verify(with: objector))
        try forEachNegative(v) { neg in
            let candidate = E2EEV2SignedString(canonical: try str(neg, "resetUtf8", default: v), signatureB64: try str(neg, "signatureDerB64", default: v))
            XCTAssertThrowsError(try E2EEV2IdentityReset.verify(candidate), caseName(neg))
        }
    }

    /// §12 : ce que savent faire tous les appareils pris en compte, avec les
    /// mises à l'écart, l'exclusion des navigateurs et les membres refusés.
    func testCapabilityIntersectionVector() throws {
        let v = try load("capability-intersection-v1")
        XCTAssertEqual(try int64(v, "freshnessMs"), E2EEV2IdentityVerification.capabilityFreshnessMs)
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for item in cases {
            let name = caseName(item)
            var devicesByUser: [String: [E2EEV2CertifiedDevice]] = [:]
            var refusals: [String: E2EEV2IdentityVerification.Failure] = [:]
            for member in try XCTUnwrap(item["members"] as? [[String: Any]], name) {
                let userId = try str(member, "userId")
                if try str(member, "refused") == "1" { refusals[userId] = .uikChanged }
                devicesByUser[userId] = try XCTUnwrap(member["devices"] as? [[String: Any]], name).map { device in
                    E2EEV2CertifiedDevice(
                        userId: userId, deviceId: try str(device, "deviceId"), keyVersion: 1,
                        platform: try str(device, "platform"), identityKeyB64: "", signingKeyB64: "", fingerprint: "",
                        capabilities: try (device["capabilities"] as? String).map { try E2EEV2CapabilitiesDocument.parse(document: $0) }
                    )
                }
            }
            let intersection = E2EEV2CertifiedDeviceSet(devicesByUser: devicesByUser, refusals: refusals)
                .capabilityIntersection(nowMs: try int64(item, "nowMs"), excludesWeb: try str(item, "excludesWeb") == "1")
            let expected = try XCTUnwrap(item["expected"] as? [String: Any], name)
            guard try str(expected, "available") == "1" else {
                XCTAssertNil(intersection, name)
                continue
            }
            let result = try XCTUnwrap(intersection, name)
            XCTAssertEqual(result.deviceIds, try strings(expected, "deviceIds"), name)
            XCTAssertEqual(result.envelopeVersions, try strings(expected, "envelopeVersions"), name)
            XCTAssertEqual(result.payloadVersions, try strings(expected, "payloadVersions"), name)
            XCTAssertEqual(result.kinds, try strings(expected, "kinds"), name)
            XCTAssertEqual(result.features, try strings(expected, "features"), name)
        }
    }

    func testReissuedVectorsAreLowS() throws {
        XCTAssertTrue(E2EEV2LowS.isLowS(der: try b64(try load("epoch-envelope-v1"), "signatureDerB64")))
        XCTAssertTrue(E2EEV2LowS.isLowS(der: try b64(try XCTUnwrap(try load("recovery-epoch-envelope-v1")["envelope"] as? [String: Any]), "signatureB64")))
        XCTAssertTrue(E2EEV2LowS.isLowS(der: try b64(try load("signed-request-v1"), "signatureDerB64")))
        let message = try load("message-envelope-v1")
        XCTAssertTrue(E2EEV2LowS.isLowS(der: try b64(message, "senderSignatureDerB64")))
        XCTAssertNotNil(E2EEV2ContentContract.parse(Data(try str(message, "cleartextUtf8").utf8)))
    }
}

// MARK: - Constructeurs des vecteurs

private extension E2EEV2JalonAVectorTests {
    func buildDeviceCert() throws -> VJ {
        let uik = try signingKey(0x11)
        let identity = try agreementKey(0x21)
        let signing = try signingKey(0x31)
        let certificate = E2EEV2DeviceCertificate(
            userId: userA, deviceId: deviceA1, keyVersion: 1,
            identityKeyB64: identity.publicKey.x963Representation.base64EncodedString(),
            signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            platform: "ios", createdAtMs: createdAtMs
        )
        let signed = try E2EEV2SignedString.sign(certificate.canonical, with: uik)
        let other = try signingKey(0x12)
        func variant(_ canonical: String) throws -> String { try E2EEV2SignedString.sign(canonical, with: uik).signatureB64 }
        let keyVersionZero = certificate.canonical.replacingOccurrences(of: "\n\(deviceA1)\n1\n", with: "\n\(deviceA1)\n0\n")
        let watch = certificate.canonical.replacingOccurrences(of: "\nios\n", with: "\nwatch\n")
        // Même clé, base64 non canonique (bits de bourrage non nuls).
        let b64 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var identityB64 = Array(identity.publicKey.x963Representation.base64EncodedString())
        identityB64[identityB64.count - 2] = b64[(b64.firstIndex(of: identityB64[identityB64.count - 2]) ?? 0) ^ 1]
        let looseKey = certificate.canonical.replacingOccurrences(
            of: identity.publicKey.x963Representation.base64EncodedString(), with: String(identityB64)
        )
        return .o([
            ("fixtureVersion", .s("2")), ("userId", .s(userA)), ("deviceId", .s(deviceA1)), ("keyVersion", .s("1")),
            ("platform", .s("ios")), ("createdAtMs", .s(String(createdAtMs))),
            ("uikPrivateRawB64", .s(uik.rawRepresentation.base64EncodedString())),
            ("uikPublicX963B64", .s(uik.publicKey.x963Representation.base64EncodedString())),
            ("identityPrivateRawB64", .s(identity.rawRepresentation.base64EncodedString())),
            ("identityPublicX963B64", .s(identity.publicKey.x963Representation.base64EncodedString())),
            ("signingPrivateRawB64", .s(signing.rawRepresentation.base64EncodedString())),
            ("signingPublicX963B64", .s(signing.publicKey.x963Representation.base64EncodedString())),
            ("fingerprint", .s(certificate.fingerprint ?? "")),
            ("certificateUtf8", .s(certificate.canonical)),
            ("signatureDerB64", .s(signed.signatureB64)),
            ("negative", .a([
                .o([("case", .s("highS")), ("signatureDerB64", .s(try highS(signed.signatureB64)))]),
                .o([("case", .s("keyVersionZero")), ("certificateUtf8", .s(keyVersionZero)), ("signatureDerB64", .s(try variant(keyVersionZero)))]),
                .o([("case", .s("unknownPlatform")), ("certificateUtf8", .s(watch)), ("signatureDerB64", .s(try variant(watch)))]),
                .o([("case", .s("extraField")), ("certificateUtf8", .s(certificate.canonical + "\nextra")), ("signatureDerB64", .s(try variant(certificate.canonical + "\nextra")))]),
                .o([("case", .s("nonCanonicalKey")), ("certificateUtf8", .s(looseKey)), ("signatureDerB64", .s(try variant(looseKey)))]),
                .o([("case", .s("wrongUik")), ("uikPublicX963B64", .s(other.publicKey.x963Representation.base64EncodedString()))]),
            ])),
        ])
    }

    func buildDeviceList() throws -> VJ {
        let uik = try signingKey(0x11)
        let fingerprintA1 = try deviceFingerprint(identitySeed: 0x21, signingSeed: 0x31)
        let fingerprintA2 = try deviceFingerprint(identitySeed: 0x22, signingSeed: 0x32)
        let entryA1 = E2EEV2DeviceList.entry(deviceId: deviceA1, keyVersion: 1, platform: "ios", fingerprint: fingerprintA1)
        let entryA2 = E2EEV2DeviceList.entry(deviceId: deviceA2, keyVersion: 1, platform: "web", fingerprint: fingerprintA2)
        let list1 = E2EEV2DeviceList.make(userId: userA, version: 1, previousCanonical: nil, entries: [entryA1, entryA2], issuedAtMs: createdAtMs)
        let signed1 = try E2EEV2SignedString.sign(list1.canonical, with: uik)
        // Version 2 : le navigateur est révoqué, il sort de la liste.
        let list2 = E2EEV2DeviceList.make(userId: userA, version: 2, previousCanonical: list1.canonical, entries: [entryA1], issuedAtMs: createdAtMs + 60_000)
        let signed2 = try E2EEV2SignedString.sign(list2.canonical, with: uik)
        let brokenChain = E2EEV2DeviceList(
            userId: userA, version: 2, previousListDigest: E2EEV2Canonical.sha256B64URL(Data("autre".utf8)),
            deviceCount: 1, devicesDigest: list2.devicesDigest, issuedAtMs: list2.issuedAtMs
        )
        let versionOneWithPrevious = E2EEV2DeviceList.make(userId: userA, version: 1, previousCanonical: list1.canonical, entries: [entryA1], issuedAtMs: createdAtMs)
        // Les lignes contiennent des « \n » : autre découpage des huit lignes, même condensat possible.
        let lines = (entryA1 + "\n" + entryA2).components(separatedBy: "\n")
        let grouped = [lines[0..<3].joined(separator: "\n"), lines[3...].joined(separator: "\n")]
        let groupedList = E2EEV2DeviceList.make(userId: userA, version: 1, previousCanonical: nil, entries: grouped, issuedAtMs: createdAtMs)
        let outOfRange = E2EEV2DeviceList.make(userId: userA, version: Int(Int32.max), previousCanonical: list1.canonical, entries: [entryA1], issuedAtMs: createdAtMs)
        let b64url = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var loose = Array(fingerprintA1)
        loose[loose.count - 1] = b64url[(b64url.firstIndex(of: loose[loose.count - 1]) ?? 0) ^ 1]
        let looseEntry = E2EEV2DeviceList.entry(deviceId: deviceA1, keyVersion: 1, platform: "ios", fingerprint: String(loose))
        let looseList = E2EEV2DeviceList.make(userId: userA, version: 1, previousCanonical: nil, entries: [looseEntry], issuedAtMs: createdAtMs)
        let twinEntry = E2EEV2DeviceList.entry(deviceId: deviceA1, keyVersion: 2, platform: "ios", fingerprint: fingerprintA2)
        let twinList = E2EEV2DeviceList.make(userId: userA, version: 1, previousCanonical: nil, entries: [entryA1, twinEntry], issuedAtMs: createdAtMs)
        func neg(_ name: String, _ list: String, _ entries: [String], _ previous: String?) throws -> VJ {
            var fields: [(String, VJ)] = [
                ("case", .s(name)), ("listUtf8", .s(list)),
                ("signatureDerB64", .s(try E2EEV2SignedString.sign(list, with: uik).signatureB64)),
                ("entries", .a(entries.map(VJ.s))),
            ]
            fields.append(("previousUtf8", previous.map(VJ.s) ?? .null))
            return .o(fields)
        }
        return .o([
            ("fixtureVersion", .s("2")), ("userId", .s(userA)),
            ("uikPrivateRawB64", .s(uik.rawRepresentation.base64EncodedString())),
            ("uikPublicX963B64", .s(uik.publicKey.x963Representation.base64EncodedString())),
            ("entriesV1", .a([.s(entryA1), .s(entryA2)])),
            ("devicesDigestV1", .s(list1.devicesDigest)),
            ("listV1Utf8", .s(list1.canonical)), ("signatureV1DerB64", .s(signed1.signatureB64)),
            ("digestV1", .s(E2EEV2DeviceList.digest(of: list1.canonical))),
            ("entriesV2", .a([.s(entryA1)])),
            ("listV2Utf8", .s(list2.canonical)), ("signatureV2DerB64", .s(signed2.signatureB64)),
            ("negative", .a([
                try neg("countMismatch", list1.canonical, [entryA1], nil),
                try neg("brokenChain", brokenChain.canonical, [entryA1], list1.canonical),
                try neg("versionOneWithPrevious", versionOneWithPrevious.canonical, [entryA1], nil),
                try neg("missingPrevious", list2.canonical, [entryA1], nil),
                try neg("groupedEntries", groupedList.canonical, grouped, nil),
                try neg("versionOutOfRange", outOfRange.canonical, [entryA1], list1.canonical),
                try neg("nonCanonicalFingerprint", looseList.canonical, [looseEntry], nil),
                try neg("duplicateDeviceId", twinList.canonical, [entryA1, twinEntry], nil),
                .o([("case", .s("highS")), ("listUtf8", .s(list1.canonical)), ("signatureDerB64", .s(try highS(signed1.signatureB64))), ("entries", .a([.s(entryA1), .s(entryA2)])), ("previousUtf8", .null)]),
            ])),
        ])
    }

    func buildCapabilities() throws -> VJ {
        let signing = try signingKey(0x31)
        let document = E2EEV2CapabilitiesDocument(
            userId: userA, deviceId: deviceA1, sequence: 3, issuedAtMs: createdAtMs,
            envelopeVersions: ["1", "2"], payloadVersions: ["1", "2"], kinds: ["DELETE", "EDIT", "TEXT"],
            features: ["calls"]
        ).document
        let canonical = E2EEV2CapabilitiesDocument.signatureCanonical(document: document)
        let signed = try E2EEV2SignedString.sign(canonical, with: signing)
        let whitespace = document.replacingOccurrences(of: "{", with: "{ ", options: .anchored)
        let duplicate = document.replacingOccurrences(of: "{\"deviceId\"", with: "{\"deviceId\":\"x\",\"deviceId\"", options: .anchored)
        let unsorted = document.replacingOccurrences(of: #""kinds":["DELETE","EDIT","TEXT"]"#, with: #""kinds":["TEXT","EDIT","DELETE"]"#)
        let unknownFeature = document.replacingOccurrences(of: #""features":["calls"]"#, with: #""features":["calls","telepathy"]"#)
        let number = document.replacingOccurrences(of: #""sequence":"3""#, with: #""sequence":3"#)
        let missing = document.replacingOccurrences(of: #","features":["calls"]"#, with: "")
        return .o([
            ("fixtureVersion", .s("1")),
            ("signingPrivateRawB64", .s(signing.rawRepresentation.base64EncodedString())),
            ("signingPublicX963B64", .s(signing.publicKey.x963Representation.base64EncodedString())),
            ("documentUtf8", .s(document)),
            ("documentSha256B64Url", .s(E2EEV2Canonical.sha256B64URL(Data(document.utf8)))),
            ("signatureCanonicalUtf8", .s(canonical)),
            ("signatureDerB64", .s(signed.signatureB64)),
            ("negative", .a([
                .o([("case", .s("notCanonicalWhitespace")), ("documentUtf8", .s(whitespace))]),
                .o([("case", .s("duplicateKey")), ("documentUtf8", .s(duplicate))]),
                .o([("case", .s("unsortedKinds")), ("documentUtf8", .s(unsorted))]),
                .o([("case", .s("unknownFeature")), ("documentUtf8", .s(unknownFeature))]),
                .o([("case", .s("numberInsteadOfString")), ("documentUtf8", .s(number))]),
                .o([("case", .s("missingKey")), ("documentUtf8", .s(missing))]),
            ])),
        ])
    }

    func buildUIKWrap() throws -> VJ {
        let uik = try signingKey(0x11)
        let approver = try signingKey(0x31)
        let newDevice = try agreementKey(0x22)
        let ephemeral = try agreementKey(0x41)
        let nonce = Data((0..<12).map { UInt8(0x50 + $0) })
        let wrap = try E2EEV2UIKWrapCrypto.wrap(
            uik: uik, userId: userA, approverDeviceId: deviceA1, newDeviceId: deviceA2,
            newDeviceAgreementKey: newDevice.publicKey, approverSigningKey: approver,
            ephemeral: ephemeral, nonce: nonce
        )
        let salt = E2EEV2UIKWrapCrypto.salt(userId: userA, approverDeviceId: deviceA1, newDeviceId: deviceA2)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: newDevice.publicKey).withUnsafeBytes { Data($0) }
        var tampered = try XCTUnwrap(Data(base64Encoded: wrap.wrappedUikB64))
        tampered[tampered.startIndex] ^= 0x01
        let tamperedWrap = E2EEV2UIKWrap(
            userId: wrap.userId, approverDeviceId: wrap.approverDeviceId, newDeviceId: wrap.newDeviceId,
            uikPublicKeyB64: wrap.uikPublicKeyB64, ephemeralPublicKeyB64: wrap.ephemeralPublicKeyB64,
            nonceB64: wrap.nonceB64, aadB64: wrap.aadB64, wrappedUikB64: tampered.base64EncodedString(), signatureB64: ""
        )
        let tamperedSignature = try E2EEV2LowS.sign(Data(E2EEV2UIKWrapCrypto.signatureCanonical(tamperedWrap).utf8), with: approver)
        return .o([
            ("fixtureVersion", .s("1")), ("userId", .s(userA)), ("approverDeviceId", .s(deviceA1)), ("newDeviceId", .s(deviceA2)),
            ("uikPrivateRawB64", .s(uik.rawRepresentation.base64EncodedString())),
            ("uikPublicX963B64", .s(wrap.uikPublicKeyB64)),
            ("approverSigningPrivateRawB64", .s(approver.rawRepresentation.base64EncodedString())),
            ("approverSigningPublicX963B64", .s(approver.publicKey.x963Representation.base64EncodedString())),
            ("newDeviceAgreementPrivateRawB64", .s(newDevice.rawRepresentation.base64EncodedString())),
            ("newDeviceAgreementPublicX963B64", .s(newDevice.publicKey.x963Representation.base64EncodedString())),
            ("ephemeralPrivateRawB64", .s(ephemeral.rawRepresentation.base64EncodedString())),
            ("ephemeralPublicX963B64", .s(wrap.ephemeralPublicKeyB64)),
            ("sharedSecretB64", .s(secret.base64EncodedString())),
            ("saltB64", .s(salt.base64EncodedString())),
            ("derivedKeyB64", .s(E2EEV2UIKWrapCrypto.wrappingKey(sharedSecret: secret, salt: salt).base64EncodedString())),
            ("nonceB64", .s(wrap.nonceB64)),
            ("aadUtf8", .s(String(decoding: try XCTUnwrap(Data(base64Encoded: wrap.aadB64)), as: UTF8.self))),
            ("aadB64", .s(wrap.aadB64)),
            ("wrappedUikB64", .s(wrap.wrappedUikB64)),
            ("signatureCanonicalUtf8", .s(E2EEV2UIKWrapCrypto.signatureCanonical(wrap))),
            ("signatureDerB64", .s(wrap.signatureB64)),
            ("negative", .a([
                .o([("case", .s("wrongExpectedUik")), ("expectedUikB64", .s(try signingKey(0x12).publicKey.x963Representation.base64EncodedString()))]),
                .o([("case", .s("tamperedWrappedUik")), ("wrappedUikB64", .s(tampered.base64EncodedString())), ("signatureDerB64", .s(tamperedSignature.base64EncodedString()))]),
                .o([("case", .s("highS")), ("signatureDerB64", .s(try highS(wrap.signatureB64)))]),
            ])),
        ])
    }

    /// Chaîne du vecteur d'appartenance : Alice crée un groupe avec Bruno
    /// (genèse, n° 1 à 3), puis exclut les navigateurs (n° 4).
    func membershipChain(actor: P256.Signing.PrivateKey) throws -> [E2EEV2SignedString] {
        let genesis = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: [userA, userB], adminIds: [userA], isGroup: true,
            actor: .init(userId: userA, deviceId: deviceA1), createdAtMs: createdAtMs
        )
        let exclude = E2EEV2MembershipChange(
            conversationId: conversationId, changeNumber: 4, action: "EXCLUDE_WEB_ON", targetUserId: "-",
            actorUserId: userA, actorDeviceId: deviceA1,
            previousChangeDigest: E2EEV2MembershipChange.digest(of: genesis[2].canonical), createdAtMs: createdAtMs + 3
        )
        return try (genesis + [exclude]).map { try E2EEV2SignedString.sign($0.canonical, with: actor) }
    }

    func manifestRecipients() throws -> [String] {
        [
            E2EEV2EpochManifest.recipient(userId: userA, deviceId: deviceA1, platform: "ios", fingerprint: try deviceFingerprint(identitySeed: 0x21, signingSeed: 0x31)),
            E2EEV2EpochManifest.recipient(userId: userA, deviceId: deviceA2, platform: "web", fingerprint: try deviceFingerprint(identitySeed: 0x22, signingSeed: 0x32)),
            E2EEV2EpochManifest.recipient(userId: userB, deviceId: deviceB1, platform: "android", fingerprint: try deviceFingerprint(identitySeed: 0x23, signingSeed: 0x33)),
        ]
    }

    func buildEpochManifest() throws -> VJ {
        let creator = try signingKey(0x31)
        let epochKey = Data((0..<32).map { UInt8(0x80 + $0) })
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let recipients = try manifestRecipients()
        let genesisDigest = E2EEV2MembershipChange.digest(of: try membershipChain(actor: creator)[2].canonical)
        func manifest(_ excludesWeb: Bool, _ list: [String], membership: Int = 3) -> E2EEV2EpochManifest {
            E2EEV2EpochManifest.make(
                conversationId: conversationId, epochNumber: 1, creatorUserId: userA, creatorDeviceId: deviceA1,
                keyCommitmentB64: commitment, recipients: list, excludesWeb: excludesWeb,
                membershipChangeNumber: membership, membershipDigest: genesisDigest, createdAtMs: createdAtMs + 3
            )
        }
        func negative(_ name: String, _ value: E2EEV2EpochManifest, recipients list: [String]? = nil) throws -> VJ {
            var fields: [(String, VJ)] = [
                ("case", .s(name)), ("manifestUtf8", .s(value.canonical)),
                ("signatureDerB64", .s(try E2EEV2SignedString.sign(value.canonical, with: creator).signatureB64)),
            ]
            if let list { fields.append(("recipients", .a(list.map(VJ.s)))) }
            return .o(fields)
        }
        let valid = manifest(false, recipients)
        let signed = try E2EEV2SignedString.sign(valid.canonical, with: creator)
        let duplicate = [recipients[0], E2EEV2EpochManifest.recipient(
            userId: userA, deviceId: deviceA1, platform: "ios", fingerprint: try deviceFingerprint(identitySeed: 0x24, signingSeed: 0x34)
        )]
        let unknownPlatform = [recipients[0], E2EEV2EpochManifest.recipient(
            userId: userB, deviceId: deviceB1, platform: "macos", fingerprint: try deviceFingerprint(identitySeed: 0x23, signingSeed: 0x33)
        )]
        let version1 = [
            E2EEV2EpochManifest.tag, "1", conversationId, "1", userA, deviceA1, commitment, "3",
            valid.recipientsDigest, "0", String(createdAtMs + 3),
        ].joined(separator: "\n")
        return .o([
            ("fixtureVersion", .s("1")), ("conversationId", .s(conversationId)), ("epochNumber", .s("1")),
            ("creatorUserId", .s(userA)), ("creatorDeviceId", .s(deviceA1)),
            ("creatorSigningPrivateRawB64", .s(creator.rawRepresentation.base64EncodedString())),
            ("creatorSigningPublicX963B64", .s(creator.publicKey.x963Representation.base64EncodedString())),
            ("epochKeyB64", .s(epochKey.base64EncodedString())), ("keyCommitmentB64", .s(commitment)),
            ("recipients", .a(recipients.map(VJ.s))), ("recipientsDigest", .s(valid.recipientsDigest)),
            ("excludesWeb", .s("0")), ("membershipChangeNumber", .s("3")), ("membershipDigest", .s(genesisDigest)),
            ("createdAtMs", .s(String(createdAtMs + 3))),
            ("manifestUtf8", .s(valid.canonical)), ("signatureDerB64", .s(signed.signatureB64)),
            ("negative", .a([
                try negative("excludesWebWithWebRecipient", manifest(true, recipients)),
                .o([("case", .s("recipientsMismatch")), ("recipients", .a([recipients[0], recipients[2]].map(VJ.s)))]),
                .o([("case", .s("highS")), ("signatureDerB64", .s(try highS(signed.signatureB64)))]),
                .o([("case", .s("formatVersion1")), ("manifestUtf8", .s(version1)), ("signatureDerB64", .s(try E2EEV2SignedString.sign(version1, with: creator).signatureB64))]),
                try negative("membershipZero", manifest(false, recipients, membership: 0)),
                try negative("duplicateDevice", manifest(false, duplicate), recipients: duplicate),
                try negative("unknownPlatform", manifest(false, unknownPlatform), recipients: unknownPlatform),
                .o([("case", .s("nonCanonicalDer")), ("signatureDerB64", .s(try nonCanonicalDer(signed.signatureB64)))]),
                .o([("case", .s("trailingDerBytes")), ("signatureDerB64", .s(try trailingDerBytes(signed.signatureB64)))]),
            ])),
        ])
    }

    /// Liaison d'une époque à la chaîne d'appartenance (v0.4.7). Chaque cas :
    /// relire `chain` (ou sa variante) jusqu'au n° du manifeste, genèse =
    /// n° du manifeste pour l'époque 1, `genesisLength` sinon, puis vérifier.
    func buildEpochBinding() throws -> VJ {
        let alice = try signingKey(0x31), bruno = try signingKey(0x33)
        let commitment = try E2EEV2EpochCrypto.keyCommitment(Data((0..<32).map { UInt8(0x80 + $0) }))
        let chain = try membershipChain(actor: alice)
        let recipients = try manifestRecipients()
        let withoutWeb = [recipients[0], recipients[2]]
        let carla = E2EEV2EpochManifest.recipient(
            userId: "user_carla_01J7ABCD23456789", deviceId: "device_carla_ios_01J7ABCD2345", platform: "ios",
            fingerprint: try deviceFingerprint(identitySeed: 0x25, signingSeed: 0x35)
        )
        func digest(_ list: [E2EEV2SignedString], _ number: Int) -> String {
            E2EEV2MembershipChange.digest(of: list[number - 1].canonical)
        }
        func signedJSON(_ list: [E2EEV2SignedString]) -> VJ {
            .a(list.map { .o([("changeUtf8", .s($0.canonical)), ("signatureDerB64", .s($0.signatureB64))]) })
        }
        func change(_ number: Int, _ action: String, _ target: String, actor: (String, String), previous: String?) -> E2EEV2MembershipChange {
            E2EEV2MembershipChange(
                conversationId: conversationId, changeNumber: number, action: action, targetUserId: target,
                actorUserId: actor.0, actorDeviceId: actor.1,
                previousChangeDigest: previous.map(E2EEV2MembershipChange.digest(of:)) ?? "-",
                createdAtMs: createdAtMs + Int64(number - 1)
            )
        }
        func item(
            _ name: String, epoch: Int, membership: Int, digest membershipDigest: String, excludesWeb: Bool,
            recipients list: [String], expected: String, creator: (String, String, P256.Signing.PrivateKey)? = nil,
            extra: [(String, VJ)] = []
        ) throws -> VJ {
            let signer = creator ?? (userA, deviceA1, alice)
            let manifest = E2EEV2EpochManifest.make(
                conversationId: conversationId, epochNumber: epoch, creatorUserId: signer.0, creatorDeviceId: signer.1,
                keyCommitmentB64: commitment, recipients: list, excludesWeb: excludesWeb,
                membershipChangeNumber: membership, membershipDigest: membershipDigest,
                createdAtMs: createdAtMs + 10 + Int64(epoch)
            )
            return .o([
                ("case", .s(name)), ("manifestUtf8", .s(manifest.canonical)),
                ("signatureDerB64", .s(try E2EEV2SignedString.sign(manifest.canonical, with: signer.2).signatureB64)),
                ("recipients", .a(list.map(VJ.s))),
            ] + extra + [("expected", .s(expected))])
        }
        // Genèse à deux appareils auteurs : Bruno signe son propre ADD.
        let first = change(1, "ADD", userA, actor: (userA, deviceA1), previous: nil)
        let second = change(2, "ADD", userB, actor: (userB, deviceB1), previous: first.canonical)
        let third = change(3, "ROLE_ADMIN", userA, actor: (userA, deviceA1), previous: second.canonical)
        let twoAuthors = [
            try E2EEV2SignedString.sign(first.canonical, with: alice),
            try E2EEV2SignedString.sign(second.canonical, with: bruno),
            try E2EEV2SignedString.sign(third.canonical, with: alice),
        ]
        // Genèse non triée : Bruno ajouté avant Alice.
        let unsortedChanges = [
            change(1, "ADD", userB, actor: (userA, deviceA1), previous: nil),
        ]
        let unsorted2 = change(2, "ADD", userA, actor: (userA, deviceA1), previous: unsortedChanges[0].canonical)
        let unsorted3 = change(3, "ROLE_ADMIN", userA, actor: (userA, deviceA1), previous: unsorted2.canonical)
        let unsorted = try [unsortedChanges[0], unsorted2, unsorted3].map { try E2EEV2SignedString.sign($0.canonical, with: alice) }
        return .o([
            ("fixtureVersion", .s("1")), ("conversationId", .s(conversationId)), ("isGroup", .s("1")),
            ("genesisLength", .s("3")),
            ("devices", .a([
                .o([("userId", .s(userA)), ("deviceId", .s(deviceA1)), ("signingPublicX963B64", .s(alice.publicKey.x963Representation.base64EncodedString()))]),
                .o([("userId", .s(userB)), ("deviceId", .s(deviceB1)), ("signingPublicX963B64", .s(bruno.publicKey.x963Representation.base64EncodedString()))]),
            ])),
            ("chain", signedJSON(chain)),
            ("cases", .a([
                try item("genesis", epoch: 1, membership: 3, digest: digest(chain, 3), excludesWeb: false, recipients: recipients, expected: "ok"),
                try item("secondEpoch", epoch: 2, membership: 4, digest: digest(chain, 4), excludesWeb: true, recipients: withoutWeb, expected: "ok",
                         extra: [("previousMembershipChangeNumber", .s("3"))]),
                try item("sameMembershipAsPrevious", epoch: 3, membership: 4, digest: digest(chain, 4), excludesWeb: true, recipients: withoutWeb, expected: "ok",
                         extra: [("previousMembershipChangeNumber", .s("4"))]),
                try item("wrongDigest", epoch: 1, membership: 3, digest: digest(chain, 2), excludesWeb: false, recipients: recipients, expected: "membershipMismatch"),
                try item("recipientNotMember", epoch: 1, membership: 3, digest: digest(chain, 3), excludesWeb: false, recipients: recipients + [carla], expected: "recipientNotMember"),
                try item("excludesWebMismatch", epoch: 2, membership: 4, digest: digest(chain, 4), excludesWeb: false, recipients: withoutWeb, expected: "excludesWebMismatch",
                         extra: [("previousMembershipChangeNumber", .s("3"))]),
                try item("membershipRegressed", epoch: 2, membership: 3, digest: digest(chain, 3), excludesWeb: false, recipients: recipients, expected: "membershipRegressed",
                         extra: [("previousMembershipChangeNumber", .s("4"))]),
                try item("genesisMismatch", epoch: 1, membership: 3, digest: digest(chain, 3), excludesWeb: false, recipients: recipients, expected: "genesisMismatch",
                         creator: (userB, deviceB1, bruno)),
                try item("genesisByTwoDevices", epoch: 1, membership: 3, digest: digest(twoAuthors, 3), excludesWeb: false, recipients: recipients, expected: "invalidChain",
                         extra: [("chain", signedJSON(twoAuthors))]),
                try item("unsortedGenesis", epoch: 1, membership: 3, digest: digest(unsorted, 3), excludesWeb: false, recipients: recipients, expected: "invalidChain",
                         extra: [("chain", signedJSON(unsorted))]),
                try item("roleAdminInDirect", epoch: 1, membership: 3, digest: digest(chain, 3), excludesWeb: false, recipients: recipients, expected: "invalidChain",
                         extra: [("isGroup", .s("0"))]),
                try item("membershipBeyondChain", epoch: 1, membership: 5, digest: digest(chain, 4), excludesWeb: true, recipients: withoutWeb, expected: "membershipMismatch"),
            ])),
        ])
    }

    func buildMembership() throws -> VJ {
        let actor = try signingKey(0x31)
        var previous: String?
        var chain: [VJ] = []
        var canonicals: [String] = []
        let steps: [(String, String)] = [("ADD", userA), ("ADD", userB), ("ROLE_ADMIN", userA), ("EXCLUDE_WEB_ON", "-")]
        for (index, step) in steps.enumerated() {
            let change = E2EEV2MembershipChange(
                conversationId: conversationId, changeNumber: index + 1, action: step.0, targetUserId: step.1,
                actorUserId: userA, actorDeviceId: deviceA1,
                previousChangeDigest: previous.map(E2EEV2MembershipChange.digest(of:)) ?? "-",
                createdAtMs: createdAtMs + Int64(index)
            )
            let signed = try E2EEV2SignedString.sign(change.canonical, with: actor)
            chain.append(.o([("action", .s(step.0)), ("changeUtf8", .s(change.canonical)), ("signatureDerB64", .s(signed.signatureB64))]))
            canonicals.append(change.canonical)
            previous = change.canonical
        }
        func change(_ number: Int, _ action: String, _ target: String, _ previousDigest: String) -> String {
            E2EEV2MembershipChange(
                conversationId: conversationId, changeNumber: number, action: action, targetUserId: target,
                actorUserId: userA, actorDeviceId: deviceA1, previousChangeDigest: previousDigest, createdAtMs: createdAtMs
            ).canonical
        }
        let digest2 = E2EEV2MembershipChange.digest(of: canonicals[1])
        return .o([
            ("fixtureVersion", .s("1")), ("conversationId", .s(conversationId)),
            ("actorSigningPrivateRawB64", .s(actor.rawRepresentation.base64EncodedString())),
            ("actorSigningPublicX963B64", .s(actor.publicKey.x963Representation.base64EncodedString())),
            ("chain", .a(chain)),
            ("negative", .a([
                .o([("case", .s("brokenChain")), ("changeUtf8", .s(change(3, "ADD", userB, E2EEV2Canonical.sha256B64URL(Data("autre".utf8))))), ("previousUtf8", .s(canonicals[1]))]),
                .o([("case", .s("leaveByOther")), ("changeUtf8", .s(change(3, "LEAVE", userB, digest2))), ("previousUtf8", .s(canonicals[1]))]),
                .o([("case", .s("webToggleWithTarget")), ("changeUtf8", .s(change(3, "EXCLUDE_WEB_ON", userB, digest2))), ("previousUtf8", .s(canonicals[1]))]),
                .o([("case", .s("unknownAction")), ("changeUtf8", .s(change(3, "PROMOTE", userB, digest2))), ("previousUtf8", .s(canonicals[1]))]),
                .o([("case", .s("firstWithPrevious")), ("changeUtf8", .s(change(1, "ADD", userA, digest2))), ("previousUtf8", .null)]),
            ])),
        ])
    }

    func buildMessageRef() -> VJ {
        .o([
            ("fixtureVersion", .s("1")), ("conversationId", .s(conversationId)), ("senderDeviceId", .s(deviceA1)),
            ("clientRequestId", .s("message_01J7ABCD23456789")),
            ("canonicalUtf8", .s(["SQ-E2EE-V2-MESSAGE-REF", "1", conversationId, deviceA1, "message_01J7ABCD23456789"].joined(separator: "\n"))),
            ("messageRef", .s(E2EEV2MessageRef.make(conversationId: conversationId, senderDeviceId: deviceA1, clientRequestId: "message_01J7ABCD23456789"))),
        ])
    }

    func buildMessageEnvelopeV2() throws -> VJ {
        let sender = try signingKey(0x31)
        let epochKey = Data((0..<32).map { UInt8(0x80 + $0) })
        let fk = Data((0..<32).map { UInt8(0xA0 + $0) })
        let nonce = Data((0..<12).map { UInt8(0x60 + $0) })
        let context = E2EEV2MessageContextV2(
            conversationId: conversationId, epochNumber: 1, senderDeviceId: deviceA1,
            clientRequestId: "message_01J7ABCD23456789", counter: 1, ttlSeconds: 0, encryptedBlobIds: []
        )
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: createdAtMs, counter: 1, replyToRef: nil, mentions: [], body: .text("Bonjour du monde 🌍")).encoded()
        let envelope = try E2EEV2MessageCryptoV2.encrypt(payload: payload, fk: fk, epochKey: epochKey, nonce: nonce, context: context)
        let canonical = try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: envelope)
        let signature = try E2EEV2LowS.sign(canonical, with: sender).base64EncodedString()
        // Bourrage invalide : même clé et même AAD, octet final non nul.
        var badClear = E2EEV2MessageCryptoV2.pad(fk: fk, payload: payload)
        badClear[badClear.index(before: badClear.endIndex)] = 0x01
        let messageKey = try E2EEV2MessageCryptoV2.deriveMessageKey(epochKey: epochKey, context: context)
        let badSealed = try AES.GCM.seal(badClear, using: SymmetricKey(data: messageKey), nonce: AES.GCM.Nonce(data: nonce), authenticating: try XCTUnwrap(Data(base64Encoded: envelope.aadB64)))
        // Compteur de la charge (2) différent de celui de l'enveloppe (1).
        let counterPayload = try E2EEV2ContentPayloadV2(sentAtMs: createdAtMs, counter: 2, replyToRef: nil, mentions: [], body: .text("Bonjour")).encoded()
        let counterEnvelope = try E2EEV2MessageCryptoV2.encrypt(payload: counterPayload, fk: fk, epochKey: epochKey, nonce: nonce, context: context)
        // L'enveloppe telle qu'elle voyage (E.3), et ce qu'un analyseur strict refuse.
        let wire = String(decoding: E2EEV2SignedMessageEnvelopeV2(envelope: envelope, senderSignatureB64: signature).encoded, as: UTF8.self)
        var offStep = try XCTUnwrap(Data(base64Encoded: envelope.ciphertextB64))
        offStep.append(0)
        // Les octets exacts aussi : un chargeur JSON peut retirer un BOM en tête
        // d'une chaîne (JSONSerialization le fait).
        func wireCase(_ name: String, _ text: String) -> VJ {
            XCTAssertNotEqual(text, wire, name)
            return .o([("case", .s(name)), ("wireJsonUtf8", .s(text)), ("wireJsonB64", .s(Data(text.utf8).base64EncodedString()))])
        }
        let wireNegative: [VJ] = [
            wireCase("counterAsNumber", wire.replacingOccurrences(of: #""counter":"1""#, with: #""counter":1"#)),
            wireCase("epochNumberAsNumber", wire.replacingOccurrences(of: #""epochNumber":"1""#, with: #""epochNumber":1"#)),
            wireCase("envelopeVersionOne", wire.replacingOccurrences(of: #""envelopeVersion":"2""#, with: #""envelopeVersion":"1""#)),
            wireCase("counterZero", wire.replacingOccurrences(of: #""counter":"1""#, with: #""counter":"0""#)),
            wireCase("counterLeadingZero", wire.replacingOccurrences(of: #""counter":"1""#, with: #""counter":"01""#)),
            wireCase("counterOverflow", wire.replacingOccurrences(of: #""counter":"1""#, with: #""counter":"2147483647""#)),
            wireCase("ttlTooLong", wire.replacingOccurrences(of: #""ttlSeconds":"0""#, with: #""ttlSeconds":"2592001""#)),
            wireCase("senderDeviceIdInEnvelope", wire.replacingOccurrences(of: #"{"aadB64""#, with: #"{"senderDeviceId":"\#(deviceA1)","aadB64""#)),
            wireCase("duplicateKey", wire.replacingOccurrences(of: #"{"aadB64""#, with: #"{"counter":"2","aadB64""#)),
            wireCase("missingFrankTag", wire.replacingOccurrences(of: #""frankTagB64":"\#(envelope.frankTagB64)","#, with: "")),
            wireCase("unpaddedCommitment", wire.replacingOccurrences(of: envelope.keyCommitmentB64, with: String(envelope.keyCommitmentB64.dropLast()))),
            wireCase("ciphertextOffPaddingStep", wire.replacingOccurrences(of: envelope.ciphertextB64, with: offStep.base64EncodedString())),
            wireCase("signatureTooLong", wire.replacingOccurrences(of: signature, with: Data(repeating: 0x30, count: 80).base64EncodedString())),
            wireCase("counterPlusSign", wire.replacingOccurrences(of: #""counter":"1""#, with: #""counter":"+1""#)),
            wireCase("counterExponent", wire.replacingOccurrences(of: #""counter":"1""#, with: #""counter":"1e0""#)),
            wireCase("counterSpace", wire.replacingOccurrences(of: #""counter":"1""#, with: #""counter":" 1""#)),
            wireCase("counterEmpty", wire.replacingOccurrences(of: #""counter":"1""#, with: "\"counter\":\"\"")),
            wireCase("counterArabicDigit", wire.replacingOccurrences(of: #""counter":"1""#, with: "\"counter\":\"\u{0661}\"")),
            wireCase("frankTagTrailingBits", wire.replacingOccurrences(of: envelope.frankTagB64, with: try nonZeroTrailingBits(envelope.frankTagB64))),
            wireCase("nonceEscapedNewline", wire.replacingOccurrences(
                of: envelope.nonceB64, with: String(envelope.nonceB64.prefix(8)) + #"\n"# + String(envelope.nonceB64.dropFirst(8))
            )),
            wireCase("ciphertextUrlAlphabet", wire.replacingOccurrences(of: envelope.ciphertextB64, with: try urlAlphabet(envelope.ciphertextB64))),
            wireCase("bomPrefix", "\u{FEFF}" + wire),
            wireCase("comment", wire.replacingOccurrences(of: #"{"aadB64""#, with: #"{/* x */"aadB64""#)),
            wireCase("apostrophes", wire.replacingOccurrences(of: #""counter":"1""#, with: "'counter':'1'")),
            wireCase("trailingComma", String(wire.dropLast()) + ",}"),
        ]
        // JSON valide, mais pas en JCS : refusé comme corps d'envoi (D.7).
        func nonCanonical(_ name: String, _ text: String) -> VJ {
            XCTAssertNotEqual(text, wire, name)
            return .o([("case", .s(name)), ("wireJsonUtf8", .s(text)), ("wireJsonB64", .s(Data(text.utf8).base64EncodedString()))])
        }
        let algorithmField = #""algorithm":"\#(E2EEV2MessageCryptoV2.algorithm)","#
        let wireNonCanonical: [VJ] = [
            nonCanonical("escapedSlash", wire.replacingOccurrences(
                of: envelope.ciphertextB64, with: envelope.ciphertextB64.replacingOccurrences(of: "/", with: #"\/"#)
            )),
            nonCanonical("unsortedKeys", "{" + algorithmField + wire.dropFirst().replacingOccurrences(of: algorithmField, with: "")),
            nonCanonical("whitespace", "{ " + wire.dropFirst()),
        ]
        return .o([
            ("fixtureVersion", .s("1")), ("conversationId", .s(conversationId)), ("epochNumber", .s("1")),
            ("senderDeviceId", .s(deviceA1)), ("clientRequestId", .s(context.clientRequestId)), ("counter", .s("1")),
            ("ttlSeconds", .s("0")), ("encryptedBlobIds", .a([])),
            ("algorithm", .s(E2EEV2MessageCryptoV2.algorithm)), ("contentType", .s(E2EEV2MessageCryptoV2.contentType)),
            ("kdfInfo", .s(E2EEV2MessageCryptoV2.kdfInfo)),
            ("epochKeyB64", .s(epochKey.base64EncodedString())), ("keyCommitmentB64", .s(envelope.keyCommitmentB64)),
            ("fkB64", .s(fk.base64EncodedString())),
            ("payloadUtf8", .s(String(decoding: payload, as: UTF8.self))),
            ("frankTagB64", .s(envelope.frankTagB64)),
            ("saltCanonicalUtf8", .s(String(decoding: E2EEV2MessageCryptoV2.saltCanonical(context), as: UTF8.self))),
            ("saltB64", .s(Data(SHA256.hash(data: E2EEV2MessageCryptoV2.saltCanonical(context))).base64EncodedString())),
            ("derivedKeyB64", .s(messageKey.base64EncodedString())),
            ("paddedClearLength", .s(String(E2EEV2MessageCryptoV2.pad(fk: fk, payload: payload).count))),
            ("nonceB64", .s(envelope.nonceB64)),
            ("aadUtf8", .s(String(decoding: try XCTUnwrap(Data(base64Encoded: envelope.aadB64)), as: UTF8.self))),
            ("aadB64", .s(envelope.aadB64)), ("ciphertextB64", .s(envelope.ciphertextB64)),
            ("signatureCanonicalUtf8", .s(String(decoding: canonical, as: UTF8.self))),
            ("senderSigningPrivateRawB64", .s(sender.rawRepresentation.base64EncodedString())),
            ("senderSigningPublicX963B64", .s(sender.publicKey.x963Representation.base64EncodedString())),
            ("signatureDerB64", .s(signature)),
            ("wireJsonUtf8", .s(wire)),
            ("wireNegative", .a(wireNegative)),
            ("wireNonCanonical", .a(wireNonCanonical)),
            ("negative", .a([
                .o([("case", .s("tamperedFrankTag")), ("frankTagB64", .s(Data(repeating: 7, count: 32).base64EncodedString()))]),
                .o([("case", .s("badPadding")), ("ciphertextB64", .s((badSealed.ciphertext + badSealed.tag).base64EncodedString()))]),
                .o([("case", .s("counterMismatch")), ("frankTagB64", .s(counterEnvelope.frankTagB64)), ("aadB64", .s(counterEnvelope.aadB64)), ("ciphertextB64", .s(counterEnvelope.ciphertextB64))]),
                .o([("case", .s("counterNotInContext")), ("contextCounter", .s("2"))]),
                .o([("case", .s("highS")), ("signatureDerB64", .s(try highS(signature)))]),
            ])),
        ])
    }

    /// Mêmes octets pour un décodeur indulgent, mais bits de fin non nuls.
    func nonZeroTrailingBits(_ b64: String) throws -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var chars = Array(b64)
        XCTAssertEqual(chars.last, "=", "Remplissage attendu : des bits de fin existent")
        let last = try XCTUnwrap(chars.lastIndex { $0 != "=" })
        let value = try XCTUnwrap(alphabet.firstIndex(of: chars[last]))
        chars[last] = alphabet[value ^ 1]
        return String(chars)
    }

    /// Un caractère de l'alphabet base64url à la place de son équivalent standard.
    func urlAlphabet(_ b64: String) throws -> String {
        if let slash = b64.firstIndex(of: "/") { return b64.replacingCharacters(in: slash...slash, with: "_") }
        let plus = try XCTUnwrap(b64.firstIndex(of: "+"))
        return b64.replacingCharacters(in: plus...plus, with: "-")
    }

    func buildContentPayloadV2() throws -> VJ {
        let ref = E2EEV2MessageRef.make(conversationId: conversationId, senderDeviceId: deviceA1, clientRequestId: "message_01J7ABCD23456789")
        let text = try E2EEV2ContentPayloadV2(sentAtMs: createdAtMs, counter: 1, replyToRef: nil, mentions: [userB], body: .text("Salut @bruno")).encoded()
        let edit = try E2EEV2ContentPayloadV2(sentAtMs: createdAtMs + 1, counter: 2, replyToRef: nil, mentions: [], body: .edit(targetRef: ref, text: "Salut Bruno")).encoded()
        let delete = try E2EEV2ContentPayloadV2(sentAtMs: createdAtMs + 2, counter: 3, replyToRef: ref, mentions: [], body: .delete(targetRef: ref)).encoded()
        let textString = String(decoding: text, as: UTF8.self)
        return .o([
            ("fixtureVersion", .s("1")),
            ("valid", .a([
                .o([("kind", .s("TEXT")), ("payloadUtf8", .s(textString))]),
                .o([("kind", .s("EDIT")), ("payloadUtf8", .s(String(decoding: edit, as: UTF8.self)))]),
                .o([("kind", .s("DELETE")), ("payloadUtf8", .s(String(decoding: delete, as: UTF8.self)))]),
            ])),
            ("negative", .a([
                .o([("case", .s("extraKey")), ("payloadUtf8", .s(textString.replacingOccurrences(of: "{\"body\"", with: "{\"a\":null,\"body\"")))]),
                .o([("case", .s("notCanonical")), ("payloadUtf8", .s(textString.replacingOccurrences(of: ",\"version\":\"2\"}", with: ",\"version\":\"2\" }")))]),
                .o([("case", .s("counterAsNumber")), ("payloadUtf8", .s(textString.replacingOccurrences(of: "\"counter\":\"1\"", with: "\"counter\":1")))]),
                .o([("case", .s("counterZero")), ("payloadUtf8", .s(textString.replacingOccurrences(of: "\"counter\":\"1\"", with: "\"counter\":\"0\"")))]),
                .o([("case", .s("emptyText")), ("payloadUtf8", .s(textString.replacingOccurrences(of: "\"text\":\"Salut @bruno\"", with: "\"text\":\"\"")))]),
                .o([("case", .s("unknownKind")), ("payloadUtf8", .s(textString.replacingOccurrences(of: "\"kind\":\"TEXT\"", with: "\"kind\":\"POLL\"")))]),
                .o([("case", .s("badMention")), ("payloadUtf8", .s(textString.replacingOccurrences(of: userB, with: "bruno")))]),
            ])),
        ])
    }

    func buildFranking() -> VJ {
        let fk = Data((0..<32).map { UInt8(0xA0 + $0) })
        let ks = Data((0..<32).map { UInt8(0xC0 + $0) })
        let payload = #"{"body":{"text":"Bonjour"},"counter":"1","kind":"TEXT","mentions":[],"replyToRef":null,"schema":"signalquest.e2ee-content","sentAtMs":"1790000000000","version":"2"}"#
        let frank = E2EEV2Franking.frankTag(fk: fk, conversationId: conversationId, senderDeviceId: deviceA1, clientRequestId: "message_01J7ABCD23456789", payload: Data(payload.utf8))
        let server = E2EEV2Franking.serverTag(
            ks: ks, frankTagB64: frank.base64EncodedString(), conversationId: conversationId, envelopeId: "envelope_01J7ABCD23456789",
            senderUserId: userA, senderDeviceId: deviceA1, serverTimeMs: createdAtMs + 250, keyId: "server_tag_key_01J7ABCD"
        )
        return .o([
            ("fixtureVersion", .s("1")), ("conversationId", .s(conversationId)), ("senderDeviceId", .s(deviceA1)),
            ("clientRequestId", .s("message_01J7ABCD23456789")), ("fkB64", .s(fk.base64EncodedString())),
            ("payloadUtf8", .s(payload)), ("frankTagB64", .s(frank.base64EncodedString())),
            ("ksB64", .s(ks.base64EncodedString())), ("envelopeId", .s("envelope_01J7ABCD23456789")),
            ("senderUserId", .s(userA)), ("serverTimeMs", .s(String(createdAtMs + 250))), ("keyId", .s("server_tag_key_01J7ABCD")),
            ("serverTagCanonicalUtf8", .s(["SQ-E2EE-V2-SERVER-TAG", "1", frank.base64EncodedString(), conversationId, "envelope_01J7ABCD23456789", userA, deviceA1, String(createdAtMs + 250), "server_tag_key_01J7ABCD"].joined(separator: "\n"))),
            ("serverTagB64", .s(server.base64EncodedString())),
        ])
    }

    func buildReport() throws -> VJ {
        let moderation = try agreementKey(0x51)
        let ikm = Data((0..<32).map { UInt8(0x70 + $0) })
        let ephemeral = try E2EEV2HPKE.deriveKeyPair(ikm: ikm)
        let fk = Data((0..<32).map { UInt8(0xA0 + $0) })
        let payload = Data(#"{"body":{"text":"Message signalé"},"counter":"1","kind":"TEXT","mentions":[],"replyToRef":null,"schema":"signalquest.e2ee-content","sentAtMs":"1790000000000","version":"2"}"#.utf8)
        let frank = E2EEV2Franking.frankTag(fk: fk, conversationId: conversationId, senderDeviceId: deviceB1, clientRequestId: "message_01J7ABCD23456789", payload: payload)
        let ks = Data((0..<32).map { UInt8(0xC0 + $0) })
        let serverTag = E2EEV2Franking.serverTag(
            ks: ks, frankTagB64: frank.base64EncodedString(), conversationId: conversationId,
            envelopeId: "envelope_01J7ABCD23456789", senderUserId: userB, senderDeviceId: deviceB1, serverTimeMs: createdAtMs, keyId: "server_tag_key_01J7ABCD"
        )
        let clear = E2EEV2Report.clearJSON(
            reportId: "report_01J7ABCD23456789", conversationId: conversationId, reason: "HARASSMENT",
            items: [.init(envelopeId: "envelope_01J7ABCD23456789", frankTagB64: frank.base64EncodedString(), serverTagB64: serverTag.base64EncodedString(), blobIds: [])]
        )
        let items = [E2EEV2Report.SealedItem(envelopeId: "envelope_01J7ABCD23456789", payload: payload, fk: fk, mediaKeys: [])]
        let sealed = try E2EEV2Report.seal(clearJSON: clear, items: items, moderationKey: moderation.publicKey, ephemeral: ephemeral)
        let tamperedClear = clear.replacingOccurrences(of: "HARASSMENT", with: "SPAM")
        var tamperedSealed = sealed.sealed
        tamperedSealed[tamperedSealed.startIndex] ^= 0x01
        return .o([
            ("fixtureVersion", .s("1")),
            ("moderationPrivateRawB64", .s(moderation.rawRepresentation.base64EncodedString())),
            ("moderationPublicX963B64", .s(moderation.publicKey.x963Representation.base64EncodedString())),
            ("moderationKeyId", .s("moderation_key_01J7ABCD2345")),
            ("hpkeSuite", .s("0x0010/0x0001/0x0002")),
            ("ephemeralIkmB64", .s(ikm.base64EncodedString())),
            ("senderDeviceId", .s(deviceB1)), ("clientRequestId", .s("message_01J7ABCD23456789")),
            // De quoi recalculer chaque `serverTag` de la partie en clair (D.9).
            ("ksB64", .s(ks.base64EncodedString())), ("senderUserId", .s(userB)),
            ("serverTimeMs", .s(String(createdAtMs))), ("keyId", .s("server_tag_key_01J7ABCD")),
            ("clearUtf8", .s(clear)),
            ("infoB64", .s(E2EEV2Report.info(clearJSON: clear).base64EncodedString())),
            ("sealedPlaintextUtf8", .s(String(decoding: E2EEV2Report.sealedJSON(items: items), as: UTF8.self))),
            ("encB64", .s(sealed.enc.base64EncodedString())), ("sealedB64", .s(sealed.sealed.base64EncodedString())),
            ("negative", .a([
                .o([("case", .s("tamperedClear")), ("clearUtf8", .s(tamperedClear))]),
                .o([("case", .s("tamperedSealed")), ("sealedB64", .s(tamperedSealed.base64EncodedString()))]),
            ])),
        ])
    }

    func buildCallDescriptor() throws -> VJ {
        let caller = try signingKey(0x31)
        let epochKey = Data((0..<32).map { UInt8(0x80 + $0) })
        let nonce = Data((0..<32).map { UInt8(0x90 + $0) }).base64EncodedString()
        let descriptor = E2EEV2CallDescriptor(
            conversationId: conversationId, callId: "call_01J7ABCD23456789XY", callerDeviceId: deviceA1,
            epochId: "epoch_01J7ABCD23456789", epochNumber: 1, keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey),
            callNonceB64: nonce, createdAtMs: createdAtMs
        )
        let signed = try E2EEV2SignedString.sign(descriptor.canonical, with: caller)
        let extra = descriptor.canonical + "\nextra"
        let shortNonce = descriptor.canonical.replacingOccurrences(of: nonce, with: Data(repeating: 1, count: 16).base64EncodedString())
        return .o([
            ("fixtureVersion", .s("1")),
            ("callerSigningPrivateRawB64", .s(caller.rawRepresentation.base64EncodedString())),
            ("callerSigningPublicX963B64", .s(caller.publicKey.x963Representation.base64EncodedString())),
            ("createdAtMs", .s(String(createdAtMs))),
            ("descriptorUtf8", .s(descriptor.canonical)), ("signatureDerB64", .s(signed.signatureB64)),
            ("e2eeV2JsonUtf8", .s(E2EEV2CanonicalJSON.encodeString(E2EEV2CallDescriptor.e2eeV2JSON(signed, callerDeviceId: deviceA1)))),
            ("negative", .a([
                .o([("case", .s("highS")), ("signatureDerB64", .s(try highS(signed.signatureB64)))]),
                .o([("case", .s("expiredRinging")), ("nowMs", .s(String(createdAtMs + 61_000)))]),
                .o([("case", .s("extraField")), ("descriptorUtf8", .s(extra)), ("signatureDerB64", .s(try E2EEV2SignedString.sign(extra, with: caller).signatureB64))]),
                .o([("case", .s("shortNonce")), ("descriptorUtf8", .s(shortNonce)), ("signatureDerB64", .s(try E2EEV2SignedString.sign(shortNonce, with: caller).signatureB64))]),
            ])),
        ])
    }

    func buildCallFrameKey() throws -> VJ {
        let epochKey = Data((0..<32).map { UInt8(0x80 + $0) })
        let nonce = Data((0..<32).map { UInt8(0x90 + $0) }).base64EncodedString()
        let callId = "call_01J7ABCD23456789XY"
        let key = try E2EEV2CallFrameKeyV2.derive(epochKey: epochKey, conversationId: conversationId, epochNumber: 1, callId: callId, callNonceB64: nonce)
        let salt = E2EEV2CallFrameKeyV2.saltCanonical(conversationId: conversationId, epochNumber: 1, callId: callId, callNonceB64: nonce)
        return .o([
            ("fixtureVersion", .s("1")), ("conversationId", .s(conversationId)), ("epochNumber", .s("1")),
            ("callId", .s(callId)), ("callNonceB64", .s(nonce)), ("epochKeyB64", .s(epochKey.base64EncodedString())),
            ("info", .s(E2EEV2CallFrameKeyV2.info)),
            ("saltCanonicalUtf8", .s(String(decoding: salt, as: UTF8.self))),
            ("saltB64", .s(Data(SHA256.hash(data: salt)).base64EncodedString())),
            ("frameKeyB64", .s(key.base64EncodedString())),
            ("livekitPassphrase", .s(E2EEV2CallFrameKeyV2.livekitPassphrase(key))),
        ])
    }

    func buildJoinProof() throws -> VJ {
        let signing = try signingKey(0x33)
        let nonce = Data((0..<32).map { UInt8(0x90 + $0) }).base64EncodedString()
        let identity = E2EEV2CallJoinProof.livekitIdentity(userId: userB, deviceId: deviceB1)
        let proof = E2EEV2CallJoinProof(
            conversationId: conversationId, callId: "call_01J7ABCD23456789XY", callNonceB64: nonce,
            livekitIdentity: identity, userId: userB, deviceId: deviceB1, joinedAtMs: createdAtMs + 2_000
        )
        let signed = try E2EEV2SignedString.sign(proof.canonical, with: signing)
        let message = String(decoding: E2EEV2CallJoinProof.message(signed), as: UTF8.self)
        let emptyIdentity = proof.canonical.replacingOccurrences(of: "\n\(identity)\n", with: "\n\n")
        // Identité du compte seul : c'était celle des appels avant la v0.4.3.
        let accountIdentity = proof.canonical.replacingOccurrences(of: "\n\(identity)\n", with: "\n\(userB)\n")
        let highSMessage = String(decoding: E2EEV2CallJoinProof.message(E2EEV2SignedString(canonical: proof.canonical, signatureB64: try highS(signed.signatureB64))), as: UTF8.self)
        return .o([
            ("fixtureVersion", .s("1")),
            ("signingPrivateRawB64", .s(signing.rawRepresentation.base64EncodedString())),
            ("signingPublicX963B64", .s(signing.publicKey.x963Representation.base64EncodedString())),
            ("topic", .s(E2EEV2CallJoinProof.topic)),
            ("proofUtf8", .s(proof.canonical)), ("signatureDerB64", .s(signed.signatureB64)),
            ("messageUtf8", .s(message)),
            ("negative", .a([
                .o([("case", .s("highS")), ("messageUtf8", .s(highSMessage))]),
                .o([("case", .s("emptyIdentity")), ("messageUtf8", .s(String(decoding: E2EEV2CallJoinProof.message(try E2EEV2SignedString.sign(emptyIdentity, with: signing)), as: UTF8.self)))]),
                .o([("case", .s("identityIsNotTheDevice")), ("messageUtf8", .s(String(decoding: E2EEV2CallJoinProof.message(try E2EEV2SignedString.sign(accountIdentity, with: signing)), as: UTF8.self)))]),
                .o([("case", .s("extraKey")), ("messageUtf8", .s(message.replacingOccurrences(of: "{\"proof\"", with: "{\"a\":null,\"proof\"")))]),
            ])),
        ])
    }

    func buildApprovalV2() throws -> VJ {
        let fingerprint = try deviceFingerprint(identitySeed: 0x22, signingSeed: 0x32)
        let challenge = Data((0..<32).map { UInt8($0 * 3) }).base64URLEncodedNoPadding()
        let expires = createdAtMs + 300_000
        let approvalId = "approval_0000000000000002"
        let qr = E2EEV2ApprovalV2.QR(
            approvalId: approvalId, pendingDeviceId: deviceA2, platform: "web", fingerprint: fingerprint,
            challengeB64Url: challenge, expiresAtMs: expires
        )
        func payload(_ fields: [String]) -> VJ { .s(fields.joined(separator: "|")) }
        let fields = qr.payload.components(separatedBy: "|")
        let pendingNonce = Data((0..<32).map { UInt8(0x40 + $0) }).base64URLEncodedNoPadding()
        let approverNonce = Data((0..<32).map { UInt8(0x60 + $0) }).base64URLEncodedNoPadding()
        let otherNonce = Data((0..<32).map { UInt8(0x41 + $0) }).base64URLEncodedNoPadding()
        let proximity = E2EEV2ApprovalV2.proximityCode(
            userId: userA, approvalId: approvalId, pendingDeviceId: deviceA2, platform: "web",
            fingerprint: fingerprint, challengeB64Url: challenge
        )
        let otherFingerprint = try deviceFingerprint(identitySeed: 0x23, signingSeed: 0x33)
        let otherProximity = E2EEV2ApprovalV2.proximityCode(
            userId: userA, approvalId: approvalId, pendingDeviceId: deviceA2, platform: "web",
            fingerprint: otherFingerprint, challengeB64Url: challenge
        )
        let iosProximity = E2EEV2ApprovalV2.proximityCode(
            userId: userA, approvalId: approvalId, pendingDeviceId: deviceA2, platform: "ios",
            fingerprint: fingerprint, challengeB64Url: challenge
        )
        let typed = String(proximity.prefix(4)).lowercased() + "-" + String(proximity.dropFirst(4).prefix(4))
            + " " + String(proximity.dropFirst(8))
        return .o([
            ("fixtureVersion", .s("3")), ("userId", .s(userA)), ("approvalId", .s(approvalId)),
            ("pendingDeviceId", .s(deviceA2)), ("platform", .s("web")), ("fingerprint", .s(fingerprint)),
            ("challengeB64Url", .s(challenge)), ("expiresAtMs", .s(String(expires))),
            ("qrPayload", .s(qr.payload)),
            ("pendingNonceB64Url", .s(pendingNonce)), ("approverNonceB64Url", .s(approverNonce)),
            ("sasCommitCanonicalUtf8", .s(["SQ-E2EE-V2-SAS-COMMIT", "1", userA, approvalId, deviceA2, "web", fingerprint, pendingNonce].joined(separator: "\n"))),
            ("sasCommitB64Url", .s(E2EEV2ApprovalV2.sasCommitment(userId: userA, approvalId: approvalId, pendingDeviceId: deviceA2, platform: "web", fingerprint: fingerprint, pendingNonceB64Url: pendingNonce))),
            ("sasCanonicalUtf8", .s(["SQ-E2EE-V2-APPROVAL-SAS", "3", userA, deviceA2, "web", fingerprint, approvalId, pendingNonce, approverNonce].joined(separator: "\n"))),
            ("sas", .s(E2EEV2ApprovalV2.sas(userId: userA, pendingDeviceId: deviceA2, platform: "web", fingerprint: fingerprint, approvalId: approvalId, pendingNonceB64Url: pendingNonce, approverNonceB64Url: approverNonce))),
            ("proximityCanonicalUtf8", .s(["SQ-E2EE-V2-PROXIMITY", "1", userA, approvalId, deviceA2, "web", fingerprint, challenge].joined(separator: "\n"))),
            ("proximityCode", .s(proximity)),
            ("proximityTyped", .s(typed)),
            ("negative", .a([
                .o([("case", .s("sevenFields")), ("qrPayload", payload(fields.enumerated().filter { $0.offset != 4 }.map(\.element)))]),
                .o([("case", .s("version2")), ("qrPayload", payload(["SQE2EE2", "2"] + fields.dropFirst(2)))]),
                .o([("case", .s("uppercasePlatform")), ("qrPayload", payload(fields.enumerated().map { $0.offset == 4 ? "WEB" : $0.element }))]),
                .o([("case", .s("emptyPlatform")), ("qrPayload", payload(fields.enumerated().map { $0.offset == 4 ? "" : $0.element }))]),
                .o([("case", .s("unknownPlatform")), ("qrPayload", payload(fields.enumerated().map { $0.offset == 4 ? "desktop" : $0.element }))]),
                .o([("case", .s("extraField")), ("qrPayload", payload(fields + ["x"]))]),
                .o([("case", .s("revealedNonceDiffers")), ("pendingNonceB64Url", .s(otherNonce))]),
                .o([("case", .s("proximityForOtherKeys")), ("proximityTyped", .s(otherProximity))]),
                .o([("case", .s("proximityForOtherPlatform")), ("proximityTyped", .s(iosProximity))]),
            ])),
        ])
    }

    func buildSafetyNumber() throws -> VJ {
        let uikA = try signingKey(0x11).publicKey.x963Representation
        let uikB = try signingKey(0x13).publicKey.x963Representation
        let pair = E2EEV2SafetyNumber.pair(userA: userA, uikA: uikA, userB: userB, uikB: uikB)
        return .o([
            ("fixtureVersion", .s("1")), ("iterations", .s(String(E2EEV2SafetyNumber.iterations))),
            ("userA", .s(userA)), ("uikAPublicX963B64", .s(uikA.base64EncodedString())),
            ("userB", .s(userB)), ("uikBPublicX963B64", .s(uikB.base64EncodedString())),
            ("digitsA", .s(E2EEV2SafetyNumber.digits(uikX963: uikA, userId: userA))),
            ("digitsB", .s(E2EEV2SafetyNumber.digits(uikX963: uikB, userId: userB))),
            ("safetyNumber", .s(pair)), ("groups", .a(E2EEV2SafetyNumber.grouped(pair).map(VJ.s))),
            ("qrPayload", .s(E2EEV2SafetyNumber.qrPayload(pair))),
        ])
    }

    func buildIdentityReset() throws -> VJ {
        let previous = try signingKey(0x11)
        let newUik = try signingKey(0x14)
        let objecting = try signingKey(0x31)
        let reset = E2EEV2IdentityReset(
            userId: userA, newUikB64: newUik.publicKey.x963Representation.base64EncodedString(),
            previousUikFingerprint: E2EEV2IdentityReset.previousFingerprint(of: previous.publicKey.x963Representation),
            requestedAtMs: createdAtMs
        )
        let signed = try E2EEV2SignedString.sign(reset.canonical, with: newUik)
        let objection = E2EEV2IdentityReset.objectionCanonical(userId: userA, newUikB64: reset.newUikB64, objectingDeviceId: deviceA1, objectedAtMs: createdAtMs + 3_600_000)
        let objectionSigned = try E2EEV2SignedString.sign(objection, with: objecting)
        let wrongDelay = reset.canonical.replacingOccurrences(of: "\n\(reset.effectiveAtMs)", with: "\n\(createdAtMs + 1_000)")
        let signedByOld = try E2EEV2SignedString.sign(reset.canonical, with: previous)
        return .o([
            ("fixtureVersion", .s("1")), ("userId", .s(userA)),
            ("previousUikPublicX963B64", .s(previous.publicKey.x963Representation.base64EncodedString())),
            ("newUikPrivateRawB64", .s(newUik.rawRepresentation.base64EncodedString())),
            ("newUikPublicX963B64", .s(reset.newUikB64)),
            ("previousUikFingerprint", .s(reset.previousUikFingerprint)),
            ("requestedAtMs", .s(String(createdAtMs))), ("effectiveAtMs", .s(String(reset.effectiveAtMs))),
            ("resetUtf8", .s(reset.canonical)), ("signatureDerB64", .s(signed.signatureB64)),
            ("objectingSigningPrivateRawB64", .s(objecting.rawRepresentation.base64EncodedString())),
            ("objectingSigningPublicX963B64", .s(objecting.publicKey.x963Representation.base64EncodedString())),
            ("objectionUtf8", .s(objection)), ("objectionSignatureDerB64", .s(objectionSigned.signatureB64)),
            ("negative", .a([
                .o([("case", .s("wrongDelay")), ("resetUtf8", .s(wrongDelay)), ("signatureDerB64", .s(try E2EEV2SignedString.sign(wrongDelay, with: newUik).signatureB64))]),
                .o([("case", .s("signedByPreviousUik")), ("signatureDerB64", .s(signedByOld.signatureB64))]),
                .o([("case", .s("highS")), ("signatureDerB64", .s(try highS(signed.signatureB64)))]),
            ])),
        ])
    }

    /// Résultats attendus écrits à la main : le vecteur ne recopie pas
    /// l'implémentation qu'il vérifie.
    func buildCapabilityIntersection() -> VJ {
        let freshness = E2EEV2IdentityVerification.capabilityFreshnessMs
        let now = createdAtMs
        let userC = "user_chloe_01J7ABCD23456789"
        func document(
            _ userId: String, _ deviceId: String, sequence: Int, issuedAtMs: Int64,
            envelopes: [String], payloads: [String], kinds: [String], features: [String]
        ) -> String {
            E2EEV2CapabilitiesDocument(
                userId: userId, deviceId: deviceId, sequence: sequence, issuedAtMs: issuedAtMs,
                envelopeVersions: envelopes, payloadVersions: payloads, kinds: kinds, features: features
            ).document
        }
        func aliceIOS(issuedAtMs: Int64) -> String {
            document(userA, deviceA1, sequence: 3, issuedAtMs: issuedAtMs, envelopes: ["1", "2"], payloads: ["2"],
                     kinds: ["POLL", "TEXT"], features: ["calls", "voice"])
        }
        func brunoAndroid(issuedAtMs: Int64) -> String {
            document(userB, deviceB1, sequence: 2, issuedAtMs: issuedAtMs, envelopes: ["2"], payloads: ["2"],
                     kinds: ["TEXT"], features: ["calls"])
        }
        let aliceWeb = document(userA, deviceA2, sequence: 1, issuedAtMs: now - 3_000, envelopes: ["2"], payloads: ["2"],
                                kinds: ["TEXT"], features: ["voice"])
        func device(_ deviceId: String, _ platform: String, _ capabilities: String?) -> VJ {
            .o([("deviceId", .s(deviceId)), ("platform", .s(platform)), ("capabilities", capabilities.map(VJ.s) ?? .null)])
        }
        func member(_ userId: String, refused: Bool = false, _ devices: [VJ]) -> VJ {
            .o([("userId", .s(userId)), ("refused", .s(refused ? "1" : "0")), ("devices", .a(devices))])
        }
        func available(_ deviceIds: [String], envelopes: [String], payloads: [String], kinds: [String], features: [String]) -> VJ {
            .o([
                ("available", .s("1")), ("deviceIds", .a(deviceIds.map(VJ.s))),
                ("envelopeVersions", .a(envelopes.map(VJ.s))), ("payloadVersions", .a(payloads.map(VJ.s))),
                ("kinds", .a(kinds.map(VJ.s))), ("features", .a(features.map(VJ.s))),
            ])
        }
        let unavailable: VJ = .o([("available", .s("0"))])
        let both = available([deviceA1, deviceB1], envelopes: ["2"], payloads: ["2"], kinds: ["TEXT"], features: ["calls"])
        let aliceOnly = available([deviceA1], envelopes: ["1", "2"], payloads: ["2"], kinds: ["POLL", "TEXT"], features: ["calls", "voice"])
        func testCase(_ name: String, excludesWeb: Bool = false, _ members: [VJ], _ expected: VJ) -> VJ {
            .o([
                ("case", .s(name)), ("nowMs", .s(String(now))), ("excludesWeb", .s(excludesWeb ? "1" : "0")),
                ("members", .a(members)), ("expected", expected),
            ])
        }
        let alice = member(userA, [device(deviceA1, "ios", aliceIOS(issuedAtMs: now - 1_000))])
        let bruno = member(userB, [device(deviceB1, "android", brunoAndroid(issuedAtMs: now - 2_000))])
        let aliceWithBrowser = member(userA, [
            device(deviceA1, "ios", aliceIOS(issuedAtMs: now - 1_000)), device(deviceA2, "web", aliceWeb),
        ])
        return .o([
            ("fixtureVersion", .s("1")),
            ("freshnessMs", .s(String(freshness))),
            ("cases", .a([
                testCase("intersection", [alice, bruno], both),
                testCase("browserWithoutCalls", [aliceWithBrowser, bruno],
                         available([deviceA1, deviceA2, deviceB1], envelopes: ["2"], payloads: ["2"], kinds: ["TEXT"], features: [])),
                testCase("browsersExcluded", excludesWeb: true, [aliceWithBrowser, bruno], both),
                testCase("staleDocumentSidelined", [
                    alice, member(userB, [device(deviceB1, "android", brunoAndroid(issuedAtMs: now - freshness - 1))]),
                ], aliceOnly),
                testCase("justUnderNinetyDaysCounts", [
                    alice, member(userB, [device(deviceB1, "android", brunoAndroid(issuedAtMs: now - freshness + 1))]),
                ], both),
                testCase("exactlyNinetyDaysSidelined", [
                    alice, member(userB, [device(deviceB1, "android", brunoAndroid(issuedAtMs: now - freshness))]),
                ], aliceOnly),
                testCase("deviceWithoutDocumentSidelined", [alice, member(userB, [device(deviceB1, "android", nil)])], aliceOnly),
                testCase("memberWithoutCertifiedDevice", [alice, bruno, member(userC, [])], both),
                testCase("refusedMember", [alice, member(userB, refused: true, [
                    device(deviceB1, "android", brunoAndroid(issuedAtMs: now - 2_000)),
                ])], unavailable),
                testCase("noActiveDevice", [
                    member(userA, [device(deviceA1, "ios", aliceIOS(issuedAtMs: now - freshness - 1))]),
                    member(userB, [device(deviceB1, "android", nil)]),
                ], unavailable),
            ])),
        ])
    }

    // MARK: Réémission des vecteurs existants

    /// Remplace une signature high-S par sa forme low-S, sans toucher au reste
    /// du fichier (même contenu, `s` remplacé par `n − s`).
    func reissueLowS(name: String, path: [String]) throws {
        let url = vectorURL(name)
        var text = try String(contentsOf: url, encoding: .utf8)
        var node: Any = try JSONSerialization.jsonObject(with: Data(text.utf8))
        for key in path.dropLast() { node = try XCTUnwrap((node as? [String: Any])?[key]) }
        let old = try XCTUnwrap((node as? [String: Any])?[path.last ?? ""] as? String)
        let normalized = try E2EEV2LowS.normalize(der: try XCTUnwrap(Data(base64Encoded: old))).base64EncodedString()
        guard normalized != old else { return }
        XCTAssertEqual(text.components(separatedBy: old).count, 2, "signature unique attendue dans \(name)")
        text = text.replacingOccurrences(of: old, with: normalized)
        try Data(text.utf8).write(to: url)
    }

    /// `message-envelope-v1` portait un clair qui n'est pas une charge valide :
    /// on le remplace par une charge v1 `TEXT` et on refait chiffré et signature
    /// (nouvelle clé d'émetteur, la clé privée d'origine n'étant pas publiée).
    func regenerateMessageEnvelopeV1() throws {
        let url = vectorURL("message-envelope-v1")
        let original = try String(contentsOf: url, encoding: .utf8)
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let order = try NSRegularExpression(pattern: #"^  "([A-Za-z0-9]+)":"#, options: [.anchorsMatchLines])
            .matches(in: original, range: NSRange(original.startIndex..., in: original))
            .compactMap { Range($0.range(at: 1), in: original).map { String(original[$0]) } }
        let context = E2EEV2MessageContext(
            conversationId: try XCTUnwrap(root["conversationId"] as? String),
            epochNumber: try XCTUnwrap(root["epochNumber"] as? Int),
            senderDeviceId: try XCTUnwrap(root["senderDeviceId"] as? String),
            clientRequestId: try XCTUnwrap(root["clientRequestId"] as? String),
            ttlSeconds: try XCTUnwrap(root["ttlSeconds"] as? Int),
            encryptedBlobIds: try XCTUnwrap(root["encryptedBlobIds"] as? [String])
        )
        let cleartext = try E2EEV2ContentContract.encode([
            "schema": E2EEV2ContentContract.schema, "version": 1, "kind": "TEXT",
            "replyToId": NSNull(), "mentions": [String](), "body": ["text": "Bonjour du monde 🌍"],
        ])
        let envelope = try E2EEV2MessageCrypto.encrypt(
            cleartext: cleartext,
            epochKey: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(root["epochKeyB64"] as? String))),
            nonce: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(root["nonceB64"] as? String))),
            context: context
        )
        let sender = try signingKey(0x35)
        let canonical = try E2EEV2MessageCrypto.signatureCanonical(context: context, envelope: envelope)
        root["cleartextUtf8"] = String(decoding: cleartext, as: UTF8.self)
        root["ciphertextB64"] = envelope.ciphertextB64
        root["signatureCanonicalUtf8"] = String(decoding: canonical, as: UTF8.self)
        root["senderPublicSigningKeyB64"] = sender.publicKey.x963Representation.base64EncodedString()
        root["senderSignatureDerB64"] = try E2EEV2LowS.sign(canonical, with: sender).base64EncodedString()
        root["senderSigningPrivateRawB64"] = sender.rawRepresentation.base64EncodedString()
        let keys = order + root.keys.filter { !order.contains($0) }.sorted()
        let rebuilt: VJ = .o(try keys.map { key in (key, try vj(from: XCTUnwrap(root[key]))) })
        try Data((render(rebuilt) + "\n").utf8).write(to: url)
    }
}

// MARK: - Outils

private indirect enum VJ {
    case s(String)
    case i(Int)
    case b(Bool)
    case null
    case a([VJ])
    case o([(String, VJ)])
}

private func render(_ value: VJ, indent: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent)
    let inner = String(repeating: " ", count: indent + 2)
    switch value {
    case .s(let text): return E2EEV2CanonicalJSON.encodeString(.string(text))
    case .i(let number): return String(number)
    case .b(let flag): return flag ? "true" : "false"
    case .null: return "null"
    case .a(let items):
        guard !items.isEmpty else { return "[]" }
        return "[\n" + items.map { inner + render($0, indent: indent + 2) }.joined(separator: ",\n") + "\n" + pad + "]"
    case .o(let fields):
        guard !fields.isEmpty else { return "{}" }
        return "{\n" + fields.map { inner + E2EEV2CanonicalJSON.encodeString(.string($0.0)) + ": " + render($0.1, indent: indent + 2) }
            .joined(separator: ",\n") + "\n" + pad + "}"
    }
}

private func vj(from value: Any) throws -> VJ {
    switch value {
    case let text as String: return .s(text)
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .b(number.boolValue) }
        return .i(number.intValue)
    case is NSNull: return .null
    case let items as [Any]: return .a(try items.map(vj(from:)))
    case let object as [String: Any]: return .o(try object.keys.sorted().map { ($0, try vj(from: object[$0] as Any)) })
    default: throw E2EEV2TrustFormatError.invalidField
    }
}

private extension E2EEV2JalonAVectorTests {
    func vectorURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-v2/\(name).json")
    }

    func load(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL(name))) as? [String: Any])
    }

    func str(_ dictionary: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(dictionary[key] as? String, "clé \(key)")
    }

    /// Valeur d'un cas négatif, ou à défaut celle du vecteur positif.
    func str(_ negative: [String: Any], _ key: String, default positive: [String: Any], fallbackKey: String? = nil) throws -> String {
        if let value = negative[key] as? String { return value }
        return try str(positive, fallbackKey ?? key)
    }

    func b64(_ dictionary: [String: Any], _ key: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try str(dictionary, key)), "base64 \(key)")
    }

    func b64(_ negative: [String: Any], _ key: String, default positive: [String: Any]) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try str(negative, key, default: positive)), "base64 \(key)")
    }

    func int(_ dictionary: [String: Any], _ key: String) throws -> Int {
        try XCTUnwrap(Int(try str(dictionary, key)), "entier \(key)")
    }

    func int64(_ dictionary: [String: Any], _ key: String) throws -> Int64 {
        try XCTUnwrap(Int64(try str(dictionary, key)), "entier \(key)")
    }

    func strings(_ dictionary: [String: Any], _ key: String) throws -> [String] {
        try XCTUnwrap(dictionary[key] as? [String], "liste \(key)")
    }

    func caseName(_ negative: [String: Any]) -> String {
        negative["case"] as? String ?? "cas négatif"
    }

    func forEachNegative(_ vector: [String: Any], _ body: ([String: Any]) throws -> Void) throws {
        let negatives = try XCTUnwrap(vector["negative"] as? [[String: Any]])
        XCTAssertFalse(negatives.isEmpty)
        for negative in negatives { try body(negative) }
    }

    func signingKey(_ seed: UInt8) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data((0..<32).map { seed &+ UInt8($0) }))
    }

    func agreementKey(_ seed: UInt8) throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: Data((0..<32).map { seed &+ UInt8($0) }))
    }

    func signingKey(fromB64 value: String) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: try XCTUnwrap(Data(base64Encoded: value)))
    }

    func agreementKey(fromB64 value: String) throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: try XCTUnwrap(Data(base64Encoded: value)))
    }

    func deviceFingerprint(identitySeed: UInt8, signingSeed: UInt8) throws -> String {
        E2EEV2Canonical.deviceFingerprint(
            identityKeyX963: try agreementKey(identitySeed).publicKey.x963Representation,
            signingKeyX963: try signingKey(signingSeed).publicKey.x963Representation
        )
    }

    /// Même signature, avec un zéro de tête superflu devant `r` (D.0).
    func nonCanonicalDer(_ signatureB64: String) throws -> String {
        var der = [UInt8](try XCTUnwrap(Data(base64Encoded: signatureB64)))
        XCTAssertEqual(der[0], 0x30)
        XCTAssertEqual(der[2], 0x02)
        der.insert(0x00, at: 4)
        der[3] += 1
        der[1] += 1
        return Data(der).base64EncodedString()
    }

    /// Même signature, suivie d'un octet en trop (D.0).
    func trailingDerBytes(_ signatureB64: String) throws -> String {
        (try XCTUnwrap(Data(base64Encoded: signatureB64)) + Data([0x00])).base64EncodedString()
    }

    func highS(_ signatureB64: String) throws -> String {
        try E2EEV2LowS.highSVariant(der: try XCTUnwrap(Data(base64Encoded: signatureB64))).base64EncodedString()
    }

    func hex(_ text: String) -> Data {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes)
    }

    func wrap(from vector: [String: Any], overrides: [String: Any] = [:]) throws -> E2EEV2UIKWrap {
        func value(_ key: String) throws -> String { try str(overrides, key, default: vector) }
        return E2EEV2UIKWrap(
            userId: try value("userId"), approverDeviceId: try value("approverDeviceId"), newDeviceId: try value("newDeviceId"),
            uikPublicKeyB64: try value("uikPublicX963B64"), ephemeralPublicKeyB64: try value("ephemeralPublicX963B64"),
            nonceB64: try value("nonceB64"), aadB64: try value("aadB64"), wrappedUikB64: try value("wrappedUikB64"),
            signatureB64: try value("signatureDerB64")
        )
    }

    func messageContextV2(_ vector: [String: Any], counterOverride: String? = nil) throws -> E2EEV2MessageContextV2 {
        let counterText = try counterOverride ?? str(vector, "counter")
        return E2EEV2MessageContextV2(
            conversationId: try str(vector, "conversationId"), epochNumber: try int(vector, "epochNumber"),
            senderDeviceId: try str(vector, "senderDeviceId"), clientRequestId: try str(vector, "clientRequestId"),
            counter: try XCTUnwrap(Int64(counterText)),
            ttlSeconds: try int(vector, "ttlSeconds"), encryptedBlobIds: try strings(vector, "encryptedBlobIds")
        )
    }

    func envelopeV2(_ envelope: E2EEV2MessageEnvelopeV2, overrides: [String: Any]) -> E2EEV2MessageEnvelopeV2 {
        E2EEV2MessageEnvelopeV2(
            envelopeVersion: envelope.envelopeVersion, epochNumber: envelope.epochNumber,
            clientRequestId: envelope.clientRequestId, counter: envelope.counter, algorithm: envelope.algorithm,
            contentType: envelope.contentType, keyCommitmentB64: envelope.keyCommitmentB64,
            ttlSeconds: envelope.ttlSeconds, encryptedBlobIds: envelope.encryptedBlobIds,
            frankTagB64: overrides["frankTagB64"] as? String ?? envelope.frankTagB64,
            nonceB64: envelope.nonceB64,
            aadB64: overrides["aadB64"] as? String ?? envelope.aadB64,
            ciphertextB64: overrides["ciphertextB64"] as? String ?? envelope.ciphertextB64
        )
    }
}
