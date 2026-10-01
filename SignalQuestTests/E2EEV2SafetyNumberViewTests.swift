import CryptoKit
import SwiftUI
import XCTest
@testable import SignalQuest

/// Plan 3, lot 3 : l'écran du numéro de sécurité (§2.4, D.12), son modèle et
/// son rendu en français et en anglais (`build/qa/safety-number`).
@MainActor
final class E2EEV2SafetyNumberViewTests: XCTestCase {
    private let aliceId = "user_alice_01J7ABCD2345"
    private let brunoId = "user_bruno_01J7ABCD2345"
    private let alice = P256.Signing.PrivateKey().publicKey
    private let bruno = P256.Signing.PrivateKey().publicKey

    private actor StubTrust: E2EEV2SafetyNumberTrusting {
        private(set) var identity: E2EEV2SafetyNumberIdentity
        private(set) var calls: [String] = []
        private var nextFailure: (any Error)?
        private var identityAfterFailure: E2EEV2SafetyNumberIdentity?
        private var loadFailure: (any Error)?

        init(_ identity: E2EEV2SafetyNumberIdentity) { self.identity = identity }

        func failLoads(with error: (any Error)?) { loadFailure = error }

        func replace(with identity: E2EEV2SafetyNumberIdentity) { self.identity = identity }

        func failNextChoice(with error: any Error, then identity: E2EEV2SafetyNumberIdentity? = nil) {
            nextFailure = error
            identityAfterFailure = identity
        }

        func safetyNumberIdentity(userId: String) throws -> E2EEV2SafetyNumberIdentity {
            if let loadFailure { throw loadFailure }
            return identity
        }

        func setVerified(_ verified: Bool, userId: String, uikX963B64: String) throws {
            calls.append("setVerified(\(verified))")
            try failIfAsked()
            identity = E2EEV2SafetyNumberIdentity(userId: userId, uikX963B64: uikX963B64, status: verified ? .verified : .unverified)
        }

        func acceptChangedIdentity(userId: String, uikX963B64: String, verified: Bool) throws {
            calls.append("accept(\(verified))")
            try failIfAsked()
            identity = E2EEV2SafetyNumberIdentity(userId: userId, uikX963B64: uikX963B64, status: verified ? .verified : .unverified)
        }

        private func failIfAsked() throws {
            guard let failure = nextFailure else { return }
            nextFailure = nil
            if let identityAfterFailure { identity = identityAfterFailure }
            throw failure
        }
    }

    private func identity(_ key: P256.Signing.PublicKey, userId: String, _ status: E2EEV2SafetyNumberIdentity.Status) -> E2EEV2SafetyNumberIdentity {
        E2EEV2SafetyNumberIdentity(userId: userId, uikX963B64: key.x963Representation.base64EncodedString(), status: status)
    }

    private struct UnexpectedState: Error {}

    /// Un état autre que « prêt » fait échouer le test, jamais l'ignorer.
    private func content(
        _ model: E2EEV2SafetyNumberViewModel, file: StaticString = #filePath, line: UInt = #line
    ) throws -> E2EEV2SafetyNumberViewModel.Content {
        guard case .ready(let content) = model.state else {
            XCTFail("État inattendu : \(model.state)", file: file, line: line)
            throw UnexpectedState()
        }
        return content
    }

    func testBothSidesShowTheSameSixtyDigits() async throws {
        let aliceSide = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { [alice] in alice },
            trust: StubTrust(identity(bruno, userId: brunoId, .unverified))
        )
        let brunoSide = E2EEV2SafetyNumberViewModel(
            peerUserId: aliceId, peerName: "Alice", ownUserId: brunoId, ownAccountKey: { [bruno] in bruno },
            trust: StubTrust(identity(alice, userId: aliceId, .unverified))
        )
        await aliceSide.load()
        await brunoSide.load()
        let shown = try content(aliceSide)
        XCTAssertEqual(shown.digits, try content(brunoSide).digits, "Les deux appareils montrent le même numéro (D.12)")
        XCTAssertEqual(shown.groups.count, 12)
        XCTAssertTrue(shown.groups.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
        XCTAssertEqual(E2EEV2SafetyNumber.qrPayload(shown.digits), "SQSN1|" + shown.digits)
        XCTAssertNotNil(shown.qrImage)
        let spoken = shown.spokenGroups.components(separatedBy: ", ")
        XCTAssertEqual(spoken.count, 12)
        XCTAssertEqual(spoken[0], shown.groups[0].map(String.init).joined(separator: " "),
                       "VoiceOver lit chiffre par chiffre : un zéro en tête n'est pas perdu")
    }

    func testVerifyingAndClearingFollowTheShownKey() async throws {
        let trust = StubTrust(identity(bruno, userId: brunoId, .unverified))
        let model = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { [alice] in alice }, trust: trust
        )
        await model.load()
        await model.markVerified(try content(model))
        XCTAssertEqual(try content(model).status, .verified)
        await model.clearVerification(try content(model))
        XCTAssertEqual(try content(model).status, .unverified)
        let calls = await trust.calls
        XCTAssertEqual(calls, ["setVerified(true)", "setVerified(false)"])
        XCTAssertNil(model.actionError)
    }

    func testAChoiceMadeOnAReplacedNumberDoesNothing() async throws {
        let renewed = P256.Signing.PrivateKey().publicKey
        let trust = StubTrust(identity(bruno, userId: brunoId, .unverified))
        let model = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { [alice] in alice }, trust: trust
        )
        await model.load()
        let seen = try content(model)
        await trust.replace(with: identity(renewed, userId: brunoId, .changed(wasVerified: false)))
        await model.load()
        await model.markVerified(seen)
        let calls = await trust.calls
        XCTAssertEqual(calls, [], "Le geste portait sur un numéro qui n'est plus affiché")
        XCTAssertEqual(try content(model).status, .changed(wasVerified: false))
    }

    func testAChangedNumberIsAcceptedVerifiedOrNot() async throws {
        let renewed = P256.Signing.PrivateKey().publicKey
        let verifying = StubTrust(identity(renewed, userId: brunoId, .changed(wasVerified: true)))
        let model = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { [alice] in alice }, trust: verifying
        )
        await model.load()
        await model.markVerified(try content(model))
        XCTAssertEqual(try content(model).status, .verified)
        let verifyingCalls = await verifying.calls
        XCTAssertEqual(verifyingCalls, ["accept(true)"])

        let seen = StubTrust(identity(renewed, userId: brunoId, .changed(wasVerified: false)))
        let other = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { [alice] in alice }, trust: seen
        )
        await other.load()
        await other.acceptWithoutVerifying(try content(other))
        XCTAssertEqual(try content(other).status, .unverified)
        let seenCalls = await seen.calls
        XCTAssertEqual(seenCalls, ["accept(false)"])
    }

    func testANumberThatChangesDuringTheChoiceIsShownAgain() async throws {
        let renewed = P256.Signing.PrivateKey().publicKey
        let trust = StubTrust(identity(bruno, userId: brunoId, .unverified))
        await trust.failNextChoice(
            with: E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged,
            then: identity(renewed, userId: brunoId, .changed(wasVerified: false))
        )
        let model = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { [alice] in alice }, trust: trust
        )
        await model.load()
        let before = try content(model).digits
        await model.markVerified(try content(model))
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(try content(model).status, .changed(wasVerified: false))
        XCTAssertNotEqual(try content(model).digits, before, "Le nouveau numéro remplace l'ancien à l'écran")
    }

    func testNoNumberWithoutTheAccountKeyOrATrustedIdentity() async throws {
        let noKey = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { nil },
            trust: StubTrust(identity(bruno, userId: brunoId, .unverified))
        )
        await noKey.load()
        guard case .failed = noKey.state else { return XCTFail("Sans clé de compte, pas de numéro") }

        let trust = StubTrust(identity(bruno, userId: brunoId, .unverified))
        await trust.failLoads(with: E2EEV2TrustDirectory.SafetyNumberFailure.refused(.deviceListRollback))
        let refused = E2EEV2SafetyNumberViewModel(
            peerUserId: brunoId, peerName: "Bruno", ownUserId: aliceId, ownAccountKey: { [alice] in alice }, trust: trust
        )
        await refused.load()
        guard case .failed(let message) = refused.state else { return XCTFail("Paquet refusé : pas de numéro") }
        XCTAssertTrue(message.contains("Bruno"))
        // Le refus levé, « Réessayer » recharge.
        await trust.failLoads(with: nil)
        await refused.load(showingProgress: true)
        XCTAssertEqual(try content(refused).status, .unverified)
    }

    func testTheScreenRendersInFrenchAndEnglish() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = repository.appendingPathComponent("build/qa/safety-number")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let digits = E2EEV2SafetyNumber.pair(
            userA: aliceId, uikA: alice.x963Representation, userB: brunoId, uikB: bruno.x963Representation
        )
        func content(_ status: E2EEV2SafetyNumberIdentity.Status) -> E2EEV2SafetyNumberViewModel.Content {
            E2EEV2SafetyNumberViewModel.Content(
                peerName: "Bruno", digits: digits, status: status,
                uikX963B64: bruno.x963Representation.base64EncodedString(),
                qrImage: E2EEV2SafetyNumberQR.image(for: E2EEV2SafetyNumber.qrPayload(digits))
            )
        }
        let cases: [(String, Locale, DynamicTypeSize, E2EEV2SafetyNumberIdentity.Status)] = [
            ("fr-non-verifie", Locale(identifier: "fr_FR"), .large, .unverified),
            ("en-verified", Locale(identifier: "en_US"), .large, .verified),
            ("fr-change", Locale(identifier: "fr_FR"), .large, .changed(wasVerified: false)),
            ("en-changed-verified", Locale(identifier: "en_US"), .large, .changed(wasVerified: true)),
            ("fr-xxl", Locale(identifier: "fr_FR"), .accessibility2, .changed(wasVerified: true)),
            ("fr-ax5", Locale(identifier: "fr_FR"), .accessibility5, .unverified),
        ]
        // `\.locale` traduit les `Text`, pas les `String(localized:)` : leurs
        // libellés suivent la langue du processus de test. Le parcours
        // d'interface en anglais vérifie le rendu réel.
        for (name, locale, size, status) in cases {
            let view = E2EEV2SafetyNumberContent(content: content(status))
                .padding(16)
                .frame(width: 390)
                .background(SQColor.bg)
                .environment(\.dynamicTypeSize, size)
                .environment(\.locale, locale)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 390, accuracy: 0.1)
            XCTAssertGreaterThan(image.size.height, 300)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
    }
}
