import XCTest
@testable import SignalQuest

@MainActor
final class SpeedtestVisibilityViewModelTests: XCTestCase {
    private func model(_ service: VisibilityTestService, guest: Bool = false) -> SpeedtestVisibilityViewModel {
        SpeedtestVisibilityViewModel(clientID: UUID(), service: service, guestMode: guest,
                                     vpnIsActive: { service.context.vpn })
    }

    func testGuestNeverLooksUpOrMutatesAnOwnerMeasurement() async {
        let service = VisibilityTestService()
        let model = model(service, guest: true)
        await model.load()
        XCTAssertEqual(model.availability, .guest)
        XCTAssertFalse(model.canHide)
        XCTAssertNil(model.requestPublicationConfirmation())
        await model.hide()
        let counts = await service.counts
        XCTAssertEqual(counts.loads, 0)
        XCTAssertEqual(counts.mutations, 0)
    }

    func testMissingAuthenticatedSessionDoesNotReadPrivateState() async {
        let service = VisibilityTestService()
        service.context.session = nil
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.availability, .sessionChanged)
        XCTAssertNil(model.state)
        let counts = await service.counts
        XCTAssertEqual(counts.loads, 0)
    }

    func testMissingServerReferenceIsNotPresentedAsHiddenOrPublished() async {
        let service = VisibilityTestService()
        await service.setState(nil)
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.availability, .noServerReference)
        XCTAssertNil(model.state)
        XCTAssertFalse(model.isStateCurrent)
        XCTAssertFalse(model.canHide)
        XCTAssertNil(model.requestPublicationConfirmation())
    }

    func testNonOwnerCannotChangeVisibilityEvenForAPublicMeasurement() async {
        let service = VisibilityTestService()
        await service.setState(.fixture(owner: false))
        let model = model(service)
        await model.load()
        XCTAssertTrue(model.isStateCurrent)
        XCTAssertFalse(model.canHide)
        XCTAssertNil(model.requestPublicationConfirmation())
        await model.hide()
        let counts = await service.counts
        XCTAssertEqual(counts.mutations, 0)
    }

    func testHidePersistsAndANewSheetReadsTheSavedValue() async {
        let service = VisibilityTestService()
        let first = model(service)
        await first.load()
        XCTAssertTrue(first.canHide)
        await first.hide()
        XCTAssertEqual(first.state?.isVisibleOnMap, false)
        XCTAssertTrue(first.isStateCurrent)
        XCTAssertNotNil(first.confirmationMessage)
        first.deactivate()
        let reopened = model(service)
        await reopened.load()
        XCTAssertEqual(reopened.state?.isSharedOnMap, false)
        XCTAssertTrue(reopened.canPublish)
        let counts = await service.counts
        XCTAssertEqual(counts.mutations, 1)
        XCTAssertEqual(counts.loads, 3, "Initial load, post-PATCH verification, reopened sheet")
    }

    func testAPrivateHistoricalMeasurementRequiresItsOwnExplicitConfirmation() async throws {
        let service = VisibilityTestService()
        await service.setState(.fixture(visible: false))
        let model = model(service)
        await model.load()
        let consent = try XCTUnwrap(model.requestPublicationConfirmation())
        var counts = await service.counts
        XCTAssertEqual(counts.mutations, 0)
        await model.confirmPublication(consent)
        XCTAssertEqual(model.state?.isSharedOnMap, true)
        XCTAssertNotNil(model.confirmationMessage)
        await model.confirmPublication(consent)
        counts = await service.counts
        XCTAssertEqual(counts.mutations, 1, "A confirmation cannot be reused")
    }

    func testCancelledOrAnotherSheetsConfirmationDoesNotPublish() async throws {
        let service = VisibilityTestService()
        await service.setState(.fixture(visible: false))
        let first = model(service)
        let second = model(service)
        await first.load()
        await second.load()
        let cancelled = try XCTUnwrap(first.requestPublicationConfirmation())
        first.cancelPublicationConfirmation()
        await first.confirmPublication(cancelled)
        let another = try XCTUnwrap(second.requestPublicationConfirmation())
        await first.confirmPublication(another)
        let counts = await service.counts
        XCTAssertEqual(counts.mutations, 0)
    }

    func testFailedMutationLeavesVisibilityUnconfirmedUntilAnExplicitReload() async {
        let service = VisibilityTestService()
        let model = model(service)
        await model.load()
        await service.setMutationFailure(APIError.transport("synthetic network failure"))
        await model.hide()
        XCTAssertEqual(model.state?.isVisibleOnMap, true)
        XCTAssertFalse(model.isStateCurrent)
        XCTAssertNil(model.confirmationMessage)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.canHide)
        await service.setMutationFailure(nil)
        await model.load()
        XCTAssertTrue(model.isStateCurrent)
        XCTAssertTrue(model.canHide)
    }

    func testFalseSuccessAndMismatchedResponsesNeverConfirmAChange() async {
        for response in [
            SpeedtestVisibilityResponse.fixture(success: false),
            SpeedtestVisibilityResponse.fixture(id: "another-measurement"),
            SpeedtestVisibilityResponse.fixture(visible: true, shared: true),
            SpeedtestVisibilityResponse.fixture(shared: true),
        ] {
            let service = VisibilityTestService()
            let model = model(service)
            await model.load()
            await service.setMutationResponse(response)
            await model.hide()
            XCTAssertFalse(model.isStateCurrent)
            XCTAssertNil(model.confirmationMessage)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testSuccessfulPatchWithFailedReadbackDoesNotClaimVisibilityWasVerified() async {
        let service = VisibilityTestService()
        let model = model(service)
        await model.load()
        await service.failNextLoad(APIError.transport("readback unavailable"))
        await model.hide()
        XCTAssertFalse(model.isStateCurrent)
        XCTAssertNil(model.confirmationMessage)
        XCTAssertNotNil(model.errorMessage)
        await model.load()
        XCTAssertTrue(model.isStateCurrent)
        XCTAssertEqual(model.state?.isVisibleOnMap, false)
    }

    func testReadbackThatContradictsThePatchIsNotConfirmed() async {
        let service = VisibilityTestService()
        let model = model(service)
        await model.load()
        await service.setShouldPersist(false)
        await model.hide()
        XCTAssertFalse(model.isStateCurrent)
        XCTAssertNil(model.confirmationMessage)
        XCTAssertNotNil(model.errorMessage)
    }

    func testIneligibleOrUnlocatedMeasurementsAreNeverOfferedForPublication() async {
        for state in [SpeedtestVisibilityState.fixture(visible: false, isPublic: false), .fixture(visible: false, position: false)] {
            let service = VisibilityTestService()
            await service.setState(state)
            let model = model(service)
            await model.load()
            XCTAssertNil(model.requestPublicationConfirmation())
            XCTAssertFalse(model.canPublish)
        }
    }

    func testVPNPreventsPublicationButNeverPreventsHiding() async throws {
        let service = VisibilityTestService()
        let model = model(service)
        service.context.vpn = true
        await model.load()
        XCTAssertTrue(model.canHide)
        await model.hide()
        XCTAssertNil(model.requestPublicationConfirmation())
        service.context.vpn = false
        let consent = try XCTUnwrap(model.requestPublicationConfirmation())
        service.context.vpn = true
        await model.confirmPublication(consent)
        let counts = await service.counts
        XCTAssertEqual(counts.mutations, 1, "Only the hide request was sent")
    }

    func testPrivateZoneRefusalDoesNotBecomePublishedState() async throws {
        let service = VisibilityTestService()
        await service.setState(.fixture(visible: false))
        let model = model(service)
        await model.load()
        await service.setMutationFailure(APIError.http(status: 409, code: "SPEEDTEST_PRIVATE_ZONE", message: "", requestId: nil, retryAfter: nil))
        let consent = try XCTUnwrap(model.requestPublicationConfirmation())
        await model.confirmPublication(consent)
        XCTAssertEqual(model.state?.isVisibleOnMap, false)
        XCTAssertFalse(model.isStateCurrent)
        XCTAssertNil(model.confirmationMessage)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAccountSwitchDuringLoadDiscardsItsOwnerData() async {
        let service = VisibilityTestService()
        let started = expectation(description: "owner load started")
        await service.suspendNextLoad(started)
        let model = model(service)
        let task = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        service.context.session = .fixture(owner: "user:B")
        await service.finishLoad(.fixture())
        await task.value
        XCTAssertNil(model.state)
        XCTAssertEqual(model.availability, .sessionChanged)
        XCTAssertFalse(model.isLoading)
    }

    func testAccountSwitchDuringMutationDoesNotShowThePreviousAccountsConfirmation() async {
        let service = VisibilityTestService()
        let model = model(service)
        await model.load()
        let started = expectation(description: "mutation started")
        await service.suspendNextMutation(started)
        let task = Task { await model.hide() }
        await fulfillment(of: [started], timeout: 2)
        service.context.session = .fixture(owner: "user:B")
        await service.finishMutation()
        await task.value
        XCTAssertNil(model.state)
        XCTAssertNil(model.confirmationMessage)
        XCTAssertEqual(model.availability, .sessionChanged)
        XCTAssertFalse(model.isSaving)
    }

    func testClosedSheetCannotPublishLateMutationStateIntoAnotherSheet() async {
        let service = VisibilityTestService()
        let old = model(service)
        await old.load()
        let started = expectation(description: "mutation started")
        await service.suspendNextMutation(started)
        let task = Task { await old.hide() }
        await fulfillment(of: [started], timeout: 2)
        old.deactivate()
        let other = model(service)
        await other.load()
        let before = other.state
        await service.finishMutation()
        await task.value
        XCTAssertNil(old.state)
        XCTAssertNil(old.confirmationMessage)
        XCTAssertEqual(other.state, before)
        XCTAssertTrue(other.isStateCurrent)
    }

    func testDoubleTapHideSubmitsOnceAndCannotClearTheActiveSpinner() async {
        let service = VisibilityTestService()
        let model = model(service)
        await model.load()
        let started = expectation(description: "mutation started")
        await service.suspendNextMutation(started)
        let task = Task { await model.hide() }
        await fulfillment(of: [started], timeout: 2)
        await model.hide()
        await model.load()
        XCTAssertTrue(model.isSaving)
        let counts = await service.counts
        XCTAssertEqual(counts.mutations, 1)
        await service.finishMutation()
        await task.value
        XCTAssertFalse(model.isSaving)
    }

    func testOlderLoadCannotReplaceASecondLoadOrItsSpinner() async {
        let service = VisibilityTestService()
        let model = model(service)
        let started = expectation(description: "first load started")
        await service.suspendNextLoad(started)
        let old = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        await service.setState(.fixture(visible: false))
        await model.load()
        await service.finishLoad(.fixture(visible: true))
        await old.value
        XCTAssertEqual(model.state?.isVisibleOnMap, false)
        XCTAssertTrue(model.isStateCurrent)
        XCTAssertFalse(model.isLoading)
    }
}

private extension SpeedtestVisibilitySession {
    static func fixture(owner: String = "user:A") -> Self {
        .init(credentialSessionID: UUID(), ownerScopeID: owner, localSessionID: UUID().uuidString)
    }
}

private extension SpeedtestVisibilityState {
    static func fixture(owner: Bool = true, visible: Bool = true, isPublic: Bool = true, position: Bool = true) -> Self {
        .init(id: "measurement-A", isOwner: owner, isVisibleOnMap: visible, isPublic: isPublic, hasMapPosition: position)
    }
}

private extension SpeedtestVisibilityResponse {
    static func fixture(success: Bool = true, id: String = "measurement-A", visible: Bool = false, shared: Bool = false) -> Self {
        .init(success: success, id: id, isVisibleOnMap: visible, isPublic: true,
              isSharedOnMap: shared, changed: true, mapEpoch: 1)
    }
}

private final class VisibilityTestContext: @unchecked Sendable {
    private let lock = NSLock()
    private var currentSession: SpeedtestVisibilitySession? = .fixture()
    private var currentVPN = false
    var session: SpeedtestVisibilitySession? {
        get { lock.withLock { currentSession } }
        set { lock.withLock { currentSession = newValue } }
    }
    var vpn: Bool {
        get { lock.withLock { currentVPN } }
        set { lock.withLock { currentVPN = newValue } }
    }
}

private actor VisibilityTestService: SpeedtestVisibilityServicing {
    nonisolated let context = VisibilityTestContext()
    nonisolated var visibilitySession: SpeedtestVisibilitySession? { context.session }
    private var state: SpeedtestVisibilityState? = .fixture()
    private var mutationFailure: Error?
    private var nextLoadFailure: Error?
    private var mutationResponse: SpeedtestVisibilityResponse?
    private var shouldPersist = true
    private var loadExpectation: XCTestExpectation?
    private var mutationExpectation: XCTestExpectation?
    private var loadContinuation: CheckedContinuation<SpeedtestVisibilityState?, Never>?
    private var mutationContinuation: CheckedContinuation<Void, Never>?
    private(set) var counts = (loads: 0, mutations: 0)

    func setState(_ value: SpeedtestVisibilityState?) { state = value }
    func setMutationFailure(_ value: Error?) { mutationFailure = value }
    func failNextLoad(_ value: Error) { nextLoadFailure = value }
    func setMutationResponse(_ value: SpeedtestVisibilityResponse) { mutationResponse = value }
    func setShouldPersist(_ value: Bool) { shouldPersist = value }
    func suspendNextLoad(_ expectation: XCTestExpectation) { loadExpectation = expectation }
    func suspendNextMutation(_ expectation: XCTestExpectation) { mutationExpectation = expectation }
    func finishLoad(_ value: SpeedtestVisibilityState?) { loadContinuation?.resume(returning: value); loadContinuation = nil }
    func finishMutation() { mutationContinuation?.resume(); mutationContinuation = nil }

    func visibility(forClientID clientID: UUID, session: SpeedtestVisibilitySession) async throws -> SpeedtestVisibilityState? {
        counts.loads += 1
        if let error = nextLoadFailure { nextLoadFailure = nil; throw error }
        if let expectation = loadExpectation {
            loadExpectation = nil
            return await withCheckedContinuation { continuation in
                loadContinuation = continuation
                expectation.fulfill()
            }
        }
        return state
    }

    func setVisibility(serverID: String, visible: Bool, session: SpeedtestVisibilitySession) async throws -> SpeedtestVisibilityResponse {
        counts.mutations += 1
        if let expectation = mutationExpectation {
            mutationExpectation = nil
            await withCheckedContinuation { continuation in
                mutationContinuation = continuation
                expectation.fulfill()
            }
        }
        if let error = mutationFailure { throw error }
        if let response = mutationResponse { return response }
        if shouldPersist, let old = state {
            state = .init(id: serverID, isOwner: old.isOwner, isVisibleOnMap: visible,
                          isPublic: old.isPublic, hasMapPosition: old.hasMapPosition)
        }
        return .fixture(visible: visible, shared: visible)
    }
}
