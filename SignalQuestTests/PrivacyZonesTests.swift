import XCTest
@testable import SignalQuest

final class PrivacyZoneDraftTests: XCTestCase {
    func testCreateUsesExplicitCoordinateAndProtectsNewZoneByDefault() throws {
        var draft = PrivacyZoneDraft()
        XCTAssertThrowsError(try draft.createRequest())
        draft.name = "  Home  "
        draft.latitudeText = "48,856612"
        draft.longitudeText = "2.352218"
        let request = try draft.createRequest()
        XCTAssertEqual(request.name, "Home")
        XCTAssertEqual(request.latitude, 48.856612)
        XCTAssertEqual(request.longitude, 2.352218)
        XCTAssertTrue(request.hideSpeedtestsOnMap)
    }

    func testCoordinateAndRadiusValidationRejectInvalidProtectionGeometry() {
        for value in ["NaN", "inf", "91", "-91", ""] {
            var draft = validDraft(); draft.latitudeText = value
            XCTAssertThrowsError(try draft.validate())
        }
        for radius in [Double.nan, .infinity, 99, 20_001] {
            var draft = validDraft(); draft.radius = radius
            XCTAssertThrowsError(try draft.validate())
        }
        var south = validDraft(); south.latitudeText = "-33,86"; south.longitudeText = "151.21"
        XCTAssertNoThrow(try south.validate())
    }

    func testRenamingPreservesAndroidGeometryFlagsAndUnknownType() throws {
        let original = PrivacyZone(id: "android-home", name: "Old", type: "future-kind",
            latitude: 48.856612345, longitude: 2.352218987, radius: 373,
            isActive: false, hideSpeedtestsOnMap: false)
        var draft = PrivacyZoneDraft(zone: original); draft.name = "New"
        let patch = try draft.updateRequest(original: original)
        XCTAssertEqual(patch.id, original.id)
        XCTAssertEqual(patch.name, "New")
        XCTAssertNil(patch.type)
        XCTAssertNil(patch.latitude)
        XCTAssertNil(patch.longitude)
        XCTAssertNil(patch.radius)
        XCTAssertNil(patch.isActive)
        XCTAssertNil(patch.hideSpeedtestsOnMap)
    }

    func testMalformedZonesResponseFailsInsteadOfProducingEmptyList() throws {
        for json in ["{}", #"{"zones":null}"#, #"{"zones":[{"name":"Home"}]}"#,
                     #"{"zones":[{"id":"a","name":"Home","isActive":true,"hideSpeedtestsOnMap":"false"}]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(PrivacyZonesResponse.self, from: Data(json.utf8)))
        }
        XCTAssertTrue(try JSONDecoder().decode(PrivacyZonesResponse.self, from: Data(#"{"zones":[]}"#.utf8)).zones.isEmpty)
        let duplicate = #"{"zones":[{"id":"a","name":"Home","isActive":true,"hideSpeedtestsOnMap":true},{"id":"a","name":"Home","isActive":true,"hideSpeedtestsOnMap":true}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrivacyZonesResponse.self, from: Data(duplicate.utf8)))
    }

    func testPreferencesPatchDoesNotEncodeUnrelatedDefaults() throws {
        let data = try JSONEncoder().encode(UserPreferencesPatch(unitsSystem: .imperial))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json, ["unitsSystem": "imperial"])
    }

    func testHypothesisPreferencePatchDoesNotRewriteUnitsOrLeaderboard() throws {
        let data = try JSONEncoder().encode(UserPreferencesPatch(showHypothesisSystem: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        XCTAssertEqual(json, ["showHypothesisSystem": false])
    }

    func testPreferencesRequireCanonicalFieldsButAcceptMissingLegacyOptionalField() throws {
        let decoder = JSONDecoder()
        for json in ["{}", #"{"unitsSystem":"metric"}"#,
                     #"{"unitsSystem":"invalid","showHandleOnLeaderboard":true}"#,
                     #"{"unitsSystem":"metric","showHandleOnLeaderboard":true,"showHypothesisSystem":"false"}"#] {
            XCTAssertThrowsError(try decoder.decode(UserPreferences.self, from: Data(json.utf8)))
        }
        let value = try decoder.decode(UserPreferences.self,
            from: Data(#"{"unitsSystem":"imperial","showHandleOnLeaderboard":true}"#.utf8))
        XCTAssertEqual(value.unitsSystem, .imperial)
        XCTAssertTrue(value.showHandleOnLeaderboard)
        XCTAssertTrue(value.showHypothesisSystem)
    }

    func testMissingLegacyPrecisionDecodesWithoutInventingOtherPermissions() throws {
        let withoutPrecision = #"{"shareLiveLocationWithFriends":false,"shareRadioDataWithFriends":true,"shareSessionsWithFriends":false,"sharePhotosOnFriendMap":false,"lastSeenVisibility":"none","messageRequestPolicy":"friends_only"}"#
        let value = try JSONDecoder().decode(SocialPrivacy.self, from: Data(withoutPrecision.utf8))
        XCTAssertTrue(value.shareExactMeasurements)
        XCTAssertFalse(value.shareLiveLocationWithFriends)
        XCTAssertTrue(value.shareRadioDataWithFriends)
        XCTAssertThrowsError(try JSONDecoder().decode(SocialPrivacy.self, from: Data("{}".utf8)))
    }

    func testMalformedOptionalZoneGeometryDoesNotBecomeAnUnpositionedZone() throws {
        let json = #"{"zones":[{"id":"a","name":"Home","isActive":true,"hideSpeedtestsOnMap":true,"latitude":"invalid"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrivacyZonesResponse.self, from: Data(json.utf8)))
    }

    private func validDraft() -> PrivacyZoneDraft {
        var draft = PrivacyZoneDraft(); draft.name = "Home"; draft.select(latitude: 48, longitude: 2)
        return draft
    }
}

@MainActor
final class PrivacySettingsLoadingTests: XCTestCase {
    func testFailedPreferencesReadCannotOverwriteDefaultsButOtherSectionsLoad() async {
        let fixture = Fixture()
        await fixture.service.failPreferences(true)
        await fixture.model.load()
        XCTAssertTrue(fixture.model.loaded)
        XCTAssertTrue(fixture.model.zonesLoaded)
        XCTAssertFalse(fixture.model.preferencesLoaded)
        XCTAssertNotNil(fixture.model.preferencesError)
        await fixture.model.setUnits(.imperial)
        let writes = await fixture.service.preferenceWriteCount()
        XCTAssertEqual(writes, 0)
    }

    func testZonesReadFailurePreservesPreviousZonesAndRetryRecovers() async {
        let fixture = Fixture()
        await fixture.model.load()
        await fixture.service.failZones(true)
        await fixture.model.loadZones()
        XCTAssertEqual(fixture.model.zones.map(\.id), ["android-home"])
        XCTAssertTrue(fixture.model.zonesLoaded)
        XCTAssertNotNil(fixture.model.zonesError)
        await fixture.service.failZones(false)
        await fixture.model.loadZones()
        XCTAssertNil(fixture.model.zonesError)
        XCTAssertFalse(fixture.model.isLoadingZones)
    }

    func testInitialZonesFailureDoesNotMeanNoZonesAndCannotCreate() async {
        let fixture = Fixture()
        await fixture.service.failZones(true)
        await fixture.model.loadZones()
        XCTAssertFalse(fixture.model.zonesLoaded)
        XCTAssertNotNil(fixture.model.zonesError)
        let saved = await fixture.model.saveZone(fixture.draft, original: nil)
        XCTAssertFalse(saved)
        let writes = await fixture.service.zoneWriteCount()
        XCTAssertEqual(writes, 0)
    }

    func testOlderZoneResponseCannotReplaceNewerLoad() async {
        let fixture = Fixture()
        let started = expectation(description: "Ancienne lecture suspendue")
        let gate = PrivacyResultGate<[PrivacyZone]>(onWait: { started.fulfill() })
        await fixture.service.holdNextZones(gate)
        let first = Task { await fixture.model.loadZones() }
        await fulfillment(of: [started], timeout: 1)
        await fixture.service.replaceStoredZones([Fixture.otherZone])
        await fixture.model.loadZones()
        await gate.resolve([Fixture.homeZone])
        await first.value
        XCTAssertEqual(fixture.model.zones.map(\.id), ["new-zone"])
    }

    func testAccountChangeDiscardsPendingReadAndBlocksOldViewMutations() async {
        let fixture = Fixture()
        let started = expectation(description: "Lecture A suspendue")
        let gate = PrivacyResultGate<[PrivacyZone]>(onWait: { started.fulfill() })
        await fixture.service.holdNextZones(gate)
        let first = Task { await fixture.model.loadZones() }
        await fulfillment(of: [started], timeout: 1)
        fixture.session.current = .init(ownerScopeId: "user:b", sessionId: "b-session")
        await gate.resolve([Fixture.homeZone])
        await first.value
        await fixture.model.setZoneHidden(Fixture.homeZone, hidden: false)
        XCTAssertTrue(fixture.model.zones.isEmpty)
        XCTAssertFalse(fixture.model.zonesLoaded)
        XCTAssertFalse(fixture.model.isSessionCurrent)
        let writes = await fixture.service.zoneWriteCount()
        XCTAssertEqual(writes, 0)
    }

    func testCreateKeepsExistingAndroidZoneAndUsesCanonicalServerGeometry() async {
        let fixture = Fixture()
        await fixture.model.loadZones()
        let saved = await fixture.model.saveZone(fixture.draft, original: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.model.zones.map(\.id), ["android-home", "new-zone"])
        XCTAssertEqual(fixture.model.zones.first, Fixture.homeZone)
        XCTAssertEqual(fixture.model.zones.last?.latitude, Fixture.otherZone.latitude)
    }

    func testDeleteFailureKeepsZoneUntilServerAcknowledgesDeletion() async {
        let fixture = Fixture()
        await fixture.model.loadZones()
        await fixture.service.failMutations(true)
        let failed = await fixture.model.deleteZone(Fixture.homeZone)
        XCTAssertFalse(failed)
        XCTAssertEqual(fixture.model.zones, [Fixture.homeZone])
        XCTAssertNotNil(fixture.model.zoneMutationError)
        await fixture.service.failMutations(false)
        let deleted = await fixture.model.deleteZone(Fixture.homeZone)
        XCTAssertTrue(deleted)
        XCTAssertTrue(fixture.model.zones.isEmpty)
    }

    func testZoneToggleUsesCanonicalResponseInsteadOfMutatingOldCopy() async {
        let fixture = Fixture()
        await fixture.model.loadZones()
        await fixture.service.setUpdateReply(PrivacyZone(id: "android-home", name: "Server name", latitude: 49,
            longitude: 3, radius: 800, isActive: true, hideSpeedtestsOnMap: false))
        await fixture.model.setZoneHidden(Fixture.homeZone, hidden: false)
        XCTAssertEqual(fixture.model.zones.first?.name, "Server name")
        XCTAssertEqual(fixture.model.zones.first?.radius, 800)
        XCTAssertFalse(fixture.model.zones.first?.hideSpeedtestsOnMap ?? true)
    }

    func testLateCreateResponseAfterAccountSwitchCannotPublishOrClaimSuccess() async {
        let fixture = Fixture()
        await fixture.model.loadZones()
        let started = expectation(description: "Création A suspendue")
        let gate = PrivacyResultGate<PrivacyZone>(onWait: { started.fulfill() })
        await fixture.service.holdNextCreate(gate)
        let creation = Task { await fixture.model.saveZone(fixture.draft, original: nil) }
        await fulfillment(of: [started], timeout: 1)
        fixture.session.current = .init(ownerScopeId: "user:b", sessionId: "b-session")
        await gate.resolve(Fixture.otherZone)
        let saved = await creation.value
        XCTAssertFalse(saved)
        XCTAssertTrue(fixture.model.zones.isEmpty)
        XCTAssertFalse(fixture.model.zonesLoaded)
    }

    func testPrivacySaveSendsOnlyTheChangedSharingField() async {
        let fixture = Fixture()
        await fixture.model.loadPrivacy()
        fixture.model.shareRadioDataWithFriends = true
        let saved = await fixture.model.save()
        XCTAssertTrue(saved)
        let patch = await fixture.service.lastPrivacyPatch()
        XCTAssertEqual(patch?.shareRadioDataWithFriends, true)
        XCTAssertNil(patch?.shareLiveLocationWithFriends)
        XCTAssertNil(patch?.shareExactMeasurements)
        XCTAssertNil(patch?.messageRequestPolicy)
    }

    func testRefreshDoesNotOverwriteUnsavedPrivacyDraft() async {
        let fixture = Fixture()
        await fixture.model.loadPrivacy()
        fixture.model.shareRadioDataWithFriends = true
        await fixture.model.loadPrivacy()
        XCTAssertTrue(fixture.model.shareRadioDataWithFriends)
        let reads = await fixture.service.privacyReadCount()
        XCTAssertEqual(reads, 1)
    }

    func testCancelledZonesReadCannotPublishItsLateSuccessfulResponse() async {
        let fixture = Fixture()
        let started = expectation(description: "Lecture annulée suspendue")
        let gate = PrivacyResultGate<[PrivacyZone]>(onWait: { started.fulfill() })
        await fixture.service.holdNextZones(gate)
        let request = Task { await fixture.model.loadZones() }
        await fulfillment(of: [started], timeout: 1)
        request.cancel()
        await gate.resolve([Fixture.homeZone])
        await request.value
        XCTAssertFalse(fixture.model.zonesLoaded)
        XCTAssertTrue(fixture.model.zones.isEmpty)
        XCTAssertFalse(fixture.model.isLoadingZones)
    }

    func testUnchangedSaveCannotConfirmPreviouslyRevokedSharing() async {
        let fixture = Fixture()
        await fixture.model.loadPrivacy()
        XCTAssertFalse(fixture.model.canSavePrivacy)
        fixture.model.shareLiveLocationWithFriends = true
        XCTAssertTrue(fixture.model.canSavePrivacy)
        let initialSave = await fixture.model.save()
        XCTAssertTrue(initialSave)
        XCTAssertFalse(fixture.model.canSavePrivacy)
        await fixture.service.revokeSharingRemotely()

        let shouldApplySharing = await fixture.model.save()
        XCTAssertFalse(shouldApplySharing, "Unchanged local values are not a fresh server acknowledgement")
        XCTAssertFalse(fixture.model.savedConfirmation)
        let remote = try? await fixture.service.get()
        XCTAssertFalse(remote?.shareLiveLocationWithFriends ?? true)
    }

    func testSuspendedCreationPreservesServerReceiptAndDefersDismissalUntilResume() async throws {
        let fixture = Fixture()
        await fixture.model.loadZones()
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Creation pending")
        let gate = PrivacyResultGate<PrivacyZone>(onWait: { started.fulfill() })
        await fixture.service.holdNextCreate(gate)
        var dismissalCount = 0
        let task = try XCTUnwrap(request.start(
            operation: { await fixture.model.saveZone(fixture.draft, original: nil) },
            isSessionCurrent: { fixture.model.isSessionCurrent },
            apply: { saved in if saved { dismissalCount += 1 } }))
        await fulfillment(of: [started], timeout: 1)
        request.suspendDelivery()
        await gate.resolve(Fixture.otherZone)
        await task.value
        XCTAssertEqual(fixture.model.zones, [Fixture.homeZone, Fixture.otherZone])
        XCTAssertNil(fixture.model.zoneBusyId)
        XCTAssertEqual(dismissalCount, 0)
        request.resumeDelivery()
        request.resumeDelivery()
        XCTAssertEqual(dismissalCount, 1)
        let writes = await fixture.service.zoneWriteCount()
        XCTAssertEqual(writes, 1, "Resuming must never issue another POST")
    }

    func testSuspendedCreationFailureKeepsDraftAndErrorWithoutDismissing() async throws {
        let fixture = Fixture()
        await fixture.model.loadZones()
        await fixture.service.failMutations(true)
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Failing creation pending")
        let gate = PrivacyResultGate<PrivacyZone>(onWait: { started.fulfill() })
        await fixture.service.holdNextCreate(gate)
        let draft = fixture.draft
        var dismissalCount = 0
        var completedResult: Bool?
        let task = try XCTUnwrap(request.start(
            operation: { await fixture.model.saveZone(draft, original: nil) },
            isSessionCurrent: { fixture.model.isSessionCurrent },
            apply: { saved in completedResult = saved; if saved { dismissalCount += 1 } }))
        await fulfillment(of: [started], timeout: 1)
        request.suspendDelivery()
        await gate.resolve(Fixture.otherZone)
        await task.value
        XCTAssertEqual(fixture.model.zones, [Fixture.homeZone])
        XCTAssertEqual(draft, fixture.draft)
        XCTAssertNotNil(fixture.model.zoneMutationError)
        XCTAssertNil(fixture.model.zoneBusyId)
        XCTAssertNil(completedResult)
        request.resumeDelivery()
        XCTAssertEqual(completedResult, false)
        XCTAssertEqual(dismissalCount, 0)
    }

    @MainActor
    private final class Fixture {
        static let homeZone = PrivacyZone(id: "android-home", name: "Android home", latitude: 48,
            longitude: 2, radius: 500, isActive: true, hideSpeedtestsOnMap: true)
        static let otherZone = PrivacyZone(id: "new-zone", name: "Canonical zone", latitude: 49.001,
            longitude: 3.001, radius: 600, isActive: true, hideSpeedtestsOnMap: true)
        let session = PrivacySessionBox()
        let service: PrivacyServiceDouble
        let model: PrivacySettingsViewModel
        var draft: PrivacyZoneDraft {
            var value = PrivacyZoneDraft(); value.name = "New"; value.select(latitude: 49.001123, longitude: 3.001234)
            return value
        }
        init() {
            service = PrivacyServiceDouble(zones: [Self.homeZone], created: Self.otherZone)
            let session = self.session
            model = PrivacySettingsViewModel(service: service, sessionSnapshot: { session.current })
        }
    }
}

@MainActor
private final class PrivacySessionBox {
    var current: LocalAccountSession? = .init(ownerScopeId: "user:a", sessionId: "a-session")
}

private actor PrivacyResultGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private let onWait: @Sendable () -> Void
    init(onWait: @escaping @Sendable () -> Void) { self.onWait = onWait }
    func wait() async -> Value {
        await withCheckedContinuation { continuation in self.continuation = continuation; onWait() }
    }
    func resolve(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}

private actor PrivacyServiceDouble: PrivacyServicing {
    nonisolated func scoped(to session: LocalAccountSession) -> any PrivacyServicing { self }
    private var storedZones: [PrivacyZone]
    private let createdZone: PrivacyZone
    private var updateReply: PrivacyZone?
    private var preferencesFail = false
    private var zonesFail = false
    private var mutationsFail = false
    private var preferenceWrites = 0
    private var zoneWrites = 0
    private var privacyReads = 0
    private var privacyPatch: UpdatePrivacyRequest?
    private var zonesGate: PrivacyResultGate<[PrivacyZone]>?
    private var createGate: PrivacyResultGate<PrivacyZone>?
    private var privacy = SocialPrivacy(shareLiveLocationWithFriends: false, shareRadioDataWithFriends: false,
        shareSessionsWithFriends: false, sharePhotosOnFriendMap: false, shareExactMeasurements: true,
        lastSeenVisibility: .none, messageRequestPolicy: .friendsOnly)

    init(zones: [PrivacyZone], created: PrivacyZone) { storedZones = zones; createdZone = created }
    func failPreferences(_ value: Bool) { preferencesFail = value }
    func failZones(_ value: Bool) { zonesFail = value }
    func failMutations(_ value: Bool) { mutationsFail = value }
    func replaceStoredZones(_ zones: [PrivacyZone]) { storedZones = zones }
    func setUpdateReply(_ zone: PrivacyZone) { updateReply = zone }
    func holdNextZones(_ gate: PrivacyResultGate<[PrivacyZone]>) { zonesGate = gate }
    func holdNextCreate(_ gate: PrivacyResultGate<PrivacyZone>) { createGate = gate }
    func preferenceWriteCount() -> Int { preferenceWrites }
    func zoneWriteCount() -> Int { zoneWrites }
    func privacyReadCount() -> Int { privacyReads }
    func lastPrivacyPatch() -> UpdatePrivacyRequest? { privacyPatch }
    func revokeSharingRemotely() {
        privacy = SocialPrivacy(shareLiveLocationWithFriends: false, shareRadioDataWithFriends: false,
            shareSessionsWithFriends: false, sharePhotosOnFriendMap: false, shareExactMeasurements: true,
            lastSeenVisibility: privacy.lastSeenVisibility, messageRequestPolicy: privacy.messageRequestPolicy)
    }
    func get() async throws -> SocialPrivacy { privacyReads += 1; return privacy }
    func update(_ patch: UpdatePrivacyRequest) async throws -> SocialPrivacy {
        privacyPatch = patch
        privacy = SocialPrivacy(shareLiveLocationWithFriends: patch.shareLiveLocationWithFriends ?? privacy.shareLiveLocationWithFriends,
            shareRadioDataWithFriends: patch.shareRadioDataWithFriends ?? privacy.shareRadioDataWithFriends,
            shareSessionsWithFriends: patch.shareSessionsWithFriends ?? privacy.shareSessionsWithFriends,
            sharePhotosOnFriendMap: patch.sharePhotosOnFriendMap ?? privacy.sharePhotosOnFriendMap,
            shareExactMeasurements: true, lastSeenVisibility: patch.lastSeenVisibility ?? privacy.lastSeenVisibility,
            messageRequestPolicy: patch.messageRequestPolicy ?? privacy.messageRequestPolicy)
        return privacy
    }
    func preferences() async throws -> UserPreferences {
        if preferencesFail { throw APIError.transport("synthetic") }
        return UserPreferences(showHandleOnLeaderboard: true, showHypothesisSystem: false)
    }
    func updatePreferences(_ patch: UserPreferencesPatch) async throws -> UserPreferences {
        preferenceWrites += 1
        return UserPreferences(unitsSystem: patch.unitsSystem ?? .metric,
            showHandleOnLeaderboard: patch.showHandleOnLeaderboard ?? true, showHypothesisSystem: false)
    }
    func zones() async throws -> [PrivacyZone] {
        if let gate = zonesGate { zonesGate = nil; return await gate.wait() }
        if zonesFail { throw APIError.transport("synthetic") }
        return storedZones
    }
    func createZone(_ request: CreatePrivacyZoneRequest) async throws -> PrivacyZone {
        zoneWrites += 1
        if let gate = createGate {
            createGate = nil
            let value = await gate.wait()
            if mutationsFail { throw APIError.transport("synthetic") }
            return value
        }
        if mutationsFail { throw APIError.transport("synthetic") }
        return createdZone
    }
    func updateZone(_ patch: UpdatePrivacyZoneRequest) async throws -> PrivacyZone {
        zoneWrites += 1
        if mutationsFail { throw APIError.transport("synthetic") }
        return updateReply ?? storedZones[0]
    }
    func deleteZone(id: String) async throws {
        zoneWrites += 1
        if mutationsFail { throw APIError.transport("synthetic") }
    }
}

final class PrivacyZoneServiceTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    func testCRUDUsesExistingAuthenticatedContractAndTargetedFields() async throws {
        let invalidations = PrivacyMapInvalidationCounter()
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-owner")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = PrivacyService(api: APIClient(config: .test, credentials: credentials,
            session: URLSession(configuration: configuration)), invalidatePublicMap: { await invalidations.increment() })
        var methods: [String] = []
        MockURLProtocol.requestHandler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.url?.path, "/api/user/zones")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=synthetic-owner")
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                    [URLQueryItem(name: "id", value: "zone&not-another-query=1")])
            } else {
                let body = try XCTUnwrap(Self.body(request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertNil(json["userId"], "Le propriétaire est déduit de la session serveur")
                if request.httpMethod == "POST" {
                    XCTAssertEqual(json["latitude"] as? Double, 48.123456)
                    XCTAssertEqual(json["hideSpeedtestsOnMap"] as? Bool, true)
                    XCTAssertNil(json["id"])
                } else {
                    XCTAssertEqual(Set(json.keys), Set(["id", "name"]))
                }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = request.httpMethod == "DELETE" ? #"{"success":true}"# : #"{"zone":{"id":"zone","name":"Server","latitude":48.123456,"longitude":2.123456,"radius":500,"isActive":true,"hideSpeedtestsOnMap":true,"isAutoDetected":false}}"#
            return (response, Data(json.utf8))
        }
        let created = try await service.createZone(CreatePrivacyZoneRequest(name: "Home", type: "home",
            latitude: 48.123456, longitude: 2.123456, radius: 500, hideSpeedtestsOnMap: true))
        XCTAssertEqual(created.name, "Server")
        _ = try await service.updateZone(UpdatePrivacyZoneRequest(id: created.id, name: "New"))
        try await service.deleteZone(id: "zone&not-another-query=1")
        XCTAssertEqual(methods, ["POST", "PATCH", "DELETE"])
        let invalidationCount = await invalidations.count
        XCTAssertEqual(invalidationCount, 3, "Chaque CRUD confirmé purge la carte avant de rendre la main")
    }

    func testScopedServiceCannotStartAnOldMutationWithReplacementCredentials() async throws {
        LocalAccountScope.activate(userId: "privacy-synthetic-a")
        defer { LocalAccountScope.deactivate() }
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-a")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let shared = PrivacyService(api: APIClient(config: .test, credentials: credentials,
            session: URLSession(configuration: configuration)))
        let bound = shared.scoped(to: try XCTUnwrap(LocalAccountScope.sessionSnapshot()))
        // Simule le token B installé avant la publication du nouveau profil UI.
        try credentials.setAccessToken("synthetic-b")
        MockURLProtocol.requestHandler = { _ in
            XCTFail("La génération attendue doit arrêter la mutation avant tout réseau")
            throw APIError.transport("unexpected-network")
        }
        do {
            _ = try await bound.createZone(CreatePrivacyZoneRequest(name: "A", type: "home",
                latitude: 48, longitude: 2, radius: 500, hideSpeedtestsOnMap: true))
            XCTFail("La mutation de l'ancien écran doit être annulée")
        } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
    }

    func testDeletionRequiresPositiveServerAcknowledgement() async throws {
        let invalidations = PrivacyMapInvalidationCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = PrivacyService(api: APIClient(config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: URLSession(configuration: configuration)),
            invalidatePublicMap: { await invalidations.increment() })
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"success":false}"#.utf8))
        }
        do {
            try await service.deleteZone(id: "zone")
            XCTFail("Un 200 sans confirmation ne doit pas supprimer la zone locale")
        } catch APIError.decoding {} catch { XCTFail("Erreur inattendue : \(error)") }
        let invalidationCount = await invalidations.count
        XCTAssertEqual(invalidationCount, 0)
    }

    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var body = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

private actor PrivacyMapInvalidationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}


@MainActor
final class PrivacyZoneEditorRequestTests: XCTestCase {
    func testManualCoordinateRoundTripInvalidatesEarlierGPSRequest() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "GPS pending")
        let deferred = PrivacyZoneEditorDeferredValue<String>(started: started)
        var coordinate = "A"
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { true }, apply: { coordinate = $0 }))
        await fulfillment(of: [started], timeout: 1)
        request.invalidate(); coordinate = "B"
        request.invalidate(); coordinate = "A"
        deferred.resolve("old GPS")
        await task.value
        XCTAssertEqual(coordinate, "A", "A→B→A must invalidate by revision, not final coordinate equality")
    }

    func testNewerGPSRequestWinsEvenWhenOlderRequestFinishesLast() async throws {
        let request = PrivacyZoneEditorRequest()
        let firstStarted = expectation(description: "First GPS pending")
        let secondStarted = expectation(description: "Second GPS pending")
        let first = PrivacyZoneEditorDeferredValue<String>(started: firstStarted)
        let second = PrivacyZoneEditorDeferredValue<String>(started: secondStarted)
        var coordinate = "manual"
        let old = try XCTUnwrap(request.start(operation: { await first.value() },
            isSessionCurrent: { true }, apply: { coordinate = $0 }))
        await fulfillment(of: [firstStarted], timeout: 1)
        let new = try XCTUnwrap(request.start(operation: { await second.value() },
            isSessionCurrent: { true }, apply: { coordinate = $0 }))
        await fulfillment(of: [secondStarted], timeout: 1)
        second.resolve("new GPS"); await new.value
        first.resolve("old GPS"); await old.value
        XCTAssertEqual(coordinate, "new GPS")
    }

    func testClosedAndReopenedEditorRejectsPreviousPresentationCompletion() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Save pending")
        let deferred = PrivacyZoneEditorDeferredValue<Bool>(started: started)
        var dismissalCount = 0
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { true }, apply: { if $0 { dismissalCount += 1 } }))
        await fulfillment(of: [started], timeout: 1)
        request.close()
        request.open()
        deferred.resolve(true); await task.value
        XCTAssertEqual(dismissalCount, 0, "A late save must not dismiss a later presentation")
    }

    func testSessionChangeRejectsLateGPSResultWithoutApplyingAnErrorEither() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "GPS pending")
        let deferred = PrivacyZoneEditorDeferredValue<String?>(started: started)
        var sessionCurrent = true
        var callbacks = 0
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { sessionCurrent }, apply: { _ in callbacks += 1 }))
        await fulfillment(of: [started], timeout: 1)
        sessionCurrent = false
        deferred.resolve(nil); await task.value
        XCTAssertEqual(callbacks, 0)
    }

    func testTaskCancellationRejectsProviderThatStillReturnsSuccess() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "GPS pending")
        let deferred = PrivacyZoneEditorDeferredValue<String>(started: started)
        var callbacks = 0
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { true }, apply: { _ in callbacks += 1 }))
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        deferred.resolve("GPS"); await task.value
        XCTAssertEqual(callbacks, 0)
    }

    func testClosingEditorCancelsItsRunningOperation() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "GPS pending")
        let deferred = PrivacyZoneEditorDeferredValue<String>(started: started)
        var observedCancellation = false
        var callbacks = 0
        let task = try XCTUnwrap(request.start(operation: {
            let value = await deferred.value()
            observedCancellation = Task.isCancelled
            return value
        }, isSessionCurrent: { true }, apply: { _ in callbacks += 1 }))
        await fulfillment(of: [started], timeout: 1)
        request.close()
        deferred.resolve("GPS"); await task.value
        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(callbacks, 0)
    }

    func testClosedEditorOrStaleSessionCannotStartAnOperation() async {
        let request = PrivacyZoneEditorRequest()
        var reads = 0
        request.close()
        let closed = request.start(operation: { reads += 1; return true },
            isSessionCurrent: { true }, apply: { _ in XCTFail("Closed presentation") })
        if let closed { await closed.value }
        XCTAssertNil(closed)
        request.open()
        let stale = request.start(operation: { reads += 1; return true },
            isSessionCurrent: { false }, apply: { _ in XCTFail("Stale session") })
        if let stale { await stale.value }
        XCTAssertNil(stale)
        XCTAssertEqual(reads, 0)
    }

    func testRepeatedActivationPreservesRequestDuringSystemPermissionDialog() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Location permission pending")
        let deferred = PrivacyZoneEditorDeferredValue<String>(started: started)
        var observedCancellation = false
        var results: [String] = []
        let task = try XCTUnwrap(request.start(operation: {
            let value = await deferred.value()
            observedCancellation = Task.isCancelled
            return value
        }, isSessionCurrent: { true }, apply: { results.append($0) }))
        await fulfillment(of: [started], timeout: 1)
        // La phase inactive du dialogue système ne ferme pas la présentation.
        // Revenir active, même plusieurs fois, conserve la requête initiale.
        request.open()
        request.open()
        deferred.resolve("authorized GPS"); await task.value
        XCTAssertFalse(observedCancellation)
        XCTAssertEqual(results, ["authorized GPS"])
    }

    func testSuspendedCompletionIsAppliedExactlyOnceAfterResume() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Mutation pending")
        let deferred = PrivacyZoneEditorDeferredValue<Bool>(started: started)
        var results: [Bool] = []
        var wasCancelled = false
        let task = try XCTUnwrap(request.start(operation: {
            let result = await deferred.value()
            wasCancelled = Task.isCancelled
            return result
        }, isSessionCurrent: { true }, apply: { results.append($0) }))
        await fulfillment(of: [started], timeout: 1)
        request.suspendDelivery()
        deferred.resolve(true); await task.value
        XCTAssertFalse(wasCancelled, "A possible server commit must still reach the model")
        XCTAssertTrue(results.isEmpty)
        request.open()
        XCTAssertTrue(results.isEmpty, "Opening alone does not resume a deferred delivery")
        request.resumeDelivery()
        request.resumeDelivery()
        XCTAssertEqual(results, [true])
    }

    func testClosingDiscardsACompletedSuspendedMutation() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Mutation pending")
        let deferred = PrivacyZoneEditorDeferredValue<Bool>(started: started)
        var callbacks = 0
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { true }, apply: { _ in callbacks += 1 }))
        await fulfillment(of: [started], timeout: 1)
        request.suspendDelivery()
        deferred.resolve(true); await task.value
        request.close()
        request.open()
        request.resumeDelivery()
        XCTAssertEqual(callbacks, 0)
    }

    func testSessionChangeDiscardsACompletedSuspendedMutation() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Mutation pending")
        let deferred = PrivacyZoneEditorDeferredValue<Bool>(started: started)
        var sessionCurrent = true
        var callbacks = 0
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { sessionCurrent }, apply: { _ in callbacks += 1 }))
        await fulfillment(of: [started], timeout: 1)
        request.suspendDelivery()
        deferred.resolve(true); await task.value
        sessionCurrent = false
        request.resumeDelivery()
        XCTAssertEqual(callbacks, 0)
    }

    func testInvalidationDiscardsACompletedSuspendedMutation() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Mutation pending")
        let deferred = PrivacyZoneEditorDeferredValue<Bool>(started: started)
        var callbacks = 0
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { true }, apply: { _ in callbacks += 1 }))
        await fulfillment(of: [started], timeout: 1)
        request.suspendDelivery()
        deferred.resolve(true); await task.value
        request.invalidate()
        request.resumeDelivery()
        XCTAssertEqual(callbacks, 0)
    }

    func testResumeBeforeMutationCompletesPreservesPendingResult() async throws {
        let request = PrivacyZoneEditorRequest()
        let started = expectation(description: "Mutation pending")
        let deferred = PrivacyZoneEditorDeferredValue<Bool>(started: started)
        var results: [Bool] = []
        let task = try XCTUnwrap(request.start(operation: { await deferred.value() },
            isSessionCurrent: { true }, apply: { results.append($0) }))
        await fulfillment(of: [started], timeout: 1)
        request.suspendDelivery()
        request.resumeDelivery()
        deferred.resolve(true); await task.value
        XCTAssertEqual(results, [true])
    }

    func testCurrentPresentationAppliesSuccessfulResultExactlyOnce() async throws {
        let request = PrivacyZoneEditorRequest()
        var results: [String] = []
        let task = try XCTUnwrap(request.start(operation: { "GPS" },
            isSessionCurrent: { true }, apply: { results.append($0) }))
        await task.value
        XCTAssertEqual(results, ["GPS"])
    }
}

@MainActor
private final class PrivacyZoneEditorDeferredValue<Value: Sendable> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func value() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func resolve(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}
