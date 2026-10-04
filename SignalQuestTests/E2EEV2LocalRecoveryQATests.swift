import CryptoKit
import XCTest
@testable import SignalQuest

/// Essai de bout en bout de la récupération v3 contre une pile serveur locale
/// (§2.8, v0.4.21, lot A2) : un appareil déjà certifié publie un bundle v3 qui
/// enveloppe l'UIK ; un appareil neuf du même compte, avec sa propre session
/// et son propre coffre, se récupère avec la seule clé de récupération et se
/// certifie lui-même ; il figure ensuite dans la liste signée du compte.
/// L'appareil d'origine le révoque à la fin pour laisser le compte propre.
///
/// Opt-in : `TEST_RUNNER_SQ_E2EE_V2_RECOVERY_QA_BASE_URL` (boucle locale),
/// `…_EMAIL` (compte dont l'identité est gardée sous `…_RUN`), `…_PASSWORD`.
final class E2EEV2LocalRecoveryQATests: XCTestCase {
    private func environment(_ name: String) -> String? {
        let values = ProcessInfo.processInfo.environment
        return values[name] ?? values["TEST_RUNNER_\(name)"]
    }

    private func login(email: String, password: String, base: URL) async throws -> (userId: String, token: String) {
        var request = URLRequest(url: base.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Connexion de \(email)")
        let cookie = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"))
        let token = try XCTUnwrap(cookie.components(separatedBy: ";").first?.components(separatedBy: "=").dropFirst().joined(separator: "="))
        let user = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["user"] as? [String: Any])
        return (try XCTUnwrap(user["id"] as? String), token)
    }

    private struct Device {
        let identity: E2EEV2DeviceIdentityStore
        let accounts: E2EEV2AccountIdentityStore
        let pins: E2EEV2TrustPinStore
        let api: APIClient
        let vault: KeychainStore
        var recovery: E2EEV2RecoveryCoordinatorV2 {
            E2EEV2RecoveryCoordinatorV2(api: api, identityStore: identity, accountIdentityStore: accounts, trustPins: pins,
                                        rotationCommitted: { _, _, _ in })
        }
        var lifecycle: E2EEV2DeviceLifecycleCoordinator {
            E2EEV2DeviceLifecycleCoordinator(
                api: api, identityStore: identity, epochKeyStore: E2EEV2EpochKeyStore(tokenStore: vault),
                conversationStateStore: E2EEV2ConversationStateStore(tokenStore: vault), accountIdentityStore: accounts,
                trustPins: pins, capabilities: E2EEV2CapabilitiesPublicationStore(tokenStore: vault), rotationCommitted: { _, _, _ in }
            )
        }
    }

    private func device(vaultService: String, userId: String, token: String, base: URL) throws -> Device {
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: userId)
        let credentials = CredentialStore(tokenStore: KeychainStore(service: vaultService + ".auth"))
        try credentials.setAccessToken(token)
        let config = AppConfig(environment: .test, appBaseURL: base, apiBaseURL: base, debugLogsEnabled: false)
        let vault = KeychainStore(service: vaultService)
        return Device(
            identity: E2EEV2DeviceIdentityStore(tokenStore: vault, identityChanged: { _ in }),
            accounts: E2EEV2AccountIdentityStore(tokenStore: vault), pins: E2EEV2TrustPinStore(tokenStore: vault),
            api: APIClient(config: config, credentials: credentials, session: APIClient.makeSession()), vault: vault
        )
    }

    func testANewDeviceRecoversWithTheRecoveryKeyAndCertifiesItself() async throws {
        guard let rawBase = environment("SQ_E2EE_V2_RECOVERY_QA_BASE_URL"), let base = URL(string: rawBase),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              let email = environment("SQ_E2EE_V2_RECOVERY_QA_EMAIL"),
              let password = environment("SQ_E2EE_V2_RECOVERY_QA_PASSWORD"),
              let run = environment("SQ_E2EE_V2_RECOVERY_QA_RUN") else {
            throw XCTSkip("Essai de récupération v3 local non demandé")
        }
        let previousUserId = LocalAccountScope.currentUserId
        let freshService = "fr.signalquest.ios.tests.e2ee.recovery." + UUID().uuidString
        defer {
            try? KeychainStore(service: freshService).removeAll()
            try? KeychainStore(service: freshService + ".auth").removeAll()
            LocalAccountScope.deactivate()
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) }
        }

        // 1. L'appareil d'origine (identité gardée) publie un bundle v3.
        let first = try await login(email: email, password: password, base: base)
        let originService = "fr.signalquest.ios.tests.e2ee.msg.\(run).\(first.userId)"
        var origin = try device(vaultService: originService, userId: first.userId, token: first.token, base: base)
        XCTAssertNotNil(try origin.accounts.load(ownerNamespace: LocalAccountScope.storageNamespace), "Identité gardée sous RUN")
        guard case .success(var material) = await origin.recovery.createAndUploadBundle() else {
            return XCTFail("Publication du bundle v3")
        }
        defer { material.zeroize() }
        XCTAssertEqual(material.bundle.version, 3)

        // 2. Un appareil neuf du même compte, sa propre session et son coffre.
        let second = try await login(email: email, password: password, base: base)
        let fresh = try device(vaultService: freshService, userId: second.userId, token: second.token, base: base)
        guard case .registered = await E2EEV2DeviceEnrollmentCoordinator(api: fresh.api, identityStore: fresh.identity)
            .registerPendingDevice(label: "QA récupération v3") else {
            return XCTFail("Enregistrement de l'appareil neuf")
        }
        let freshDevice = try XCTUnwrap(try fresh.identity.load(ownerNamespace: LocalAccountScope.storageNamespace))
        XCTAssertNil(try fresh.accounts.load(ownerNamespace: LocalAccountScope.storageNamespace), "L'appareil neuf n'a pas l'UIK")

        // 3. Récupération : il déballe l'UIK, se certifie, est approuvé.
        switch await fresh.recovery.recover(recoveryKey: material.recoveryKey) {
        case .success(let completion):
            XCTAssertEqual(completion.deviceId, freshDevice.deviceId)
        case .failed(let failure):
            return XCTFail("Récupération : \(failure.code ?? "") \(failure.message)")
        }
        let namespace = LocalAccountScope.storageNamespace
        let recovered = try XCTUnwrap(try fresh.accounts.load(ownerNamespace: namespace))
        XCTAssertTrue(try fresh.accounts.isVerified(ownerNamespace: namespace))
        let trust = try await E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: fresh.pins, ownUserId: second.userId, ownAccountKey: { recovered.publicKey },
            fetch: E2EEV2TrustDirectory.identityFetch(
                transport: E2EEV2APITransport(api: fresh.api, identityStore: fresh.identity),
                ownerScopeId: "user:\(second.userId)"
            )
        ).ownAccountTrust()
        XCTAssertTrue(trust.outcome.devices.contains { $0.deviceId == freshDevice.deviceId }, "Certifié dans la liste signée")

        // 4. L'appareil d'origine révoque l'appareil récupéré.
        origin = try device(vaultService: originService, userId: first.userId, token: first.token, base: base)
        guard case .success = await origin.lifecycle.revoke(deviceId: freshDevice.deviceId, reason: "USER_REQUEST") else {
            return XCTFail("Révocation de l'appareil récupéré")
        }
    }
}
