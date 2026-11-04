import XCTest
@testable import SignalQuest

/// Minutage et replis de « C'est moi » (E2EE-AUTO §5.3), avec une horloge simulée.
@MainActor
final class E2EEAutoHistoryRequestCoordinatorTests: XCTestCase {
    private typealias Coordinator = E2EEAutoHistoryRequestCoordinator
    nonisolated private static let open = E2EEAutoHistoryRequests.OpenRequest(requestId: "hreq_000000000000000001", expiresAtMs: .max)
    nonisolated private static let pending = E2EEAutoHistoryRequests.Pending(
        requestId: "hreq_000000000000000002", deviceId: "android_device_0000000001", platform: .android,
        addedAtMs: 7_000, fingerprint: ["11111", "22222", "33333", "44444"], expiresAtMs: .max
    )

    private final class World: @unchecked Sendable {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var held = false
        var heldAfterChecks: Int?
        var keyChecks = 0
        var hasOpenRequest = false
        var startOutcomes: [E2EEAutoHistoryRequests.RequestOutcome] = []
        var checkOutcomes: [E2EEAutoHistoryRequests.RequestOutcome] = []
        var starts = 0
        var checks = 0
        var continued = 0
        var removed: [String] = []
        var listing: E2EEAutoHistoryRequests.Listing = .requests([])
        var approveOutcome: E2EEAutoHistoryRequests.ApproveOutcome = .served
        var approved: [String] = []
        var hasPasskey = false
        var passkeyOutcomes: [Coordinator.PasskeyRecovery] = []
        var passkeyUses = 0

        @MainActor
        func coordinator() -> Coordinator {
            Coordinator(dependencies: .init(
                client: {
                    .init(
                        start: { self.starts += 1; return self.startOutcomes.isEmpty ? .waiting(E2EEAutoHistoryRequestCoordinatorTests.open) : self.startOutcomes.removeFirst() },
                        check: { self.checks += 1; return self.checkOutcomes.isEmpty ? .waiting(E2EEAutoHistoryRequestCoordinatorTests.open) : self.checkOutcomes.removeFirst() },
                        hasOpenRequest: { self.hasOpenRequest },
                        ownFingerprint: { ["48213", "09177", "66402", "31958"] },
                        openRequests: { self.listing },
                        approve: { self.approved.append($0); return self.approveOutcome },
                        hasPasskey: { self.hasPasskey },
                        usePasskey: { self.passkeyUses += 1; return self.passkeyOutcomes.isEmpty ? .failed : self.passkeyOutcomes.removeFirst() }
                    )
                },
                historyKeyHeld: { _ in
                    self.keyChecks += 1
                    if let after = self.heldAfterChecks, self.keyChecks > after { return true }
                    return self.held
                },
                continueWithHistoryKey: { self.continued += 1 },
                removeDelivered: { self.removed.append($0) },
                sleep: { duration in self.clock.addTimeInterval(TimeInterval(duration.components.seconds)) },
                now: { self.clock }
            ))
        }
    }

    private func settle(_ coordinator: Coordinator) async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// HK arrivée par le trousseau pendant l'attente : aucune demande.
    func testHistoryKeyArrivingBySyncOpensNoRequest() async {
        let world = World()
        world.heldAfterChecks = 3
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        XCTAssertEqual(world.starts, 0)
        XCTAssertEqual(world.continued, 1)
        XCTAssertNil(coordinator.requester)
    }

    /// Sans synchro, la demande part après 120 s, pas avant.
    func testRequestOpensAfterTheSyncWait() async {
        let world = World()
        let start = world.clock
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        XCTAssertEqual(world.starts, 1)
        XCTAssertEqual(world.clock.timeIntervalSince(start), Coordinator.syncWait)
        XCTAssertEqual(world.keyChecks, 12)
        XCTAssertEqual(coordinator.requester?.phase, .waiting)
        XCTAssertEqual(coordinator.requester?.fingerprint, ["48213", "09177", "66402", "31958"])
        XCTAssertTrue(coordinator.presentsRequester)
    }

    /// Une demande déjà ouverte n'attend pas la synchro.
    func testOpenRequestSkipsTheSyncWait() async {
        let world = World()
        world.hasOpenRequest = true
        let start = world.clock
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        XCTAssertEqual(world.starts, 1)
        XCTAssertEqual(world.clock, start)
    }

    /// Relue toutes les 10 s pendant 15 min, puis « Vérifier ».
    func testPollingStopsAfterFifteenMinutes() async {
        let world = World()
        world.hasOpenRequest = true
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        await coordinator.pollWhileVisible()
        XCTAssertEqual(coordinator.requester?.phase, .paused)
        XCTAssertEqual(world.checks, 90)
        await coordinator.verify()
        XCTAssertEqual(world.checks, 91)
        XCTAssertEqual(coordinator.requester?.phase, .paused)
    }

    /// Servie pendant l'attente : HK suit la chaîne habituelle, l'écran le dit.
    func testServedRequestContinuesWithTheHistoryKey() async {
        let world = World()
        world.hasOpenRequest = true
        world.checkOutcomes = [.waiting(Self.open), .present(hkPubB64: "hk")]
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        await coordinator.pollWhileVisible()
        XCTAssertEqual(world.checks, 2)
        XCTAssertEqual(world.continued, 1)
        XCTAssertEqual(coordinator.requester?.phase, .received)
    }

    /// « Continuer sans l'historique » : l'écran se ferme, une réponse arrivée
    /// au retour au premier plan est prise sans rien afficher.
    func testHiddenRequesterStillReceivesQuietly() async {
        let world = World()
        world.hasOpenRequest = true
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        coordinator.hideRequester()
        XCTAssertFalse(coordinator.presentsRequester)
        world.checkOutcomes = [.present(hkPubB64: "hk")]
        await coordinator.refresh()
        XCTAssertEqual(world.continued, 1)
        XCTAssertNil(coordinator.requester)
    }

    /// « C'est moi » servi : la notification livrée se retire.
    func testApprovalServedRemovesTheNotification() async {
        let world = World()
        world.listing = .requests([Self.pending])
        let coordinator = world.coordinator()
        await coordinator.refreshApprovals()
        XCTAssertEqual(coordinator.approval?.pending, Self.pending)
        await coordinator.approve()
        XCTAssertEqual(world.approved, [Self.pending.requestId])
        XCTAssertEqual(coordinator.approval?.phase, .served)
        XCTAssertEqual(world.removed, [Self.pending.requestId])
    }

    /// Servie par un autre appareil (`_closed`) : l'écran non servi se ferme.
    func testClosedPushDismissesAnUnservedApproval() async {
        let world = World()
        world.listing = .requests([Self.pending])
        let coordinator = world.coordinator()
        await coordinator.refreshApprovals()
        world.listing = .requests([])
        await coordinator.requestClosed(Self.pending.requestId)
        XCTAssertNil(coordinator.approval)
        XCTAssertEqual(world.removed, [Self.pending.requestId])
        XCTAssertTrue(world.approved.isEmpty)
    }

    /// « Pas maintenant » : plus présentée avant le prochain lancement.
    func testPostponedApprovalIsNotShownAgain() async {
        let world = World()
        world.listing = .requests([Self.pending])
        let coordinator = world.coordinator()
        await coordinator.refreshApprovals()
        coordinator.closeApproval()
        await coordinator.refreshApprovals()
        XCTAssertNil(coordinator.approval)
    }

    /// §5.3 point 2 : après la synchro, une passkey du compte passe avant « C'est moi ».
    func testPasskeyComesBeforeTheRequest() async {
        let world = World()
        world.hasPasskey = true
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        XCTAssertEqual(world.starts, 0)
        XCTAssertEqual(coordinator.requester?.phase, .passkey)

        world.passkeyOutcomes = [.present(hkPubB64: "hk")]
        await coordinator.usePasskey()
        XCTAssertEqual(world.passkeyUses, 1)
        XCTAssertEqual(world.continued, 1)
        XCTAssertEqual(world.starts, 0)
        XCTAssertEqual(coordinator.requester?.phase, .received)
    }

    /// Passkey périmée ou annulée : l'écran reste, « Demander à un autre appareil » ouvre la demande.
    func testStalePasskeyFallsBackToARequest() async {
        let world = World()
        world.hasPasskey = true
        let coordinator = world.coordinator()
        coordinator.historyKeyMissing(hkPubB64: "hk")
        await settle(coordinator)
        world.passkeyOutcomes = [.cancelled, .older]
        await coordinator.usePasskey()
        XCTAssertEqual(coordinator.requester?.phase, .passkey)
        XCTAssertNil(coordinator.requester?.passkeyIssue)
        await coordinator.usePasskey()
        XCTAssertEqual(coordinator.requester?.passkeyIssue, .older)
        XCTAssertEqual(world.continued, 0)

        await coordinator.askAnotherDevice()
        XCTAssertEqual(world.starts, 1)
        XCTAssertEqual(coordinator.requester?.phase, .waiting)
    }
}
