import CryptoKit
import XCTest
@testable import SignalQuest

/// Changements d'appartenance après la genèse (D.4, E.2) : composés sur la
/// chaîne gardée, vérifiés localement, envoyés en comparaison-échange.
final class E2EEV2MembershipWriterV2Tests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"

    func testExcludingBrowsersInATwoPersonConversation() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        let namespace = fixture.session.ownerNamespace
        let bodies = MembershipBodies()
        MockURLProtocol.requestHandler = { request in
            bodies.append(request.url?.path ?? "", E2EEV2AccountFixture.rawBody(request))
            let change = try XCTUnwrap(E2EEV2MembershipChange.signed(from: try E2EEV2CanonicalJSON.parseStrict(E2EEV2AccountFixture.rawBody(request))))
            let number = try XCTUnwrap(change.canonical.components(separatedBy: "\n")[safe: 3])
            return E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(.object(["changeNumber": .string(number)])))
        }
        let writer = E2EEV2MembershipWriterV2(api: fixture.api, identityStore: fixture.identity, stateStore: fixture.states, expectedSession: fixture.session)
        let result = await writer.submit(.excludeBrowsers(true), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: fixture.session.ownerScopeId)
        let next = seeded.membership.changeNumber + 1
        XCTAssertEqual(result, .applied(changeNumber: next))
        XCTAssertEqual(bodies.all.first?.0, "/api/e2ee/v2/conversations/\(seeded.conversationId)/membership")

        // La chaîne gardée se relit, signature comprise, avec le nouveau réglage.
        let chain = try fixture.states.membershipChain(conversationId: seeded.conversationId, ownerNamespace: namespace)
        XCTAssertEqual(chain.count, next)
        let ownKey = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded: fixture.descriptor.publicSigningKeyB64)))
        let state = try E2EEV2MembershipChain.apply(
            chain, conversationId: seeded.conversationId, isGroup: false, genesisLength: seeded.membership.changeNumber
        ) { userId, deviceId in userId == fixture.user && deviceId == fixture.descriptor.deviceId ? ownKey : nil }
        XCTAssertTrue(state.excludesWeb)
        XCTAssertNil(try fixture.states.pendingMembership(conversationId: seeded.conversationId, ownerNamespace: namespace))

        // Le réglage a changé : l'époque courante doit tourner avant tout envoi.
        XCTAssertEqual(
            E2EEV2RotationPolicy.reasons(
                current: seeded.current, membership: state, devices: fixture.deviceSet(adding: [phone.device]),
                nowMs: seeded.current.acceptedAtMs + 1_000
            ),
            [.browsers]
        )
    }

    func testRulesAreCheckedLocallyBeforeAnyRequest() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête pour un changement refusé")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let writer = E2EEV2MembershipWriterV2(api: fixture.api, identityStore: fixture.identity, stateStore: fixture.states, expectedSession: fixture.session)
        let owner = fixture.session.ownerScopeId
        let add = await writer.submit(.add(userId: "user_carol_01J7ABCD23456789"), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        XCTAssertEqual(add, .notAllowed, "Pas d'ajout dans un tête-à-tête")
        let remove = await writer.submit(.remove(userId: bruno), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        XCTAssertEqual(remove, .notAllowed)
        XCTAssertNil(try fixture.states.pendingMembership(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace))
    }

    func testARetryResendsTheSameChangeAndAStaleNumberAsksForASync() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        let bodies = MembershipBodies()
        MockURLProtocol.requestHandler = { request in
            switch bodies.append(request.url?.path ?? "", E2EEV2AccountFixture.rawBody(request)) {
            case 1: throw URLError(.networkConnectionLost)
            case 2: return E2EEV2AccountFixture.response(request, Data(#"{"error":"stale","code":"E2EE_MEMBERSHIP_STALE"}"#.utf8), status: 409)
            default:
                let number = String(seeded.membership.changeNumber + 1)
                return E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(.object(["changeNumber": .string(number)])))
            }
        }
        let writer = E2EEV2MembershipWriterV2(api: fixture.api, identityStore: fixture.identity, stateStore: fixture.states, expectedSession: fixture.session)
        let owner = fixture.session.ownerScopeId
        guard case .failure = await writer.submit(.excludeBrowsers(true), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        else { return XCTFail("Coupure réseau") }
        let stale = await writer.submit(.excludeBrowsers(false), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        XCTAssertEqual(stale, .needsSync)
        let retried = await writer.submit(.excludeBrowsers(false), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        XCTAssertEqual(retried, .applied(changeNumber: seeded.membership.changeNumber + 1))
        let sent = bodies.all.map(\.1)
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(Set(sent).count, 1, "Le changement gardé passe avant tout autre, à l'octet : jamais deux signatures pour un numéro")
        XCTAssertTrue(String(decoding: sent[0], as: UTF8.self).contains("EXCLUDE_WEB_ON"))
    }

    func testAnAcceptedChangeWhoseReceiptWasLostIsRecognized() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        let namespace = fixture.session.ownerNamespace
        let bodies = MembershipBodies()
        MockURLProtocol.requestHandler = { request in
            _ = bodies.append(request.url?.path ?? "", E2EEV2AccountFixture.rawBody(request))
            throw URLError(.networkConnectionLost)
        }
        let writer = E2EEV2MembershipWriterV2(api: fixture.api, identityStore: fixture.identity, stateStore: fixture.states, expectedSession: fixture.session)
        let owner = fixture.session.ownerScopeId
        _ = await writer.submit(.excludeBrowsers(true), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        // Le serveur l'avait accepté ; la synchronisation l'a ajouté à la chaîne.
        let pending = try XCTUnwrap(try fixture.states.pendingMembership(conversationId: seeded.conversationId, ownerNamespace: namespace))
        try fixture.states.appendMembership([pending], conversationId: seeded.conversationId, ownerNamespace: namespace)
        MockURLProtocol.requestHandler = { request in
            XCTFail("Déjà dans la chaîne : rien à renvoyer")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let result = await writer.submit(.excludeBrowsers(true), conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        XCTAssertEqual(result, .applied(changeNumber: seeded.membership.changeNumber + 1))
        XCTAssertNil(try fixture.states.pendingMembership(conversationId: seeded.conversationId, ownerNamespace: namespace))
    }
}

extension E2EEV2MembershipWriterV2Tests {
    /// v0.4.16 : un départ rejoué après un reçu perdu reçoit 404 (plus
    /// membre) et est tenu pour fait ; un premier envoi qui reçoit 404 échoue.
    func testAReplayedLeaveAnsweredNotFoundCountsAsDone() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        let namespace = fixture.session.ownerNamespace
        let writer = E2EEV2MembershipWriterV2(api: fixture.api, identityStore: fixture.identity, stateStore: fixture.states, expectedSession: fixture.session)
        let owner = fixture.session.ownerScopeId
        let notFound = Data(#"{"error":"x","code":"E2EE_CONVERSATION_NOT_FOUND"}"#.utf8)

        MockURLProtocol.requestHandler = { request in E2EEV2AccountFixture.response(request, notFound, status: 404) }
        guard case .failure = await writer.submit(.leave, conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        else { return XCTFail("Premier envoi : un 404 reste un échec") }
        XCTAssertEqual(try fixture.states.membershipChain(conversationId: seeded.conversationId, ownerNamespace: namespace).count,
                       seeded.membership.changeNumber, "Rien n'est ajouté à la chaîne")

        // Le même départ, gardé, repart : le serveur l'avait accepté.
        let replayed = await writer.submit(.leave, conversationId: seeded.conversationId, isGroup: false, expectedOwnerScopeId: owner)
        XCTAssertEqual(replayed, .applied(changeNumber: seeded.membership.changeNumber + 1))
        XCTAssertNil(try fixture.states.pendingMembership(conversationId: seeded.conversationId, ownerNamespace: namespace))
        let chain = try fixture.states.membershipChain(conversationId: seeded.conversationId, ownerNamespace: namespace)
        XCTAssertTrue(try XCTUnwrap(chain.last).canonical.contains("\nLEAVE\n"))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private final class MembershipBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, Data)] = []

    @discardableResult
    func append(_ path: String, _ body: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        items.append((path, body))
        return items.count
    }

    var all: [(String, Data)] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
