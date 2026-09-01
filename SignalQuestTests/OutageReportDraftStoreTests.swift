import XCTest
@testable import SignalQuest

final class OutageReportDraftStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let ownerA = "user:outage-draft-a"
    private let ownerB = "user:outage-draft-b"

    override func setUp() {
        super.setUp()
        suiteName = "OutageReportDraftStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func scope(owner: String = "user:outage-draft-a", target: String = "site-1") -> OutageReportDraftScope {
        .init(ownerScopeId: owner, targetKind: "custom", targetId: target, marketCode: "CH", operatorKey: "SWISSCOM")
    }

    func testDraftSurvivesAndIsScopedToOwnerAndTarget() throws {
        var draft = OutageReportDraft()
        draft.select(.degraded)
        draft.affectsVoice = true
        draft.technologies = ["4g", "5g"]
        draft.bands = ["n78"]
        draft.sectors = [60, 180]
        draft.comment = "Débit très dégradé"
        OutageReportDraftStore.save(draft, scope: scope(), defaults: defaults, nowMs: 100, currentOwnerScopeId: ownerA)

        let restored = try XCTUnwrap(OutageReportDraftStore.restore(
            scope: scope(), defaults: defaults, nowMs: 200, currentOwnerScopeId: ownerA
        ))
        XCTAssertEqual(restored, draft)
        XCTAssertNil(OutageReportDraftStore.restore(
            scope: scope(owner: ownerB), defaults: defaults, nowMs: 200, currentOwnerScopeId: ownerB
        ))
        XCTAssertNil(OutageReportDraftStore.restore(
            scope: scope(target: "site-2"), defaults: defaults, nowMs: 200, currentOwnerScopeId: ownerA
        ))
    }

    func testLateWriteAfterLogoutCannotResurrectPurgedDraft() {
        var draftA = OutageReportDraft(); draftA.select(.down)
        var draftB = OutageReportDraft(); draftB.select(.degraded)
        OutageReportDraftStore.save(draftA, scope: scope(), defaults: defaults, nowMs: 100, currentOwnerScopeId: ownerA)
        OutageReportDraftStore.save(draftB, scope: scope(owner: ownerB), defaults: defaults, nowMs: 100, currentOwnerScopeId: ownerB)
        OutageReportDraftStore.purge(ownerScopeId: ownerA, defaults: defaults)
        OutageReportDraftStore.save(draftA, scope: scope(), defaults: defaults, nowMs: 200, currentOwnerScopeId: ownerB)
        XCTAssertNil(OutageReportDraftStore.restore(scope: scope(), defaults: defaults, nowMs: 300, currentOwnerScopeId: ownerA))
        XCTAssertEqual(OutageReportDraftStore.restore(
            scope: scope(owner: ownerB), defaults: defaults, nowMs: 300, currentOwnerScopeId: ownerB
        )?.severity, .degraded)
    }

    func testEmptyAndExpiredDraftsAreRemoved() {
        OutageReportDraftStore.save(OutageReportDraft(), scope: scope(), defaults: defaults, nowMs: 100, currentOwnerScopeId: ownerA)
        XCTAssertNil(OutageReportDraftStore.restore(scope: scope(), defaults: defaults, nowMs: 200, currentOwnerScopeId: ownerA))
        var draft = OutageReportDraft(); draft.select(.down)
        OutageReportDraftStore.save(draft, scope: scope(), defaults: defaults, nowMs: 100, currentOwnerScopeId: ownerA)
        XCTAssertNil(OutageReportDraftStore.restore(
            scope: scope(), defaults: defaults,
            nowMs: 100 + OutageReportDraftStore.ttlMs + 1,
            currentOwnerScopeId: ownerA
        ))
    }
}
