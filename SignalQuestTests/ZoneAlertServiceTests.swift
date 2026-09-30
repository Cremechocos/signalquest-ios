import XCTest
@testable import SignalQuest

/// Plan 3, vague 2 : alertes de panne près de ses lieux. Le serveur refuse
/// toute clé inconnue : chaque changement n'envoie que la sienne.
final class ZoneAlertServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testEachChangeSendsOnlyItsOwnKeys() throws {
        XCTAssertEqual(try json(.notifyDegraded(true)), ["notifyDegraded": true])
        XCTAssertEqual(try json(.radius(3_000)), ["notificationRadiusMeters": 3_000])
        XCTAssertEqual(try json(.maxPerDay(8)), ["maxNotificationsPerDay": 8])
        XCTAssertEqual(try json(.watchedOperators(["ORANGE", "FREE"])), ["watchedOperators": ["ORANGE", "FREE"]])
        XCTAssertEqual(try json(.quietHours(start: 22, end: 7)), ["quietHoursStart": 22, "quietHoursEnd": 7])
        XCTAssertEqual(try json(.quietHoursOff), ["quietHoursStart": NSNull(), "quietHoursEnd": NSNull()],
                       "Couper les heures calmes les efface par un null explicite")
    }

    func testChangeShowsBeforeTheServerAnswers() {
        let preferences = ZoneAlertSettings.demo.preferences
        XCTAssertEqual(ZoneAlertChange.radius(1_000).applied(to: preferences).notificationRadiusMeters, 1_000)
        let quiet = ZoneAlertChange.quietHoursOff.applied(to: preferences)
        XCTAssertNil(quiet.quietHoursStart)
        XCTAssertNil(quiet.quietHoursEnd)
        XCTAssertEqual(quiet.notifyAntennaDown, preferences.notifyAntennaDown)
    }

    func testServerRowIsReadAndTheChangeIsPut() async throws {
        var methods: [String?] = []
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/user/zones/preferences")
            methods.append(request.httpMethod)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            // La ligne Prisma complète : les champs en plus sont ignorés.
            return (response, Data(#"""
            {"preferences":{"id":"p1","userId":"u1","notifyAntennaDown":true,"notifyMaintenance":false,
             "notifyNewAntenna":false,"notifyUpgrade":false,"notifyDegraded":false,"autoLearnZones":false,
             "minConfidence":50,"quietHoursStart":null,"quietHoursEnd":null,"maxNotificationsPerDay":5,
             "notificationRadiusMeters":5000,"notificationCountToday":0,"lastNotificationAt":null,
             "watchedOperators":["SFR"],"createdAt":"2026-09-30T10:00:00.000Z","updatedAt":"2026-09-30T10:00:00.000Z"},
             "capabilities":{"supportedOperators":["SFR","BOUYGUES","ORANGE","FREE"],"futureReadyOperators":[],
             "activationPolicy":"confirmation_required","notificationRadiusOptionsMeters":[1000,3000,5000,10000]}}
            """#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("zone-alert-access-token")
        let service = ZoneAlertService(api: APIClient(
            config: .test, credentials: credentials, session: URLSession(configuration: configuration)
        ))

        let settings = try await service.settings()
        XCTAssertEqual(settings.preferences.watchedOperators, ["SFR"])
        XCTAssertNil(settings.preferences.quietHoursStart)
        XCTAssertEqual(settings.capabilities.notificationRadiusOptionsMeters, [1_000, 3_000, 5_000, 10_000])
        _ = try await service.apply(.notifyDegraded(true), to: settings)
        XCTAssertEqual(methods, ["GET", "PUT"])
    }

    func testHourLabelFollowsTheLanguage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(ZoneAlertSettingsView.hourLabel(22, calendar: calendar, locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "\u{202F}", with: " "), "22 h")
        XCTAssertTrue(ZoneAlertSettingsView.hourLabel(22, calendar: calendar, locale: Locale(identifier: "en_US")).contains("10"))
    }

    private func json(_ change: ZoneAlertChange) throws -> NSDictionary {
        let data = try JSONEncoder().encode(change)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}
