import XCTest
import CoreLocation
@testable import SignalQuest

@MainActor
final class LivePresenceServiceTests: XCTestCase {
    private func fixture(
        now: @escaping @Sendable () -> Date = { Date() },
        protocolClass: AnyClass = MockURLProtocol.self,
        prepareLocation: (LocationService) -> Void = { _ in }
    ) throws -> (LivePresenceService, CredentialStore, PresenceSettingsGate, PresenceGPSDriver, PresenceHTTPRecorder) {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-presence-a")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let session = URLSession(configuration: config)
        let api = APIClient(config: .test, credentials: credentials, session: session)
        let recorder = PresenceHTTPRecorder()
        MockURLProtocol.requestHandler = { request in try recorder.respond(request) }
        let driver = PresenceGPSDriver()
        let location = LocationService(manager: driver, makeOneShotManager: { driver }, now: now)
        prepareLocation(location)
        let gate = PresenceSettingsGate()
        let service = LivePresenceService(api: api, location: location, networkPath: NetworkPathMonitor(),
            privacy: PrivacyService(api: api),
            preferences: LivePresencePreferences(loadMode: { .mapOpenOnly }, loadStatus: { .online },
                loadCustomStatus: { nil }, saveMode: { _ in }, saveStatus: { _, _ in }),
            settingsLoader: { await gate.load($0) })
        service.setAppActive(false)
        addTeardownBlock {
            credentials.clearAccessToken()
            session.invalidateAndCancel()
        }
        return (service, credentials, gate, driver, recorder)
    }

    private func response(sharing: Bool, status: SocialPresenceStatus = .online, custom: String? = nil) -> LivePresenceSettingsResponse {
        LivePresenceSettingsResponse(settings: SocialPrivacy(shareLiveLocationWithFriends: sharing,
            shareRadioDataWithFriends: sharing, shareSessionsWithFriends: false, sharePhotosOnFriendMap: false,
            shareExactMeasurements: true, lastSeenVisibility: .none, messageRequestPolicy: .noOne),
            presence: OwnPresence(status: status, customStatus: custom))
    }

    func testOldAccountRefreshCannotReenableSharingAfterNewAccountSettings() async throws {
        let (service, credentials, gate, gps, recorder) = try fixture()
        defer { credentials.clearAccessToken(); service.stopForSignOut(); MockURLProtocol.requestHandler = nil }
        let old = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(1)
        service.stopForSignOut()
        try credentials.setAccessToken("synthetic-presence-b")
        let current = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(2)
        await gate.resolve(1, response(sharing: false, status: .invisible, custom: "B"))
        await current.value
        await gate.resolve(0, response(sharing: true, custom: "A"))
        await old.value
        XCTAssertEqual(service.status, .invisible)
        XCTAssertEqual(service.customStatus, "B")
        let sent = expectation(description: "B heartbeat")
        recorder.onRequest = { sent.fulfill() }
        service.mapDidAppear()
        service.setAppActive(true)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(gps.requests, 0)
        XCTAssertTrue(recorder.bodies.allSatisfy { $0["location"] == nil })
        XCTAssertTrue(recorder.cookies.allSatisfy { $0 == "auth_token=synthetic-presence-b" })
    }

    func testOldRefreshCannotOverrideConfirmedLocalPrivacyOrPresence() async throws {
        let (service, credentials, gate, gps, recorder) = try fixture()
        defer { credentials.clearAccessToken(); service.stopForSignOut(); MockURLProtocol.requestHandler = nil }
        let initial = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(1)
        await gate.resolve(0, response(sharing: true))
        await initial.value
        let old = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(2)
        service.applySharingSettings(shareLocation: false, shareRadio: false,
                                     expectedSessionID: credentials.snapshot().sessionID)
        service.setPresence(status: .invisible, customStatus: "new choice")
        await gate.resolve(1, response(sharing: true, custom: "old choice"))
        await old.value
        XCTAssertEqual(service.status, .invisible)
        XCTAssertEqual(service.customStatus, "new choice")
        let sent = expectation(description: "no coordinate heartbeat")
        recorder.onRequest = { sent.fulfill() }
        service.mapDidAppear()
        service.setAppActive(true)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(gps.requests, 0)
        XCTAssertTrue(recorder.bodies.allSatisfy { $0["location"] == nil })
    }

    func testPartialInitialSettingsCannotPublishWithAnUnknownPresencePreference() async throws {
        let (service, credentials, gate, gps, recorder) = try fixture()
        defer { credentials.clearAccessToken(); service.stopForSignOut(); MockURLProtocol.requestHandler = nil }
        let loading = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(1)
        await gate.resolve(0, LivePresenceSettingsResponse(settings: response(sharing: true).settings, presence: nil))
        await loading.value
        service.mapDidAppear()
        service.setAppActive(true)
        XCTAssertFalse(service.isBroadcasting)
        XCTAssertEqual(gps.requests, 0)
        XCTAssertTrue(recorder.bodies.isEmpty)
    }


    func testPartialSettingsCannotPromoteLocalStatusThroughCustomStatusEditing() async throws {
        let (service, credentials, gate, gps, recorder) = try fixture()
        defer { credentials.clearAccessToken(); service.stopForSignOut(); MockURLProtocol.requestHandler = nil }
        let initial = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(1)
        await gate.resolve(0, LivePresenceSettingsResponse(settings: response(sharing: false).settings, presence: nil))
        await initial.value
        let premature = expectation(description: "Unknown presence must not emit a heartbeat")
        premature.isInverted = true
        recorder.onRequest = {
            recorder.onRequest = nil
            premature.fulfill()
        }
        service.mapDidAppear()
        service.setAppActive(true)
        // La vue réutilise le statut local quand seul son texte est modifié.
        service.setPresence(status: service.status, customStatus: "draft before server status")
        XCTAssertFalse(service.presenceLoaded)
        XCTAssertFalse(service.isBroadcasting)
        XCTAssertNil(service.customStatus, "L'édition refusée ne doit pas devenir une préférence locale")
        await fulfillment(of: [premature], timeout: 0.15)
        XCTAssertTrue(recorder.bodies.isEmpty)
        XCTAssertEqual(gps.requests, 0)
        service.setAppActive(false)
        recorder.onRequest = nil

        // Un nouveau chargement confirme le vrai statut : l'édition redevient
        // possible et conserve invisible au lieu d'émettre online.
        let retry = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(2)
        await gate.resolve(1, response(sharing: false, status: .invisible, custom: "server status"))
        await retry.value
        XCTAssertTrue(service.presenceLoaded)
        XCTAssertEqual(service.status, .invisible)
        XCTAssertEqual(service.customStatus, "server status")
        service.setPresence(status: service.status, customStatus: "confirmed edit")
        XCTAssertEqual(service.status, .invisible)
        XCTAssertEqual(service.customStatus, "confirmed edit")
        let published = expectation(description: "Loaded owner can edit and publish presence")
        recorder.onRequest = {
            recorder.onRequest = nil
            published.fulfill()
        }
        service.setAppActive(true)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertFalse(recorder.bodies.isEmpty)
        XCTAssertTrue(recorder.bodies.allSatisfy { $0["status"] as? String == "invisible" })
        XCTAssertTrue(recorder.bodies.allSatisfy { $0["customStatus"] as? String == "confirmed edit" })
        XCTAssertTrue(recorder.bodies.allSatisfy { $0["location"] == nil })
    }

    func testOldAccountSaveCannotApplyToNewSession() async throws {
        let (service, credentials, gate, gps, recorder) = try fixture()
        defer { credentials.clearAccessToken(); service.stopForSignOut(); MockURLProtocol.requestHandler = nil }
        let ownerA = credentials.snapshot().sessionID
        try credentials.setAccessToken("synthetic-presence-b")
        let loading = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(1)
        await gate.resolve(0, response(sharing: false))
        await loading.value
        service.applySharingSettings(shareLocation: true, shareRadio: true, expectedSessionID: ownerA)
        let sent = expectation(description: "B without old settings")
        recorder.onRequest = { sent.fulfill() }
        service.mapDidAppear()
        service.setAppActive(true)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(gps.requests, 0)
        XCTAssertTrue(recorder.bodies.allSatisfy { $0["location"] == nil })
    }

    func testSignOutInvalidatesAnInFlightPartialRefresh() async throws {
        let (service, credentials, gate, gps, recorder) = try fixture()
        defer { credentials.clearAccessToken(); service.stopForSignOut(); MockURLProtocol.requestHandler = nil }
        let loading = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(1)
        service.stopForSignOut()
        credentials.clearAccessToken()
        await gate.resolve(0, LivePresenceSettingsResponse(settings: response(sharing: true).settings, presence: nil))
        await loading.value
        service.setAppActive(true)
        XCTAssertFalse(service.isBroadcasting)
        XCTAssertEqual(gps.requests, 0)
        XCTAssertTrue(recorder.bodies.isEmpty)
    }


    func testPresence503RetryRechecksRevokedGPSPermission() async throws {
        // Le témoin prouve que le même service émet et rejoue bien la position.
        try await checkPresenceRetry(.unavailable, invalidateFix: false)
        try await checkPresenceRetry(.unavailable, invalidateFix: true)
    }

    func testPresence401RefreshCannotReplayAFixThatExpiredWhileSuspended() async throws {
        try await checkPresenceRetry(.refresh, invalidateFix: false)
        try await checkPresenceRetry(.refresh, invalidateFix: true)
    }

    private func checkPresenceRetry(_ mode: PresenceRetryTransport.Mode, invalidateFix: Bool) async throws {
        let clock = PresenceRetryClock(Date(timeIntervalSince1970: 2_000_000_000.123))
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35),
            altitude: 0, horizontalAccuracy: 12, verticalAccuracy: -1, timestamp: clock.value)
        let suspended = expectation(description: "HTTP boundary before retry: \(mode), invalid=\(invalidateFix)")
        let rechecked = expectation(description: "Service validates GPS again")
        let replayed = expectation(description: "Second coordinate POST")
        replayed.isInverted = invalidateFix
        let transport = PresenceRetryTransport(mode: mode, onSuspended: { suspended.fulfill() },
            onReplay: { replayed.fulfill() })
        PresenceRetryURLProtocol.install { try await transport.respond($0) }
        let (service, credentials, gate, gps, _) = try fixture(now: { clock.value },
            protocolClass: PresenceRetryURLProtocol.self, prepareLocation: { $0.receiveLocations([fix]) })
        defer {
            gps.onAuthorizationRead = nil
            transport.release()
            credentials.clearAccessToken()
            service.stopForSignOut()
            PresenceRetryURLProtocol.install(nil)
            MockURLProtocol.requestHandler = nil
        }
        let owner = credentials.snapshot().sessionID
        let loading = Task { await service.refreshSharingSettings() }
        await gate.waitForRequests(1)
        // Le canal radio est désactivé : le test ne dépend pas du réseau du Mac.
        await gate.resolve(0, LivePresenceSettingsResponse(settings: SocialPrivacy(
            shareLiveLocationWithFriends: true, shareRadioDataWithFriends: false,
            shareSessionsWithFriends: false, sharePhotosOnFriendMap: false,
            shareExactMeasurements: true, lastSeenVisibility: .none, messageRequestPolicy: .noOne),
            presence: OwnPresence(status: .invisible, customStatus: "synthetic")))
        await loading.value
        service.mapDidAppear()
        service.setAppActive(true)
        await fulfillment(of: [suspended], timeout: 2)
        XCTAssertEqual(transport.coordinateBodies.count, 1, "Le vrai service doit avoir envoyé un premier fix")
        XCTAssertTrue(service.isBroadcasting)
        if invalidateFix {
            switch mode {
            case .unavailable: gps.authorizationStatus = .denied
            case .refresh: clock.advance(LocationService.defaultMaxLocationAge + 1)
            }
        }
        // Le getter est consulté par LocationService.isUsable, appelé depuis la
        // closure validateBeforeSend construite par LivePresenceService.
        // Le premier POST est déjà passé et aucun nouveau tick n'est planifié
        // pendant cette fenêtre (cadence initiale 20 s).
        gps.onAuthorizationRead = {
            gps.onAuthorizationRead = nil
            rechecked.fulfill()
        }
        transport.release()
        await fulfillment(of: [rechecked], timeout: 2)
        if invalidateFix {
            // Fenêtre négative bornée après preuve de la revalidation ; aucun
            // sleep GPS, refresh, backoff ou délai de 20 s n'est attendu.
            await fulfillment(of: [replayed], timeout: 0.25)
        } else {
            await fulfillment(of: [replayed], timeout: 2)
        }
        XCTAssertEqual(transport.coordinateBodies.count, invalidateFix ? 1 : 2)
        XCTAssertEqual(transport.refreshRequests, mode == .refresh ? 1 : 0)
        XCTAssertEqual(credentials.snapshot().sessionID, owner, "Le refus ne doit pas venir d'un changement de compte")
        XCTAssertEqual(service.status, .invisible)
        XCTAssertTrue(service.isBroadcasting, "Le test ne doit pas masquer le retry par un arrêt de boucle")
        if mode == .refresh {
            XCTAssertEqual(credentials.accessToken(), "synthetic-presence-refreshed",
                "Le refresh doit finir ; seule la réémission de coordonnées est refusée")
        }
        for body in transport.coordinateBodies {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let point = try XCTUnwrap(json["location"] as? [String: Any])
            XCTAssertEqual(point["observedAt"] as? String, ObservationTimestamp.string(fix.timestamp))
            XCTAssertEqual(point["lat"] as? Double, fix.coordinate.latitude)
            XCTAssertEqual(point["lng"] as? Double, fix.coordinate.longitude)
            XCTAssertEqual(json["status"] as? String, "invisible")
        }
    }

    func testClearingCustomStatusIsExplicitButGoingOfflinePreservesIt() throws {
        let online = try JSONEncoder.signalQuest.encode(PresencePublishRequest(status: "invisible", customStatus: nil, location: nil))
        let onlineJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: online) as? [String: Any])
        XCTAssertTrue(onlineJSON["customStatus"] is NSNull)
        let offline = try JSONEncoder.signalQuest.encode(PresencePublishRequest(status: "offline", customStatus: nil, location: nil))
        let offlineJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: offline) as? [String: Any])
        XCTAssertNil(offlineJSON["customStatus"])
    }

    func testPresenceAndRadioEncodingPreserveIndependentCaptureTimes() throws {
        let observed = Date(timeIntervalSince1970: 1_700_000_000.123)
        let radio = Date(timeIntervalSince1970: 1_700_000_005.456)
        let location = PresenceLocationPayload(lat: 48, lng: 2, accuracy: 200, heading: nil, speed: nil, observedAt: observed)
        let presenceData = try JSONEncoder.signalQuest.encode(PresencePublishRequest(status: "online", customStatus: nil, location: location))
        let presenceJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: presenceData) as? [String: Any])
        XCTAssertEqual((presenceJSON["location"] as? [String: Any])?["observedAt"] as? String, "2023-11-14T22:13:20.123Z")
        let radioData = try JSONEncoder.signalQuest.encode(RadioSnapshotPublishRequest(technology: "LTE", operator: nil,
            lat: 48, lng: 2, observedAt: radio, locationObservedAt: observed))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: radioData) as? [String: Any])
        XCTAssertEqual(json["observedAt"] as? String, "2023-11-14T22:13:25.456Z")
        XCTAssertEqual(json["locationObservedAt"] as? String, "2023-11-14T22:13:20.123Z")
    }
}

private actor PresenceSettingsGate {
    private var next = 0
    private var pending: [Int: CheckedContinuation<LivePresenceSettingsResponse, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func load(_ owner: UUID) async -> LivePresenceSettingsResponse {
        let id = next
        next += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            let ready = waiters.filter { next >= $0.0 }
            waiters.removeAll { next >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if next >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func resolve(_ id: Int, _ value: LivePresenceSettingsResponse) {
        pending.removeValue(forKey: id)?.resume(returning: value)
    }
}

@MainActor
private final class PresenceGPSDriver: LocationManagerDriving {
    weak var delegate: (any CLLocationManagerDelegate)?
    private var storedAuthorization: CLAuthorizationStatus = .authorizedWhenInUse
    var onAuthorizationRead: (() -> Void)?
    var authorizationStatus: CLAuthorizationStatus {
        get { onAuthorizationRead?(); return storedAuthorization }
        set { storedAuthorization = newValue }
    }
    var desiredAccuracy: CLLocationAccuracy = 100
    var distanceFilter: CLLocationDistance = 0
    var allowsBackgroundLocationUpdates = false
    var pausesLocationUpdatesAutomatically = true
    var headingFilter: CLLocationDegrees = 0
    var requests = 0
    func requestWhenInUseAuthorization() {}
    func requestLocation() { requests += 1 }
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
}

private final class PresenceHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, [String: Any])] = []
    private var callback: (@Sendable () -> Void)?
    var onRequest: (@Sendable () -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    var bodies: [[String: Any]] { lock.withLock { recorded.map(\.1) } }
    var cookies: [String] { lock.withLock { recorded.map(\.0) } }
    fileprivate static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
    func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
        let callback = lock.withLock {
            recorded.append((request.value(forHTTPHeaderField: "Cookie") ?? "", body))
            return self.callback
        }
        callback?()
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"ok\":true}".utf8))
    }
}


private final class PresenceRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(_ date: Date) { instant = date }
    var value: Date { lock.withLock { instant } }
    func advance(_ interval: TimeInterval) { lock.withLock { instant.addTimeInterval(interval) } }
}

/// Gate sans sémaphore : le protocole suspend une Task et laisse le MainActor
/// libre pour révoquer la permission ou avancer l'horloge.
private final class PresenceRetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if opened { return true }
                waiting = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func open() {
        let continuation = lock.withLock {
            opened = true
            let result = waiting
            waiting = nil
            return result
        }
        continuation?.resume()
    }
}

private final class PresenceRetryTransport: @unchecked Sendable {
    enum Mode: Equatable { case unavailable, refresh }
    private let mode: Mode
    private let gate = PresenceRetryGate()
    private let lock = NSLock()
    private var coordinates: [Data] = []
    private var refreshCount = 0
    private let onSuspended: @Sendable () -> Void
    private let onReplay: @Sendable () -> Void
    init(mode: Mode, onSuspended: @escaping @Sendable () -> Void, onReplay: @escaping @Sendable () -> Void) {
        self.mode = mode
        self.onSuspended = onSuspended
        self.onReplay = onReplay
    }
    var coordinateBodies: [Data] { lock.withLock { coordinates } }
    var refreshRequests: Int { lock.withLock { refreshCount } }
    func release() { gate.open() }
    func respond(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        if url.path == "/api/auth/refresh" {
            lock.withLock { refreshCount += 1 }
            onSuspended()
            await gate.wait()
            return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=synthetic-presence-refreshed; Path=/; HttpOnly"])),
                Data(#"{"ok":true}"#.utf8))
        }
        guard url.path == "/api/social/presence" else { throw URLError(.unsupportedURL) }
        let body = try PresenceHTTPRecorder.body(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        guard json["location"] != nil else { throw URLError(.badServerResponse) }
        let count = lock.withLock { coordinates.append(body); return coordinates.count }
        if count == 1 {
            switch mode {
            case .unavailable:
                // Révocation à la frontière de la réponse : le premier POST est
                // arrivé, puis le transport délivre 503 et le vrai backoff 0.
                onSuspended()
                await gate.wait()
                return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                    headerFields: ["Retry-After": "0"])), Data(#"{"error":"unavailable"}"#.utf8))
            case .refresh:
                return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil,
                    headerFields: nil)), Data(#"{"error":"expired"}"#.utf8))
            }
        }
        onReplay()
        return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)),
            Data(#"{"ok":true,"locationAccepted":true}"#.utf8))
    }
}

/// Variante async locale au fichier ; ne change pas le MockURLProtocol partagé.
private final class PresenceRetryURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    private let stateLock = NSLock()
    private var stopped = false
    static func install(_ value: Handler?) { handlerLock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let respond = Self.handlerLock.withLock { Self.handler }
        Task {
            do {
                guard let respond else { throw URLError(.unsupportedURL) }
                let (response, data) = try await respond(request)
                guard !stateLock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !stateLock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}
