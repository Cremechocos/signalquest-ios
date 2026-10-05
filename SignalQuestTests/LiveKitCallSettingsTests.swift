#if canImport(LiveKit)
import LiveKit
import XCTest
@testable import SignalQuest

/// COM-1 (plan 3, jalon A) : les réglages de chiffrement des appels sont posés
/// un par un, tels que la spec les fige (§10.3), et non laissés aux défauts du
/// SDK, qui diffèrent entre iOS, Android et le web.
final class LiveKitCallSettingsTests: XCTestCase {
    func testKeyProviderOptionsAreTheSpecifiedOnes() {
        let options = E2EEV2LiveKitSession.keyProviderOptions
        XCTAssertTrue(options.sharedKey)
        XCTAssertEqual(options.ratchetSalt, Data("LKFrameEncryptionKey".utf8))
        XCTAssertEqual(options.ratchetWindowSize, 0, "Pas de ratchet : une clé par appel")
        XCTAssertEqual(options.uncryptedMagicBytes, Data("LK-ROCKS".utf8))
        XCTAssertEqual(options.failureTolerance, 10)
        XCTAssertEqual(options.keyRingSize, 16)
        XCTAssertTrue(options.discardFrameWhenCryptorNotReady, "Aucune trame avant que la clé soit posée")
        XCTAssertEqual(options.keyDerivationAlgorithm, .pbkdf2)
    }

    /// Vecteur commun `livekit-shared-key-v1` (§10.3) : la phrase de passe
    /// tirée de la clé de trame v2 et chaque réglage figé, relus contre le SDK.
    func testSharedKeyVectorMatchesThePassphraseAndSettings() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-v2")
        let vector = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("livekit-shared-key-v1.json"))
        ) as? [String: Any])
        let source = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("call-frame-key-v2.json"))
        ) as? [String: Any])
        let settings = try XCTUnwrap(vector["settings"] as? [String: Any])
        let options = E2EEV2LiveKitSession.keyProviderOptions
        XCTAssertEqual(settings["sharedKey"] as? Bool, options.sharedKey)
        XCTAssertEqual(settings["keyDerivationAlgorithm"] as? String, "PBKDF2")
        XCTAssertEqual(options.keyDerivationAlgorithm, .pbkdf2)
        XCTAssertEqual((settings["ratchetSaltUtf8"] as? String).map { Data($0.utf8) }, options.ratchetSalt)
        XCTAssertEqual((settings["ratchetWindowSize"] as? String).flatMap(Int32.init), options.ratchetWindowSize)
        XCTAssertEqual((settings["keyRingSize"] as? String).flatMap(Int32.init), options.keyRingSize)
        XCTAssertEqual((settings["failureTolerance"] as? String).flatMap(Int32.init), options.failureTolerance)
        XCTAssertEqual((settings["uncryptedMagicBytesUtf8"] as? String).map { Data($0.utf8) }, options.uncryptedMagicBytes)
        XCTAssertEqual(settings["discardFrameWhenCryptorNotReady"] as? Bool, options.discardFrameWhenCryptorNotReady)
        XCTAssertEqual(settings["encryptionType"] as? String, "gcm")

        let frameKey = try E2EEV2CallFrameKeyV2.derive(
            epochKey: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(source["epochKeyB64"] as? String))),
            conversationId: try XCTUnwrap(source["conversationId"] as? String),
            epochNumber: try XCTUnwrap((source["epochNumber"] as? String).flatMap(Int.init)),
            callId: try XCTUnwrap(source["callId"] as? String),
            callNonceB64: try XCTUnwrap(source["callNonceB64"] as? String)
        )
        XCTAssertEqual(frameKey.base64EncodedString(), vector["frameKeyB64"] as? String)
        let passphrase = E2EEV2CallFrameKeyV2.livekitPassphrase(frameKey)
        XCTAssertEqual(passphrase, vector["passphrase"] as? String)
        XCTAssertEqual(Data(passphrase.utf8).base64EncodedString(), vector["installedKeyUtf8B64"] as? String)
    }

    func testSessionInstallsTheBase64PassphraseAsKeyZeroWithGCM() throws {
        let epochKey = Data((0..<32).map { UInt8($0) })
        let context = E2EEV2CallFrameKeyContext(
            conversationId: "conv_0123456789abcdef", epochNumber: 1, callId: "call_0123456789abcdef"
        )
        let session = try E2EEV2LiveKitSession.make(epochKey: epochKey, context: context)
        XCTAssertEqual(session.encryptionOptions.encryptionType, .gcm)
        XCTAssertEqual(session.keyProvider.options, E2EEV2LiveKitSession.keyProviderOptions)
        XCTAssertEqual(session.keyProvider.getCurrentKeyIndex(), 0)

        // La clé posée est la CHAÎNE base64 de la clé de trame, comme
        // `setSharedKey(String)` sous Android et une chaîne sous le web.
        let frameKey = try E2EEV2CallFrameKey.derive(epochKey: epochKey, context: context)
        let passphrase = try E2EEV2CallFrameKey.liveKitSharedPassphrase(frameKey: frameKey)
        XCTAssertEqual(session.keyProvider.exportKey(index: 0), Data(passphrase.utf8))
    }
}
#endif
