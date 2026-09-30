import XCTest
@testable import SignalQuest

/// Historique de consultation : sites, lieux et profils, local et par compte
/// (plan 3, vague 1).
final class RecentlyViewedStoreTests: XCTestCase {
    private let alice = "user:" + String(repeating: "a", count: 64)
    private let bruno = "user:" + String(repeating: "b", count: 64)
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RecentlyViewedStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func record(_ item: RecentlyViewedStore.Item, as owner: String? = nil) {
        RecentlyViewedStore.record(item, ownerScopeId: owner ?? alice, defaults: defaults)
    }

    private func items(of owner: String? = nil) -> [RecentlyViewedStore.Item] {
        RecentlyViewedStore.items(ownerScopeId: owner ?? alice, defaults: defaults)
    }

    private func place(_ id: String) -> RecentlyViewedStore.Item {
        .place(PlaceResult(id: id, name: "Lieu \(id)", subtitle: nil, latitude: 45.76, longitude: 4.83))
    }

    func testMostRecentFirstWithoutDuplicates() {
        record(place("lyon"))
        record(.profile(id: "u1", name: "Camille", handle: "camille", avatarURL: nil))
        record(place("lyon"))
        XCTAssertEqual(items().map(\.id), ["place:lyon", "profile:u1"])
    }

    func testKeepsTwentyOfEachKind() {
        for index in 0..<25 { record(place("p\(index)")) }
        record(.profile(id: "u1", name: "Camille", handle: nil, avatarURL: nil))
        for index in 25..<30 { record(place("p\(index)")) }
        let list = items()
        XCTAssertEqual(list.filter { $0.kind == .place }.count, RecentlyViewedStore.maxPerKind)
        XCTAssertEqual(list.first?.targetId, "p29")
        XCTAssertTrue(list.contains { $0.id == "profile:u1" }, "Une série de lieux ne doit pas chasser les profils")
    }

    func testSiteRoundTripReopensTheSameSheet() throws {
        let site = AntennaSite(
            id: "anfr-123", siteId: "37199", anfrCode: "0692123456",
            latitude: 45.75, longitude: 4.84, operators: ["ORANGE", "FREE"],
            technologies: ["4G", "5G"], bands: [700], azimuths: [120],
            sharingType: nil, crozonLeader: nil, address: "40 avenue Leclerc, Lyon",
            height: 30, owner: "Orange"
        )
        record(.site(site, market: "FR"))
        let stored = try XCTUnwrap(items().first)
        XCTAssertEqual(stored.market, "FR")
        let reopened = try XCTUnwrap(stored.antennaSite)
        XCTAssertEqual(reopened.id, site.id)
        XCTAssertEqual(reopened.siteId, "37199")
        XCTAssertEqual(reopened.anfrCode, "0692123456")
        XCTAssertEqual(reopened.address, "40 avenue Leclerc, Lyon")
        XCTAssertEqual(reopened.operators, ["ORANGE", "FREE"])
        XCTAssertEqual(reopened.technologies, site.technologies)
        XCTAssertEqual(reopened.latitude, 45.75)
        XCTAssertNil(stored.placeResult)
    }

    func testSiteWithoutAddressStaysUnnamedForTheScreen() throws {
        let site = AntennaSite(
            id: "s1", siteId: nil, latitude: nil, longitude: nil, operators: [],
            technologies: [], bands: [], azimuths: [], sharingType: nil,
            crozonLeader: nil, address: nil, height: nil, owner: nil
        )
        record(.site(site, market: "FR"))
        let stored = try XCTUnwrap(items().first)
        XCTAssertEqual(stored.title, "")
        XCTAssertNil(stored.antennaSite?.address)
    }

    func testPlaceRoundTrip() throws {
        record(.place(PlaceResult(id: "place-1", name: "Lyon", subtitle: "Rhône, France", latitude: 45.76, longitude: 4.83)))
        let reopened = try XCTUnwrap(items().first?.placeResult)
        XCTAssertEqual(reopened, PlaceResult(id: "place-1", name: "Lyon", subtitle: "Rhône, France", latitude: 45.76, longitude: 4.83))
    }

    func testClearOnlyTouchesTheKindsOfTheScreen() {
        record(place("lyon"))
        record(.profile(id: "u1", name: "Camille", handle: nil, avatarURL: nil))
        RecentlyViewedStore.clear([.site, .place], ownerScopeId: alice, defaults: defaults)
        XCTAssertEqual(items().map(\.id), ["profile:u1"])
        RecentlyViewedStore.remove(.profile, targetId: "u1", ownerScopeId: alice, defaults: defaults)
        XCTAssertTrue(items().isEmpty)
    }

    func testHistoryBelongsToOneAccountAndIsPurgedAtLogout() {
        record(place("lyon"))
        record(place("paris"), as: "guest")
        XCTAssertTrue(items(of: bruno).isEmpty)
        RecentlyViewedStore.purge(ownerScopeId: alice, defaults: defaults)
        XCTAssertTrue(items().isEmpty)
        XCTAssertEqual(items(of: "guest").map(\.targetId), ["paris"], "Un invité garde son historique")
    }

    func testEmptyIdentifierIsIgnoredAndChangesAreAnnounced() {
        record(.profile(id: "", name: "?", handle: nil, avatarURL: nil))
        XCTAssertTrue(items().isEmpty)
        let announced = expectation(forNotification: RecentlyViewedStore.didChange, object: nil)
        record(place("lyon"))
        wait(for: [announced], timeout: 1)
    }
}
