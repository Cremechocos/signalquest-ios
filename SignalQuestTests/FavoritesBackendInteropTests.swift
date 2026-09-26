import XCTest
@testable import SignalQuest

/// Nécessite SQ_FAVORITES_INTEROP=1 et une fixture du serveur synthétique local.
/// La CI ordinaire ignore cette suite et ne contacte jamais le serveur QA.
@MainActor
final class FavoritesBackendInteropTests: XCTestCase {
    private let first = FavoriteAntenna(siteId: "IOS-ONE", market: "FR", operator: "SFR", name: "Synthetic iOS one")
    private let second = FavoriteAntenna(siteId: "IOS-TWO", market: "BE", operator: nil, name: "Synthetic iOS two")

    func testRealBackendAlternatingClientsKeepBothFavoritesAndIndependentPreference() async throws {
        try await scenario { harness in
            let ios = try harness.client(harness.scenario.A, directoryName: "ios")
            let peer = try harness.client(harness.scenario.A, directoryName: "peer")
            await ios.service.load()
            await peer.service.load()
            assertLoaded(ios)
            assertLoaded(peer)
            _ = await ios.service.toggle(first)
            _ = await peer.service.toggle(second)
            await ios.service.setNotifyOnIssues(true)
            await peer.service.load()
            await ios.service.load()
            let expected = Set([first.id, second.id])
            XCTAssertEqual(Set(ios.service.favorites.map(\.id)), expected)
            XCTAssertEqual(Set(peer.service.favorites.map(\.id)), expected)
            XCTAssertTrue(peer.service.notifyOnIssues)
            let account = try await harness.databaseState().account(harness.scenario.A)
            XCTAssertEqual(account.favoriteKeys, expected)
            XCTAssertTrue(account.preferences.notifyFavoriteAntennaIssuesPush)
            XCTAssertEqual(account.receipts.count, 3)
            XCTAssertEqual(ios.service.pendingCount, 0)
            XCTAssertEqual(peer.service.pendingCount, 0)
        }
    }

    func testRealLostResponseRetryFindsReceiptWithoutResurrectingPeerRemoval() async throws {
        try await scenario { harness in
            let ios = try harness.client(harness.scenario.A, directoryName: "ios")
            await ios.service.load()
            assertLoaded(ios)
            try await harness.fault("drop_after_commit")
            _ = await ios.service.toggle(first)
            XCTAssertEqual(ios.service.pendingCount, 1, "La perte de réponse doit conserver l’intention durable")
            let disk = try await ios.store.load(ownerScopeID: "user:" + harness.scenario.A.userId)
            let requestID = try XCTUnwrap(disk?.pending.first?.requestId)
            let committed = try await harness.databaseState().account(harness.scenario.A)
            XCTAssertEqual(committed.favoriteKeys, [first.id])
            XCTAssertEqual(committed.receipts.map(\.requestId), [requestID])

            let peer = try harness.client(harness.scenario.A, directoryName: "peer")
            await peer.service.load()
            await peer.service.remove(first)
            let reopened = try harness.client(harness.scenario.A, directoryName: "ios")
            await reopened.service.load()
            XCTAssertTrue(reopened.service.favorites.isEmpty)
            XCTAssertEqual(reopened.service.pendingCount, 0)
            XCTAssertNil(reopened.service.errorMessage)
            let final = try await harness.databaseState().account(harness.scenario.A)
            XCTAssertTrue(final.favoriteKeys.isEmpty)
            XCTAssertEqual(final.receipts.count, 2, "Le replay réutilise le reçu, pas une troisième mutation")
            let attempts = try await harness.events().filter { $0.method == "PATCH" && $0.mutationId == requestID }
            XCTAssertEqual(attempts.count, 2)
            XCTAssertEqual(attempts.first?.fault, "drop_after_commit")
            let restored = try await reopened.store.load(ownerScopeID: "user:" + harness.scenario.A.userId)
            XCTAssertTrue(restored?.pending.isEmpty == true)
            XCTAssertTrue(restored?.attemptedRequestIDs.isEmpty == true)
        }
    }

    func testExplicitRemovalDoesNotReaddAnItemAlreadyRemovedByAnotherClient() async throws {
        try await scenario { harness in
            let ios = try harness.client(harness.scenario.A, directoryName: "ios")
            let peer = try harness.client(harness.scenario.A, directoryName: "peer")
            await ios.service.load()
            _ = await ios.service.toggle(first)
            await peer.service.load()
            await peer.service.remove(first)
            // Le snapshot iOS contient encore la ligne : remove reste un retrait.
            XCTAssertTrue(ios.service.isFavorite(siteId: first.siteId, market: first.market))
            await ios.service.remove(first)
            XCTAssertTrue(ios.service.favorites.isEmpty)
            let account = try await harness.databaseState().account(harness.scenario.A)
            XCTAssertTrue(account.favoriteKeys.isEmpty)
            XCTAssertEqual(ios.service.pendingCount, 0)
        }
    }

    func testNotificationEndpointAndFavoriteMutationsDoNotOverwriteEachOther() async throws {
        try await scenario { harness in
            let ios = try harness.client(harness.scenario.A, directoryName: "ios")
            let peer = try harness.client(harness.scenario.A, directoryName: "peer")
            await ios.service.load()
            try await peer.patchNotificationSettings(["notifyFavoriteAntennaIssuesPush": true, "notifyMessagesPush": true])
            _ = await ios.service.toggle(first)
            XCTAssertTrue(ios.service.notifyOnIssues)
            await ios.service.setNotifyOnIssues(false)
            let preferences = try await peer.notificationSettings()
            XCTAssertEqual(preferences["notifyFavoriteAntennaIssuesPush"], false)
            XCTAssertEqual(preferences["notifyMessagesPush"], true)
            let account = try await harness.databaseState().account(harness.scenario.A)
            XCTAssertEqual(account.favoriteKeys, [first.id])
            XCTAssertFalse(account.preferences.notifyFavoriteAntennaIssuesPush)
            XCTAssertEqual(account.receipts.count, 2)
        }
    }

    func testServerCapacityRejectionIsTerminalAndNewGestureUsesNewReceipt() async throws {
        try await scenario { harness in
            let ios = try harness.client(harness.scenario.A, directoryName: "ios")
            await ios.service.load()
            assertLoaded(ios)
            // L'autre client remplit la capacité après le snapshot local vide.
            try await harness.reset(capacity: true)
            _ = await ios.service.toggle(first)
            XCTAssertEqual(ios.service.pendingCount, 0)
            XCTAssertEqual(ios.service.favorites.count, 500)
            XCTAssertFalse(ios.service.isFavorite(siteId: first.siteId, market: first.market))
            XCTAssertNotNil(ios.service.errorMessage)
            let rejected = try await harness.databaseState().account(harness.scenario.A)
            let terminal = try XCTUnwrap(rejected.receipts.first)
            XCTAssertEqual(terminal.outcome, "capacity_rejected")

            let peer = try harness.client(harness.scenario.A, directoryName: "peer")
            await peer.service.load()
            await peer.service.remove(FavoriteAntenna(siteId: "CAP-0000", market: "FR", operator: "SFR"))
            await ios.service.load()
            _ = await ios.service.toggle(first)
            XCTAssertTrue(ios.service.isFavorite(siteId: first.siteId, market: first.market))
            XCTAssertEqual(ios.service.pendingCount, 0)
            let final = try await harness.databaseState().account(harness.scenario.A)
            XCTAssertEqual(final.favorites.count, 500)
            XCTAssertEqual(final.receipts.count, 3)
            XCTAssertTrue(final.receipts.contains { $0.requestId == terminal.requestId && $0.outcome == "capacity_rejected" })
            let attempts = try await harness.events().filter { $0.method == "PATCH" && $0.mutationId == terminal.requestId }
            XCTAssertEqual(attempts.count, 1, "Un reçu de capacité refusée ne doit pas être rejoué")
        }
    }

    func testHeldAccountAResponseCannotPublishOrReplayAsAccountB() async throws {
        try await scenario { harness in
            let client = try harness.client(harness.scenario.A, directoryName: "ios")
            await client.service.load()
            let scopeA = try XCTUnwrap(client.service.captureActionScope())
            try await harness.fault("hold_after_commit")
            let adding = Task { await client.service.toggle(first, matching: scopeA) }
            let heldID = try await harness.waitForHeldMutation()
            try client.switchAccount(to: harness.scenario.B)
            XCTAssertTrue(client.service.favorites.isEmpty)
            XCTAssertNil(client.service.errorMessage)
            await client.service.load()
            _ = await client.service.toggle(first, matching: scopeA)
            let beforeB = try await harness.databaseState().account(harness.scenario.B)
            XCTAssertTrue(beforeB.favoriteKeys.isEmpty)
            XCTAssertTrue(beforeB.receipts.isEmpty)
            _ = await client.service.toggle(second)
            try await harness.release(heldID)
            _ = await adding.value
            XCTAssertEqual(Set(client.service.favorites.map(\.id)), [second.id])
            let state = try await harness.databaseState()
            XCTAssertEqual(try state.account(harness.scenario.A).favoriteKeys, [first.id])
            XCTAssertEqual(try state.account(harness.scenario.B).favoriteKeys, [second.id])
            XCTAssertEqual(try state.account(harness.scenario.B).receipts.count, 1)
            try client.switchAccount(to: harness.scenario.A)
            await client.service.load()
            XCTAssertEqual(Set(client.service.favorites.map(\.id)), [first.id])
            XCTAssertEqual(client.service.pendingCount, 0)
            let final = try await harness.databaseState()
            XCTAssertEqual(try final.account(harness.scenario.A).receipts.count, 1)
            XCTAssertEqual(try final.account(harness.scenario.B).favoriteKeys, [second.id])
        }
    }

    private func assertLoaded(_ client: FavoritesInteropClient, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(client.service.hasLoaded, file: file, line: line)
        XCTAssertNil(client.service.errorMessage, file: file, line: line)
    }

    private func scenario(_ body: @MainActor (FavoritesInteropHarness) async throws -> Void) async throws {
        let harness = try await FavoritesInteropHarness.create()
        do {
            try await body(harness)
            await harness.cleanUp()
        } catch {
            await harness.cleanUp()
            throw error
        }
    }
}
