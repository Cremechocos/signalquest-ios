import XCTest
@testable import SignalQuest

/// Essai de bout en bout de la messagerie v2 contre une pile serveur locale
/// (plan 3, IOS-A3) : trois comptes de test, chacun son appareil, sa clé de
/// compte et ses capacités ; un groupe v2 créé par le premier, des messages
/// lus par les autres, un départ, puis un message sous une nouvelle époque que
/// le membre parti ne lit plus. Rien n'est simulé : transport, signatures,
/// CryptoKit et trousseau sont réels.
///
/// Opt-in : `TEST_RUNNER_SQ_E2EE_V2_MSG_QA_BASE_URL` (boucle locale),
/// `…_EMAILS` (trois comptes sans identité, séparés par des virgules) et
/// `…_PASSWORD`. Sans elles, l'essai est ignoré.
final class E2EEV2LocalMessagingQATests: XCTestCase {
    private struct Account {
        let email: String
        let userId: String
        let token: String
        let run: String
        var vault: KeychainStore { KeychainStore(service: "fr.signalquest.ios.tests.e2ee.msg.\(run).\(userId)") }
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
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200, "Connexion de \(email)")
        let cookie = try XCTUnwrap(http.value(forHTTPHeaderField: "Set-Cookie"))
        let token = try XCTUnwrap(cookie.components(separatedBy: ";").first?.components(separatedBy: "=").dropFirst().joined(separator: "="))
        let user = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["user"] as? [String: Any])
        return Account(email: email, userId: try XCTUnwrap(user["id"] as? String), token: token, run: run)
    }

    /// Les briques d'un compte, ce compte rendu courant.
    private struct Session {
        let lifecycle: E2EEV2DeviceLifecycleCoordinator
        let runtime: E2EEV2MessagingRuntime
        let enrollment: E2EEV2DeviceEnrollmentCoordinator
    }

    private func become(_ account: Account, base: URL, root: URL) throws -> Session {
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: account.userId)
        let credentials = CredentialStore(tokenStore: KeychainStore(service: "fr.signalquest.ios.tests.e2ee.msg.\(account.run).\(account.userId).auth"))
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
        return Session(
            lifecycle: E2EEV2DeviceLifecycleCoordinator(
                api: api, identityStore: identity, epochKeyStore: keys, conversationStateStore: states,
                accountIdentityStore: accounts, trustPins: pins,
                capabilities: E2EEV2CapabilitiesPublicationStore(tokenStore: vault), rotationCommitted: { _, _, _ in }
            ),
            runtime: E2EEV2MessagingRuntime(
                api: api, identityStore: identity, keyStore: keys, stateStore: states,
                accountIdentityStore: accounts, pins: pins,
                messageStores: {
                    (E2EEV2MessageStoreV2(rootURL: folder.appendingPathComponent("store"), keyStore: vault),
                     try E2EEV2MessageLedgerStore(baseDirectory: folder.appendingPathComponent("ledger")))
                },
                notificationContext: { nil }, ignoresGates: true
            ),
            enrollment: E2EEV2DeviceEnrollmentCoordinator(api: api, identityStore: identity)
        )
    }

    private func texts(_ result: E2EEV2MessagingRuntime.ThreadResult, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard case .thread(let thread) = result else {
            XCTFail("Relève refusée : \(result)", file: file, line: line)
            return []
        }
        return thread.messages.compactMap(\.content)
    }

    func testAV2GroupCarriesMessagesAndAFreshEpochAfterALeave() async throws {
        guard let rawBase = environment("SQ_E2EE_V2_MSG_QA_BASE_URL"), let base = URL(string: rawBase),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              let emails = environment("SQ_E2EE_V2_MSG_QA_EMAILS")?.split(separator: ",").map(String.init), emails.count == 3,
              let password = environment("SQ_E2EE_V2_MSG_QA_PASSWORD") else {
            throw XCTSkip("Essai de messagerie v2 local non demandé")
        }
        let previousUserId = LocalAccountScope.currentUserId
        // `…_RUN` fixe : les trousseaux sont gardés d'un passage à l'autre et
        // les identités déjà créées resservent ; sinon tout est effacé à la fin.
        let keptRun = environment("SQ_E2EE_V2_MSG_QA_RUN")
        let run = keptRun ?? ("msg" + String(UUID().uuidString.prefix(8)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(run, isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
        var people: [Account] = []
        for email in emails { people.append(try await login(email: email, password: password, base: base, run: run)) }
        defer {
            if keptRun == nil {
                for person in people { try? person.vault.removeAll() }
                try? FileManager.default.removeItem(at: root)
            }
            LocalAccountScope.deactivate()
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) }
        }
        let (alice, bruno, carla) = (people[0], people[1], people[2])

        // 1. Chacun : appareil, clé de compte, capacités (publiées après le bootstrap).
        for person in people {
            let session = try become(person, base: base, root: root)
            guard case .registered = await session.enrollment.registerPendingDevice(label: "QA v2 \(person.email)") else {
                return XCTFail("Enrôlement de \(person.email)")
            }
            // Identité gardée d'un passage précédent : elle resert.
            if keptRun != nil, (try? E2EEV2AccountIdentityStore(tokenStore: person.vault).load(ownerNamespace: LocalAccountScope.storageNamespace)) != nil {
                continue
            }
            guard case .success = await session.lifecycle.bootstrapInitialDevice(.password(password)) else {
                return XCTFail("Bootstrap de \(person.email)")
            }
        }

        // 2. Alice crée le groupe v2 et écrit.
        var session = try become(alice, base: base, root: root)
        let created = await session.runtime.create(
            participantIds: [bruno.userId, carla.userId], isGroup: true, title: "QA v2", excludesWeb: false
        )
        guard case .created(let conversationId, let pending) = created else { return XCTFail("Création v2 : \(created)") }
        XCTAssertEqual(pending, [])
        let participants = [alice, bruno, carla].map { person in
            ConversationParticipant(userId: person.userId, role: nil, joinedAt: nil, lastReadAt: nil,
                                    user: MessageUser(id: person.userId, name: person.email, email: person.email, avatarUrl: nil), presence: nil)
        }
        let first = await session.runtime.send(
            .init(body: .text("Bonjour à tous"), replyToRef: nil, mentions: [], ttlSeconds: 0),
            clientRequestId: UUID().uuidString, conversationId: conversationId, isGroup: true,
            participantIds: [bruno.userId, carla.userId]
        )
        guard case .sent = first else { return XCTFail("Premier envoi : \(first)") }

        // 3. Bruno et Carla lisent ; Bruno répond.
        session = try become(bruno, base: base, root: root)
        let view1 = await session.runtime.thread(conversationId: conversationId, isGroup: true, participants: participants)
        XCTAssertEqual(texts(view1),
                       ["Bonjour à tous"])
        guard case .sent = await session.runtime.send(
            .init(body: .text("Salut Alice"), replyToRef: nil, mentions: [], ttlSeconds: 0),
            clientRequestId: UUID().uuidString, conversationId: conversationId, isGroup: true,
            participantIds: participants.map(\.userId)
        ) else { return XCTFail("Réponse de Bruno") }
        session = try become(carla, base: base, root: root)
        let view2 = await session.runtime.thread(conversationId: conversationId, isGroup: true, participants: participants)
        XCTAssertEqual(texts(view2),
                       ["Bonjour à tous", "Salut Alice"])

        // 4. Carla part ; le message suivant d'Alice passe sous une nouvelle époque.
        let left = await session.runtime.change(.leave, conversationId: conversationId, isGroup: true, participantIds: participants.map(\.userId))
        guard case .applied = left else { return XCTFail("Départ de Carla : \(left)") }
        session = try become(alice, base: base, root: root)
        _ = await session.runtime.thread(conversationId: conversationId, isGroup: true, participants: participants)
        guard case .sent = await session.runtime.send(
            .init(body: .text("Carla est partie"), replyToRef: nil, mentions: [], ttlSeconds: 0),
            clientRequestId: UUID().uuidString, conversationId: conversationId, isGroup: true,
            participantIds: [bruno.userId]
        ) else { return XCTFail("Envoi après le départ") }

        // 5. Bruno lit le nouveau message ; Carla ne lit plus rien de neuf.
        session = try become(bruno, base: base, root: root)
        let view3 = await session.runtime.thread(conversationId: conversationId, isGroup: true, participants: participants)
        XCTAssertEqual(texts(view3),
                       ["Bonjour à tous", "Salut Alice", "Carla est partie"])
        let parts = try XCTUnwrap(session.runtime.current())
        XCTAssertEqual(try parts.stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: parts.session.ownerNamespace)?
            .epochNumber, 2, "Le départ a fait tourner l'époque")
        // Un membre parti n'a plus accès : le serveur ne lui sert plus la conversation.
        session = try become(carla, base: base, root: root)
        switch await session.runtime.thread(conversationId: conversationId, isGroup: true, participants: participants) {
        case .failure(let failure):
            XCTAssertEqual(failure.code, "E2EE_CONVERSATION_NOT_FOUND")
        case .thread(let thread):
            XCTAssertFalse(thread.messages.compactMap(\.content).contains("Carla est partie"), "Un membre parti ne lit plus rien de neuf")
        }
    }
}
