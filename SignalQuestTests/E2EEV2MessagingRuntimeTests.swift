import XCTest
@testable import SignalQuest

/// Coordinateur de la messagerie v2 (branchement, plan 3 IOS-A3) : verrous,
/// comptes demandés à l'annuaire, relecture unique sur `E2EE_DEVICE_LIST_STALE`.
final class E2EEV2MessagingRuntimeTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD2345"

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func add(_ user: String) { lock.lock(); counts[user, default: 0] += 1; lock.unlock() }
        func count(_ user: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[user] ?? 0 }
    }

    private func runtime(_ fixture: E2EEV2AccountFixture, reads: Reads, ignoresGates: Bool) throws -> E2EEV2MessagingRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        let namespace = fixture.session.ownerNamespace
        return E2EEV2MessagingRuntime(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            messageStores: {
                (E2EEV2MessageStoreV2(rootURL: root.appendingPathComponent("store"), keyStore: InMemoryTokenStore()),
                 try E2EEV2MessageLedgerStore(baseDirectory: root.appendingPathComponent("ledger")))
            },
            notificationContext: { nil },
            directory: { session in
                E2EEV2DeviceDirectoryCache(
                    session: session,
                    directory: E2EEV2TrustDirectory(ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())) { user, _ in
                        reads.add(user)
                        throw E2EEV2TrustDirectory.IdentityNotFound()
                    }
                )
            },
            ignoresGates: ignoresGates
        )
    }

    func testNothingRunsWhileTheGatesAreClosed() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let reads = Reads()
        let closed = try runtime(fixture, reads: reads, ignoresGates: false)
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête verrou fermé : \(request.url?.path ?? "")")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        guard case .failure(let failure) = await closed.refresh(conversationId: "conversation_runtime_00001", isGroup: false, participantIds: [bruno])
        else { return XCTFail("Verrou fermé") }
        XCTAssertEqual(failure.kind, .activationBlocked)
        guard case .failure(let creation) = await closed.create(participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false)
        else { return XCTFail("Verrou fermé") }
        XCTAssertEqual(creation.kind, .activationBlocked)
        guard case .failure(let rotation) = await closed.rotate(conversationId: "conversation_runtime_00001")
        else { return XCTFail("Verrou fermé") }
        XCTAssertEqual(rotation.kind, .activationBlocked)
        XCTAssertEqual(reads.count(bruno), 0)
    }

    /// Les comptes demandés couvrent les membres et les auteurs de la chaîne ;
    /// une liste périmée relit les comptes nommés, puis recommence une fois.
    func testAStaleDeviceListRereadsTheNamedAccountsOnce() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let reads = Reads()
        let open = try runtime(fixture, reads: reads, ignoresGates: true)
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        let parts = try XCTUnwrap(open.current())
        XCTAssertEqual(Set(open.accounts(conversationId: seeded.conversationId, participantIds: [], parts: parts)), [fixture.user, bruno],
                       "Les auteurs de la chaîne gardée sont relus")

        var calls = 0
        let result = try await open.withDevices(
            conversationId: seeded.conversationId, participantIds: [bruno], parts: parts,
            staleUserIds: { (stale: Bool) in stale ? [self.bruno] : nil }
        ) { devices -> Bool in
            calls += 1
            XCTAssertEqual(devices.refusals[self.bruno], .notFound)
            return true
        }
        XCTAssertTrue(result, "Le second résultat est rendu, même encore périmé : jamais de boucle")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(reads.count(bruno), 2, "Relu une fois")
        XCTAssertEqual(reads.count(fixture.user), 1, "Les autres restent en cache")
    }
}

extension E2EEV2MessagingRuntimeTests {
    /// La recette locale ne s'ouvre qu'avec l'argument, hors production et vers
    /// une API en boucle locale ; en Release elle n'existe pas.
    func testTheLocalQAGateNeedsTheArgumentAndALoopbackAPI() {
        let local = AppConfig(environment: .test, appBaseURL: URL(string: "http://127.0.0.1:3201")!,
                              apiBaseURL: URL(string: "http://127.0.0.1:3201")!, debugLogsEnabled: false)
        let remote = AppConfig(environment: .test, appBaseURL: URL(string: "https://api.signalquest.fr")!,
                               apiBaseURL: URL(string: "https://api.signalquest.fr")!, debugLogsEnabled: false)
        XCTAssertTrue(E2EEV2MessagingQAGate.allows(config: local, qaArgumentEnabled: true))
        XCTAssertFalse(E2EEV2MessagingQAGate.allows(config: local, qaArgumentEnabled: false))
        XCTAssertFalse(E2EEV2MessagingQAGate.allows(config: remote, qaArgumentEnabled: true))
        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled, "Les verrous globaux restent fermés")
    }
}

extension E2EEV2MessagingRuntimeTests {
    /// File des rotations (§3.3) : une conversation qui n'est pas v2 ici ne
    /// demande rien ; le genre d'une conversation v2 se lit dans sa chaîne
    /// signée, sans dépendre de ce que le serveur en dit.
    func testARotationRequestReadsTheKindFromTheSignedChainAndSkipsOtherConversations() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let open = try runtime(fixture, reads: Reads(), ignoresGates: true)
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête pour une conversation qui n'est pas v2 : \(request.url?.path ?? "")")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let skipped = await open.rotate(conversationId: "conversation_v1_only_000001")
        XCTAssertEqual(skipped, .noAction)

        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let direct = try fixture.seedConversation(with: bruno, devices: devices)
        let group = try fixture.seedGroup(with: [bruno], devices: devices)
        let parts = try XCTUnwrap(open.current())
        XCTAssertEqual(parts.messaging.storedMembership(conversationId: direct.conversationId),
                       .v2(isGroup: false, members: [fixture.user, bruno].sorted(), excludesWeb: false))
        XCTAssertEqual(parts.messaging.storedMembership(conversationId: group.conversationId),
                       .v2(isGroup: true, members: [fixture.user, bruno].sorted(), excludesWeb: false))
        XCTAssertEqual(parts.messaging.storedMembership(conversationId: "conversation_v1_only_000001"), .notV2)
    }
}
