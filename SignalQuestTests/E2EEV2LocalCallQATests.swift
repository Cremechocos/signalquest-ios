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
        // Deux comptes dans un même processus : chaque coffre signe pour son
        // compte même quand l'autre est le compte courant (preuves de jonction).
        let identity = E2EEV2DeviceIdentityStore(tokenStore: vault, allowsOwner: { _ in true }, identityChanged: { _ in })
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
        let callerMedia = try await session.calls.liveKitSession(for: descriptor, liveKitURL: callerURL)

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
        let calleeMedia = try await session.calls.liveKitSession(for: descriptor, liveKitURL: calleeURL)
        XCTAssertNotNil(answered.liveKitToken)

        // 3 bis. Média réel : les deux appareils rejoignent le LiveKit local avec
        // leurs jetons, se prouvent l'un à l'autre, puis échangent une donnée chiffrée.
        try await Self.exchange(caller: (initiated, callerMedia), callee: (answered, calleeMedia))

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

    /// Appel croisé iOS ↔ Android (plan 3, X-1) : iOS crée un groupe v2 avec
    /// le compte appelé, initie un appel chiffré et écrit la passation
    /// (`…_HANDOFF`) ; l'appareil Android de l'appelé le vérifie, répond et
    /// rejoint. Chacun prouve sa jonction, puis échange un paquet chiffré sur
    /// `sq.qa.cross` ; iOS n'accepte que celui de l'identité prouvée de l'appelé.
    func testACrossPlatformEncryptedCallIsAnsweredAndProvenByAnotherPlatform() async throws {
        guard let rawBase = environment("SQ_E2EE_V2_CROSS_CALL_BASE_URL"), let base = URL(string: rawBase),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              let callerEmail = environment("SQ_E2EE_V2_CROSS_CALL_CALLER_EMAIL"),
              let calleeEmail = environment("SQ_E2EE_V2_CROSS_CALL_CALLEE_EMAIL"),
              let password = environment("SQ_E2EE_V2_CROSS_CALL_PASSWORD"),
              let run = environment("SQ_E2EE_V2_CROSS_CALL_RUN"),
              let handoff = environment("SQ_E2EE_V2_CROSS_CALL_HANDOFF") else {
            throw XCTSkip("Appel croisé local non demandé")
        }
        let wait = TimeInterval(environment("SQ_E2EE_V2_CROSS_CALL_WAIT_SECONDS").flatMap(Int.init) ?? 300)
        let previousUserId = LocalAccountScope.currentUserId
        E2EEV2CapabilitiesPublicationStore.announcesCallsForLocalQA = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(run, isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
        defer {
            E2EEV2CapabilitiesPublicationStore.announcesCallsForLocalQA = false
            LocalAccountScope.deactivate()
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) }
        }
        let caller = try await login(email: callerEmail, password: password, base: base, run: run)
        // Seulement pour l'identifiant de l'appelé : aucun appareil n'est créé pour lui ici.
        let calleeUserId = try await login(email: calleeEmail, password: password, base: base, run: run).userId

        let session = try become(caller, base: base, root: root)
        guard case .success = await session.lifecycle.publishCapabilitiesIfNeeded() else {
            return XCTFail("Capacités de l'appelant")
        }
        let created = await session.messaging.create(participantIds: [calleeUserId], isGroup: true, title: "QA appel croisé", excludesWeb: false)
        guard case .created(let conversationId, _) = created else { return XCTFail("Création v2 : \(created)") }
        XCTAssertTrue(session.calls.canStart(conversationId: conversationId),
                      "Tous les appareils certifiés de l'appelé doivent annoncer « appels »")
        guard case .prepared(let descriptor) = session.calls.prepareOutgoing(conversationId: conversationId) else {
            return XCTFail("Descripteur de l'appelant")
        }
        let initiated = try await session.service.initiate(conversationId: conversationId, mode: "audio", e2ee: descriptor)
        let media = try await session.calls.liveKitSession(for: descriptor, liveKitURL: try XCTUnwrap(initiated.liveKitUrl))
        defer { Task { try? await session.service.end(callId: initiated.id) } }

        let handoffURL = URL(fileURLWithPath: handoff)
        try FileManager.default.createDirectory(at: handoffURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "conversationId": conversationId, "callId": initiated.id, "callerUserId": caller.userId,
            "callerDeviceId": descriptor.descriptor.callerDeviceId, "livekitIdentity": initiated.livekitIdentity ?? "",
            "calleeUserId": calleeUserId, "createdAtMs": descriptor.descriptor.createdAtMs,
        ], options: [.sortedKeys]).write(to: handoffURL, options: .atomic)

        if environment("SQ_E2EE_V2_CROSS_CALL_MEDIA") == "0" {
            // Étape sans média : le banc de l'autre plateforme vérifie le descripteur,
            // répond signé, puis écrit son reçu à côté de la passation.
            let answer = handoffURL.deletingLastPathComponent().appendingPathComponent("answer.json")
            let deadline = Date().addingTimeInterval(wait)
            var receipt: [String: Any]?
            while receipt == nil, Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                receipt = (try? Data(contentsOf: answer)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if receipt?["callId"] as? String != initiated.id { receipt = nil }
            }
            let received = try XCTUnwrap(receipt, "Reçu de l'appelé")
            XCTAssertEqual(received["descriptorVerified"] as? Bool, true, "Descripteur vérifié par l'appelé")
            XCTAssertEqual(received["answered"] as? Bool, true, "Réponse signée acceptée par le serveur : \(received)")
        } else {
            try await Self.crossExchange(call: initiated, media: media, calleeUserId: calleeUserId, wait: wait)
        }
        try await session.service.end(callId: initiated.id)
    }

    /// Sens inverse (plan 3, X-1) : l'autre plateforme appelle. Elle écrit sa
    /// passation (`…_INBOUND`, avec `callId` et `conversationId`) ; iOS voit
    /// l'appel dans `pending`, synchronise la conversation v2, vérifie le
    /// descripteur à la sonnerie, répond signé et rejoint avec sa preuve.
    func testAnEncryptedCallFromAnotherPlatformIsVerifiedAnsweredAndJoined() async throws {
        guard let rawBase = environment("SQ_E2EE_V2_CROSS_CALL_BASE_URL"), let base = URL(string: rawBase),
              ["127.0.0.1", "localhost", "::1"].contains(base.host ?? ""),
              let calleeEmail = environment("SQ_E2EE_V2_CROSS_CALL_CALLEE_EMAIL"),
              let callerEmail = environment("SQ_E2EE_V2_CROSS_CALL_CALLER_EMAIL"),
              let password = environment("SQ_E2EE_V2_CROSS_CALL_PASSWORD"),
              let run = environment("SQ_E2EE_V2_CROSS_CALL_RUN"),
              let inbound = environment("SQ_E2EE_V2_CROSS_CALL_INBOUND") else {
            throw XCTSkip("Appel croisé entrant local non demandé")
        }
        let wait = TimeInterval(environment("SQ_E2EE_V2_CROSS_CALL_WAIT_SECONDS").flatMap(Int.init) ?? 300)
        let previousUserId = LocalAccountScope.currentUserId
        E2EEV2CapabilitiesPublicationStore.announcesCallsForLocalQA = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(run, isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
        defer {
            E2EEV2CapabilitiesPublicationStore.announcesCallsForLocalQA = false
            LocalAccountScope.deactivate()
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) }
        }
        let callee = try await login(email: calleeEmail, password: password, base: base, run: run)
        let callerUserId = try await login(email: callerEmail, password: password, base: base, run: run).userId
        let session = try become(callee, base: base, root: root)
        guard case .success = await session.lifecycle.publishCapabilitiesIfNeeded() else {
            return XCTFail("Capacités de l'appelé")
        }
        // Prêt : l'autre plateforme peut appeler.
        let inboundURL = URL(fileURLWithPath: inbound)
        let ready = inboundURL.deletingLastPathComponent().appendingPathComponent("ios-ready.json")
        try FileManager.default.createDirectory(at: ready.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["calleeUserId": callee.userId, "readyAtMs": Int64(Date().timeIntervalSince1970 * 1_000)])
            .write(to: ready, options: .atomic)

        // L'appel annoncé, puis sa sonnerie dans `pending`.
        let deadline = Date().addingTimeInterval(wait)
        var handoff: [String: Any]?
        while handoff == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            handoff = (try? Data(contentsOf: inboundURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let at = handoff?["createdAtMs"] as? Int64 ?? (handoff?["createdAtMs"] as? NSNumber)?.int64Value,
               Double(at) / 1_000 < Date().timeIntervalSince1970 - 120 { handoff = nil }
        }
        let announced = try XCTUnwrap(handoff, "Passation de l'appelant")
        let callId = try XCTUnwrap(announced["callId"] as? String)
        let conversationId = try XCTUnwrap(announced["conversationId"] as? String)
        _ = await session.messaging.callMembers(conversationId: conversationId, synchronizing: true)
        var ringing: CallSession?
        for _ in 0..<20 where ringing == nil {
            ringing = try await session.service.pending().first { $0.id == callId }
            if ringing == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        let call = try XCTUnwrap(ringing, "L'appel chiffré sonne chez iOS")
        let descriptor = try XCTUnwrap(call.e2eeV2, "Appel v2")
        let verification = await session.calls.verify(descriptor, conversationId: conversationId, callId: callId, ringing: true)
        XCTAssertEqual(verification, .verified(descriptor.descriptor), "Descripteur de \(callerUserId) vérifié")
        guard case .verified = verification else { return }
        let answered = try await session.service.answer(callId: callId, e2ee: true)
        let media = try await session.calls.liveKitSession(for: descriptor, liveKitURL: try XCTUnwrap(answered.liveKitUrl))
        defer { Task { try? await session.service.end(callId: callId) } }
        try await Self.crossExchange(call: answered, media: media, calleeUserId: callerUserId, wait: 60)
        try await session.service.end(callId: callId)
    }

    @MainActor
    private static func crossExchange(call: CallSession, media: E2EEV2LiveKitSession, calleeUserId: String, wait: TimeInterval) async throws {
        var received: [(sender: String?, text: String)] = []
        var losses: [E2EEV2CallTrustLoss] = []
        let client = LiveKitClient()
        client.onDataReceived = { sender, data, topic in
            if topic == "sq.qa.cross" { received.append((sender, String(decoding: data, as: UTF8.self))) }
        }
        client.onE2EETrustLost = { losses.append($0) }
        let start = Date()
        LiveKitClient.qaDataTrace = { print(String(format: "[QA appel croisé] +%.2f s ", Date().timeIntervalSince(start)) + $0) }
        defer {
            LiveKitClient.qaDataTrace = nil
            Task { @MainActor in await client.disconnect() }
        }
        await client.connect(
            url: try XCTUnwrap(call.liveKitUrl), token: try XCTUnwrap(call.liveKitToken),
            room: try XCTUnwrap(call.liveKitRoom), video: false, managesAudioSession: false,
            e2eeSession: media, mediaSetupMode: .localQADataOnly
        )
        XCTAssertEqual(client.state, .connected)
        // Le paquet de l'appelé n'arrive qu'une fois sa jonction prouvée. Un état
        // toutes les 5 s, pour situer un blocage avec l'autre plateforme.
        let deadline = Date().addingTimeInterval(wait)
        var lastReport = Date.distantPast
        // Réussite : un paquet de l'identité prouvée de l'appelé, ou son appareil
        // prouvé et sa piste audio chiffrée reçue (un SDK qui ne remplit pas
        // l'émetteur d'un paquet chiffré rend ses autres paquets inattribuables).
        func done() -> Bool { !received.isEmpty || (client.isE2EEVerified && !client.remoteAudios.isEmpty) }
        while !done(), Date() < deadline {
            if Date().timeIntervalSince(lastReport) >= 5 {
                lastReport = Date()
                print("[QA appel croisé] état=\(client.state) arrivé=\(client.remoteJoinedAt.map { "\($0)" } ?? "non")"
                      + " vérifié=\(client.isE2EEVerified) échecsDéchiffrement=\(client.e2eeDataDecryptionFailureCount)"
                      + " pistesAudio=\(client.remoteAudios.count) pertes=\(losses)")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard done() else { return XCTFail("Délai dépassé : ni paquet ni piste prouvée de l'appelé") }
        if let sender = received.first?.sender {
            XCTAssertTrue(sender.hasPrefix(calleeUserId + "."), "Identité LiveKit prouvée de l'appelé : \(sender)")
        }
        XCTAssertTrue(client.isE2EEVerified)
        // Laisse passer quelques secondes de média pour compter les échecs.
        try await Task.sleep(for: .seconds(5))
        print("[QA appel croisé] fin : paquets=\(received.count) pistesAudio=\(client.remoteAudios.count) échecsDéchiffrement=\(client.e2eeDataDecryptionFailureCount)")
        XCTAssertEqual(client.e2eeDataDecryptionFailureCount, 0)
        // Plusieurs envois, le temps que l'appelé confirme de son côté.
        for _ in 0..<5 {
            try await client.publishData(Data("bonjour depuis iOS".utf8), topic: "sq.qa.cross")
            try await Task.sleep(for: .seconds(2))
        }
        XCTAssertEqual(losses, [])
    }

    @MainActor
    private static func exchange(
        caller: (call: CallSession, media: E2EEV2LiveKitSession),
        callee: (call: CallSession, media: E2EEV2LiveKitSession)
    ) async throws {
        var received: [(sender: String?, topic: String)] = []
        var losses: [E2EEV2CallTrustLoss] = []
        let callerClient = LiveKitClient(), calleeClient = LiveKitClient()
        calleeClient.onDataReceived = { sender, _, topic in received.append((sender, topic)) }
        callerClient.onE2EETrustLost = { losses.append($0) }
        calleeClient.onE2EETrustLost = { losses.append($0) }
        defer {
            Task { @MainActor in
                await callerClient.disconnect()
                await calleeClient.disconnect()
            }
        }
        for (client, side) in [(callerClient, caller), (calleeClient, callee)] {
            await client.connect(
                url: try XCTUnwrap(side.call.liveKitUrl), token: try XCTUnwrap(side.call.liveKitToken),
                room: try XCTUnwrap(side.call.liveKitRoom), video: false, managesAudioSession: false,
                e2eeSession: side.media, mediaSetupMode: .localQADataOnly
            )
            XCTAssertEqual(client.state, .connected)
        }
        try await waitUntil("preuves de jonction échangées") { callerClient.isE2EEVerified && calleeClient.isE2EEVerified }
        try await callerClient.publishData(Data("bonjour chiffré".utf8), topic: "sq.qa.call")
        try await waitUntil("donnée reçue de l'appelant prouvé") { received.contains { $0.topic == "sq.qa.call" } }
        XCTAssertEqual(received.first { $0.topic == "sq.qa.call" }?.sender, caller.call.livekitIdentity,
                       "Identité LiveKit <userId>.<deviceId>")
        XCTAssertFalse(received.contains { $0.topic == E2EEV2CallJoinProof.topic }, "Une preuve n'atteint jamais l'app")
        XCTAssertEqual(losses, [])
    }

    @MainActor
    private static func waitUntil(_ label: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Délai dépassé : \(label)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
