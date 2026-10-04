import XCTest
@testable import SignalQuest

/// Essai de bout en bout d'un appel chiffré v2 contre une pile serveur locale
/// et un `livekit-server` en boucle locale (plan 3, IOS-CALL) : deux comptes
/// déjà dotés d'une identité v2, un groupe v2, puis un appel audio. L'appelant
/// signe son descripteur et initie ; l'appelé voit l'appel dans `pending`, le
/// vérifie, répond ; chacun bâtit sa session LiveKit v2 (clé de trame, preuves
/// de jonction) ; l'appel prend fin. Rien n'est simulé côté réseau.
///
/// Opt-in : `TEST_RUNNER_SQ_E2EE_V2_CALL_QA_BASE_URL` (boucle locale),
/// `…_EMAILS` (deux comptes amis, identités déjà créées et gardées sous
/// `…_RUN`, par exemple par l'essai de messagerie) et `…_PASSWORD`.
final class E2EEV2LocalCallQATests: XCTestCase {
    private struct Account {
        let email: String
        let userId: String
        let token: String
        let run: String
        var vault: KeychainStore { KeychainStore(service: "fr.signalquest.ios.tests.e2ee.msg.\(run).\(userId)") }
    }

    private struct Session {
        let messaging: E2EEV2MessagingRuntime
        let calls: E2EEV2CallRuntime
        let service: CallsService
        let lifecycle: E2EEV2DeviceLifecycleCoordinator
    }

    private func environment(_ name: String) -> String? {
        let values = ProcessInfo.processInfo.environment
        return values[name] ?? values["TEST_RUNNER_\(name)"]
    }

    private func login(email: String, password: String, base: URL, run: String) async throws -> Account {
        var request = URLRequest(url: base.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Connexion de \(email)")
        let cookie = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"))
        let token = try XCTUnwrap(cookie.components(separatedBy: ";").first?.components(separatedBy: "=").dropFirst().joined(separator: "="))
        let user = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["user"] as? [String: Any])
        return Account(email: email, userId: try XCTUnwrap(user["id"] as? String), token: token, run: run)
    }

    private func become(_ account: Account, base: URL, root: URL) throws -> Session {
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: account.userId)
        let credentials = CredentialStore(tokenStore: KeychainStore(service: "fr.signalquest.ios.tests.e2ee.call.\(account.run).\(account.userId).auth"))
        try credentials.setAccessToken(account.token)
        let config = AppConfig(environment: .test, appBaseURL: base, apiBaseURL: base, debugLogsEnabled: false)
        let api = APIClient(config: config, credentials: credentials, session: APIClient.makeSession())
        let vault = account.vault
        let identity = E2EEV2DeviceIdentityStore(tokenStore: vault, identityChanged: { _ in })
        let keys = E2EEV2EpochKeyStore(tokenStore: vault)
        let states = E2EEV2ConversationStateStore(tokenStore: vault)
        let accounts = E2EEV2AccountIdentityStore(tokenStore: vault)
        let pins = E2EEV2TrustPinStore(tokenStore: vault)
        let folder = root.appendingPathComponent(account.userId, isDirectory: true)
        let messaging = E2EEV2MessagingRuntime(
            api: api, identityStore: identity, keyStore: keys, stateStore: states,
            accountIdentityStore: accounts, pins: pins,
            messageStores: {
                (E2EEV2MessageStoreV2(rootURL: folder.appendingPathComponent("store"), keyStore: vault),
                 try E2EEV2MessageLedgerStore(baseDirectory: folder.appendingPathComponent("ledger")))
            },
            notificationContext: { nil }, ignoresGates: true
        )
        let calls = E2EEV2CallRuntime(
            members: { await messaging.callMembers(conversationId: $0, synchronizing: $1) },
            identityStore: identity, keyStore: keys, stateStore: states,
            nonces: E2EEV2CallNonceLedger(fileURL: nil), contextStore: { nil },
            controlPlaneOpen: { true }, mediaOpen: { url in ["127.0.0.1", "localhost"].contains(url.host ?? "") }
        )
        return Session(
            messaging: messaging, calls: calls,
            service: CallsService(api: api, e2eeTransport: E2EEV2APITransport(api: api, identityStore: identity)),
            lifecycle: E2EEV2DeviceLifecycleCoordinator(
                api: api, identityStore: identity, epochKeyStore: keys, conversationStateStore: states,
                accountIdentityStore: accounts, trustPins: pins,
                capabilities: E2EEV2CapabilitiesPublicationStore(tokenStore: vault), rotationCommitted: { _, _, _ in }
            )
        )
    }

    func testAnEncryptedCallIsSignedRungVerifiedAnsweredAndJoined() async throws {
        guard let rawBase = environment("SQ_E2EE_V2_CALL_QA_BASE_URL"), let base = URL(string: rawBase),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              let emails = environment("SQ_E2EE_V2_CALL_QA_EMAILS")?.split(separator: ",").map(String.init), emails.count == 2,
              let password = environment("SQ_E2EE_V2_CALL_QA_PASSWORD"),
              let run = environment("SQ_E2EE_V2_CALL_QA_RUN") else {
            throw XCTSkip("Essai d'appel v2 local non demandé")
        }
        let previousUserId = LocalAccountScope.currentUserId
        E2EEV2CapabilitiesPublicationStore.announcesCallsForLocalQA = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(run, isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
        defer {
            E2EEV2CapabilitiesPublicationStore.announcesCallsForLocalQA = false
            LocalAccountScope.deactivate()
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) }
        }
        let caller = try await login(email: emails[0], password: password, base: base, run: run)
        let callee = try await login(email: emails[1], password: password, base: base, run: run)

        // 1. Chacun annonce « appels » ; sa requête signée lie aussi la session.
        for person in [callee, caller] {
            let session = try become(person, base: base, root: root)
            guard case .success = await session.lifecycle.publishCapabilitiesIfNeeded() else {
                return XCTFail("Capacités de \(person.email)")
            }
        }

        // 2. L'appelant crée un groupe v2 et signe son descripteur.
        var session = try become(caller, base: base, root: root)
        let created = await session.messaging.create(participantIds: [callee.userId], isGroup: true, title: "QA appel", excludesWeb: false)
        guard case .created(let conversationId, _) = created else { return XCTFail("Création v2 : \(created)") }
        XCTAssertTrue(session.calls.canStart(conversationId: conversationId))
        guard case .prepared(let descriptor) = session.calls.prepareOutgoing(conversationId: conversationId) else {
            return XCTFail("Descripteur de l'appelant")
        }
        let initiated = try await session.service.initiate(conversationId: conversationId, mode: "audio", e2ee: descriptor)
        XCTAssertEqual(initiated.id, descriptor.descriptor.callId, "L'appel porte l'identifiant tiré par l'appelant")
        XCTAssertEqual(initiated.e2eeV2, descriptor)
        let callId = initiated.id
        let callerURL = try XCTUnwrap(initiated.liveKitUrl)
        _ = try await session.calls.liveKitSession(for: descriptor, liveKitURL: callerURL)

        // 3. L'appelé lie sa session, voit l'appel sans nom servi, le vérifie et répond.
        session = try become(callee, base: base, root: root)
        _ = await session.messaging.callMembers(conversationId: conversationId, synchronizing: true)
        let pending = try await session.service.pending()
        let ringing = try XCTUnwrap(pending.first { $0.id == callId }, "L'appel chiffré sonne chez l'appelé")
        XCTAssertEqual(ringing.e2eeV2, descriptor, "Le descripteur relayé tel quel")
        let verification = await session.calls.verify(descriptor, conversationId: conversationId, callId: callId, ringing: true)
        XCTAssertEqual(verification, .verified(descriptor.descriptor))
        let answered = try await session.service.answer(callId: callId, e2ee: true)
        XCTAssertEqual(answered.e2eeV2, descriptor)
        let calleeURL = try XCTUnwrap(answered.liveKitUrl)
        _ = try await session.calls.liveKitSession(for: descriptor, liveKitURL: calleeURL)
        XCTAssertNotNil(answered.liveKitToken)

        // 4. Une seconde réponse ne gagne pas.
        do {
            _ = try await session.service.answer(callId: callId, e2ee: true)
            XCTFail("Une seconde réponse doit être refusée")
        } catch {
            XCTAssertEqual(error as? CallsServiceError, .refused(code: "CALL_PARTICIPANT_ALREADY_ANSWERED"))
        }

        // 5. Fin de l'appel des deux côtés.
        try await session.service.end(callId: callId)
        session = try become(caller, base: base, root: root)
        try await session.service.end(callId: callId)
    }
}
