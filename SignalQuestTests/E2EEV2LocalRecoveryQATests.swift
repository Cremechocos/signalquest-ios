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
        var lifecycle: E2EEV2DeviceLifecycleCoordinator { lifecycle(aheadMs: 0) }

        /// `aheadMs` : horloge avancée, pour lire une bascule avancée sur la pile locale.
        func lifecycle(aheadMs: Int64) -> E2EEV2DeviceLifecycleCoordinator {
            E2EEV2DeviceLifecycleCoordinator(
                api: api, identityStore: identity, epochKeyStore: E2EEV2EpochKeyStore(tokenStore: vault),
                conversationStateStore: E2EEV2ConversationStateStore(tokenStore: vault), accountIdentityStore: accounts,
                trustPins: pins, capabilities: E2EEV2CapabilitiesPublicationStore(tokenStore: vault),
                nowMs: { Int64(Date().timeIntervalSince1970 * 1_000) + aheadMs }, rotationCommitted: { _, _, _ in }
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

    /// Lot A2 (§2.4, D.14) : un appareil neuf du compte demande la
    /// réinitialisation ; rien ne bascule, la demande attend 72 heures. Un
    /// appareil certifié de l'identité actuelle la lit, la vérifie et s'y
    /// oppose ; le demandeur voit le refus et oublie sa demande.
    func testAResetRequestedElsewhereWaitsAndIsRefusedByACertifiedDevice() async throws {
        guard let rawBase = environment("SQ_E2EE_V2_RECOVERY_QA_BASE_URL"), let base = URL(string: rawBase),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              let email = environment("SQ_E2EE_V2_RECOVERY_QA_EMAIL"),
              let password = environment("SQ_E2EE_V2_RECOVERY_QA_PASSWORD"),
              let run = environment("SQ_E2EE_V2_RECOVERY_QA_RUN") else {
            throw XCTSkip("Essai de réinitialisation local non demandé")
        }
        let previousUserId = LocalAccountScope.currentUserId
        let freshService = "fr.signalquest.ios.tests.e2ee.reset." + UUID().uuidString
        defer {
            try? KeychainStore(service: freshService).removeAll()
            try? KeychainStore(service: freshService + ".auth").removeAll()
            LocalAccountScope.deactivate()
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) }
        }

        // 1. La génération courante, lue par l'appareil d'origine (identité gardée).
        let first = try await login(email: email, password: password, base: base)
        let originService = "fr.signalquest.ios.tests.e2ee.msg.\(run).\(first.userId)"
        var origin = try device(vaultService: originService, userId: first.userId, token: first.token, base: base)
        guard case .success(let inventory) = await origin.lifecycle.listDeviceInventory(),
              let generation = inventory.identity?.generation else {
            return XCTFail("Inventaire de l'appareil d'origine")
        }

        // 2. Un appareil neuf demande la réinitialisation : elle reste en attente.
        let second = try await login(email: email, password: password, base: base)
        let fresh = try device(vaultService: freshService, userId: second.userId, token: second.token, base: base)
        guard case .success(let candidate) = fresh.lifecycle.prepareIdentityReset(label: "QA réinitialisation") else {
            return XCTFail("Appareil de remplacement")
        }
        let requested: E2EEV2IdentityResetStatus
        switch await fresh.lifecycle.resetIdentity(expectedGeneration: generation, reauthentication: .password(password)) {
        case .success(let status): requested = status
        case .failed(let failure): return XCTFail("Demande : \(failure.code ?? "") \(failure.message)")
        }
        XCTAssertEqual(requested.state, .pending)
        XCTAssertEqual(requested.replacementDeviceId, candidate.deviceId)
        let delay = requested.effectiveAtMs - Int64(Date().timeIntervalSince1970 * 1_000)
        XCTAssertTrue((E2EEV2IdentityReset.delayMs - 600_000...E2EEV2IdentityReset.delayMs).contains(delay), "Échéance à 72 heures")
        guard case .success(let followed)? = await fresh.lifecycle.refreshIdentityReset() else {
            return XCTFail("Suivi de la demande")
        }
        XCTAssertEqual(followed.state, .pending)
        XCTAssertNotNil(try fresh.identity.loadResetCandidate(ownerNamespace: LocalAccountScope.storageNamespace),
                        "Rien ne bascule avant l'échéance")

        // 3. L'appareil d'origine la voit dans son paquet de confiance et s'y oppose.
        origin = try device(vaultService: originService, userId: first.userId, token: first.token, base: base)
        let served = await origin.lifecycle.pendingIdentityResetToReview()
        let review = try XCTUnwrap(served, "Réinitialisation servie et vérifiée")
        XCTAssertEqual(review.resetId, requested.resetId)
        switch await origin.lifecycle.objectIdentityReset(review) {
        case .success(let status): XCTAssertEqual(status.state, .objected)
        case .failed(let failure): return XCTFail("Opposition : \(failure.code ?? "") \(failure.message)")
        }
        let none = await origin.lifecycle.pendingIdentityResetToReview()
        XCTAssertNil(none, "Plus rien à signaler")

        // 4. Le demandeur voit le refus et oublie sa demande et son appareil de remplacement.
        let refreshed = try device(vaultService: freshService, userId: second.userId, token: second.token, base: base)
        guard case .success(let refused)? = await refreshed.lifecycle.refreshIdentityReset() else {
            return XCTFail("Suivi après opposition")
        }
        XCTAssertEqual(refused.state, .objected)
        XCTAssertNil(try refreshed.accounts.loadPendingReset(ownerNamespace: LocalAccountScope.storageNamespace))
        XCTAssertNil(try refreshed.identity.loadResetCandidate(ownerNamespace: LocalAccountScope.storageNamespace))
    }

    /// Lot A2 : la bascule réelle, sur un compte réservé à cet essai (elle
    /// révoque tous ses autres appareils). L'essai écrit l'identifiant de la
    /// demande dans `…_HANDOFF` ; le script de lancement avance l'échéance sur
    /// la pile locale et lance la bascule. L'appareil demandeur la lit alors,
    /// active son appareil de remplacement et sa nouvelle clé de compte, puis
    /// se retrouve seul certifié dans la liste v1 signée par elle.
    func testAResetSwitchesAtItsDeadlineToTheReplacementDeviceAndNewAccountKey() async throws {
        guard let rawBase = environment("SQ_E2EE_V2_RESET_QA_BASE_URL"), let base = URL(string: rawBase),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              let email = environment("SQ_E2EE_V2_RESET_QA_EMAIL"),
              let password = environment("SQ_E2EE_V2_RESET_QA_PASSWORD"),
              let handoff = environment("SQ_E2EE_V2_RESET_QA_HANDOFF") else {
            throw XCTSkip("Essai de bascule local non demandé")
        }
        let previousUserId = LocalAccountScope.currentUserId
        let originService = "fr.signalquest.ios.tests.e2ee.reset-origin." + UUID().uuidString
        let freshService = "fr.signalquest.ios.tests.e2ee.reset-switch." + UUID().uuidString
        defer {
            for service in [originService, freshService] {
                try? KeychainStore(service: service).removeAll()
                try? KeychainStore(service: service + ".auth").removeAll()
            }
            LocalAccountScope.deactivate()
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) }
        }

        // 1. Un appareil d'origine ; il établit l'identité du compte si elle n'existe pas encore.
        let first = try await login(email: email, password: password, base: base)
        let origin = try device(vaultService: originService, userId: first.userId, token: first.token, base: base)
        guard case .registered = await E2EEV2DeviceEnrollmentCoordinator(api: origin.api, identityStore: origin.identity)
            .registerPendingDevice(label: "QA bascule origine") else {
            return XCTFail("Enrôlement de l'appareil d'origine")
        }
        guard case .success(var inventory) = await origin.lifecycle.listDeviceInventory() else {
            return XCTFail("Inventaire")
        }
        let established = inventory.identity != nil
        if !established {
            guard case .success = await origin.lifecycle.bootstrapInitialDevice(.password(password)) else {
                return XCTFail("Bootstrap de l'appareil d'origine")
            }
            guard case .success(let refreshed) = await origin.lifecycle.listDeviceInventory() else { return XCTFail("Inventaire") }
            inventory = refreshed
        }
        let generation = try XCTUnwrap(inventory.identity?.generation)

        // 2. Un appareil neuf demande la réinitialisation.
        let second = try await login(email: email, password: password, base: base)
        let fresh = try device(vaultService: freshService, userId: second.userId, token: second.token, base: base)
        guard case .success(let candidate) = fresh.lifecycle.prepareIdentityReset(label: "QA bascule") else {
            return XCTFail("Appareil de remplacement")
        }
        let requested: E2EEV2IdentityResetStatus
        switch await fresh.lifecycle.resetIdentity(expectedGeneration: generation, reauthentication: .password(password)) {
        case .success(let status): requested = status
        case .failed(let failure): return XCTFail("Demande : \(failure.code ?? "") \(failure.message)")
        }
        XCTAssertEqual(requested.state, .pending)

        // 3. Le script de lancement avance l'échéance et bascule, puis remet en base
        // l'échéance signée ; l'appareil, son horloge avancée de 72 heures, suit.
        try Data((requested.resetId ?? "").utf8).write(to: URL(fileURLWithPath: handoff), options: .atomic)
        let late = fresh.lifecycle(aheadMs: E2EEV2IdentityReset.delayMs)
        var switched: E2EEV2IdentityResetStatus?
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            guard case .success(let status)? = await late.refreshIdentityReset() else { continue }
            if status.state != .pending { switched = status; break }
        }
        let status = try XCTUnwrap(switched, "Bascule lue par l'appareil demandeur")
        XCTAssertEqual(status.state, .completed, "Abandon : \(status.abortReason ?? "")")
        let namespace = LocalAccountScope.storageNamespace
        XCTAssertEqual(try fresh.identity.load(ownerNamespace: namespace)?.deviceId, candidate.deviceId, "Appareil de remplacement actif")
        XCTAssertNil(try fresh.identity.loadResetCandidate(ownerNamespace: namespace))
        XCTAssertNil(try fresh.accounts.loadPendingReset(ownerNamespace: namespace))
        let newUik = try XCTUnwrap(try fresh.accounts.load(ownerNamespace: namespace))
        XCTAssertTrue(try fresh.accounts.isVerified(ownerNamespace: namespace))
        XCTAssertEqual(newUik.publicKey.x963Representation.base64EncodedString(),
                       try E2EEV2IdentityReset.verify(try XCTUnwrap(status.reset)).newUikB64)
        XCTAssertNil(try fresh.pins.pin(userId: second.userId, ownerNamespace: namespace), "Ancien pin retiré")
        let trust = try await E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: fresh.pins, ownUserId: second.userId, ownAccountKey: { newUik.publicKey },
            fetch: E2EEV2TrustDirectory.identityFetch(
                transport: E2EEV2APITransport(api: fresh.api, identityStore: fresh.identity),
                ownerScopeId: "user:\(second.userId)"
            )
        ).ownAccountTrust()
        XCTAssertEqual(trust.outcome.devices.map(\.deviceId), [candidate.deviceId], "Seul certifié, sous la nouvelle clé")
        XCTAssertEqual(trust.outcome.pin.listVersion, 1)
        XCTAssertNil(trust.pendingIdentityReset)
    }
}
