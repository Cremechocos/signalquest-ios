import CoreLocation
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

/// Accueil modulable : préréglages, retouches et mémoire par compte.
final class HomeLayoutTests: XCTestCase {
    private let alice = "user:" + String(repeating: "a", count: 64)
    private let bruno = "user:" + String(repeating: "b", count: 64)
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HomeLayoutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultIsTheCommunityPresetWithTwoSmallSideBySide() {
        let layout = HomeLayout.default
        XCTAssertEqual(layout.matchingPreset, .community)
        XCTAssertEqual(layout.entries.first?.module, .network, "« Mon réseau » ouvre l'accueil")
        let rows = layout.rows(pairingSmall: true)
        XCTAssertEqual(rows.map { $0.map(\.module) }[2], [.latestTest, .week])
        XCTAssertTrue(layout.rows(pairingSmall: false).allSatisfy { $0.count == 1 },
                      "Aux grandes tailles de texte, chaque module prend la pleine largeur")
    }

    /// Seuls les chiffres collés à un « G » comptent comme génération.
    @MainActor
    func testHighestGenerationReadsOnlyDigitsAttachedToG() {
        XCTAssertEqual(SignalQuestHomeView.highestGeneration(["4G", "5G"]), "5G")
        XCTAssertEqual(SignalQuestHomeView.highestGeneration(["5G 3500"]), "5G")
        XCTAssertEqual(SignalQuestHomeView.highestGeneration(["2G/3G"]), "3G")
        XCTAssertEqual(SignalQuestHomeView.highestGeneration(["4g+5g"]), "5G")
        XCTAssertNil(SignalQuestHomeView.highestGeneration(["LTE", "3500"]))
        XCTAssertNil(SignalQuestHomeView.highestGeneration([]))
    }

    func testLoneSmallTakesTheFullRow() {
        var layout = HomeLayout.default
        layout.remove(.week)
        XCTAssertTrue(layout.rows(pairingSmall: true).allSatisfy { $0.count == 1 })
    }

    func testEditingKeepsEveryModuleOnceAndInASupportedSize() {
        var layout = HomeLayout.preset(.essential)
        layout.add(.week)
        layout.add(.week)
        XCTAssertEqual(layout.entries.filter { $0.module == .week }.count, 1)
        layout.toggleSize(.week)
        XCTAssertEqual(layout.entries.last?.size, .small)
        layout.toggleSize(.outages)
        XCTAssertEqual(layout.entries[1].size, .large, "Les pannes n'existent qu'en Large")
        layout.move(.week, by: -10)
        XCTAssertEqual(layout.entries.first?.module, .week)
        layout.move(.week, by: 1)
        XCTAssertEqual(layout.entries.map(\.module), [.network, .week, .outages, .latestTest])
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(layout.entries.map(\.module), [.week, .outages, .latestTest, .network])
        layout.remove(.network)
        XCTAssertTrue(layout.available.contains(.network), "Un module retiré revient dans « À ajouter »")
        XCTAssertNil(layout.matchingPreset)
    }

    func testEachAccountKeepsItsOwnHome() {
        HomeLayoutStore.save(.preset(.field), ownerScopeId: alice, defaults: defaults)
        XCTAssertEqual(HomeLayoutStore.layout(ownerScopeId: alice, defaults: defaults), .preset(.field))
        XCTAssertEqual(HomeLayoutStore.layout(ownerScopeId: bruno, defaults: defaults), .default)
        HomeLayoutStore.save(.default, ownerScopeId: alice, defaults: defaults)
        XCTAssertEqual(HomeLayoutStore.layout(ownerScopeId: alice, defaults: defaults), .default)
    }

    func testUnknownOrDuplicatedModulesAreDroppedNotTheWholeHome() throws {
        let json = #"{"version":2,"entries":[{"module":"radar","size":"large"},{"module":"week","size":"small"},{"module":"outages","size":"small"},{"module":"week","size":"large"}]}"#
        let layout = try JSONDecoder().decode(HomeLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.entries, [
            HomeModuleEntry(module: .week, size: .small),
            HomeModuleEntry(module: .outages, size: .large),
        ])
        let roundTrip = try JSONDecoder().decode(HomeLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(roundTrip, layout)
    }
}

/// Module Communauté de l'Accueil : les derniers posts des autres membres,
/// chacun résumé par le titre de sa carte du fil et une ligne de texte.
final class HomeFeedPreviewTests: XCTestCase {
    private func item(_ id: String, kind: String = "post", text: String = "Bonjour", mine: Bool? = nil) -> UnifiedSocialFeedItem {
        let isMine = mine.map { #","isMine":\#($0)"# } ?? ""
        let raw = #"{"id":"\#(id)","kind":"\#(kind)","author":{"id":"a-\#(id)","name":"Camille"},"text":"\#(text)"\#(isMine)}"#
        return try! JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(raw.utf8))
    }

    func testRowReadsLikeTheFeedCard() {
        let speedtest = HomeFeedPreview(item: item("1", kind: "speedtest", text: "412 Mb/s à Paris"))
        XCTAssertEqual(speedtest.symbol, "speedometer")
        XCTAssertEqual(speedtest.header, "Camille · \(String(localized: "Test de débit"))")
        XCTAssertEqual(speedtest.line, "412 Mb/s à Paris")

        let photo = HomeFeedPreview(item: item("2", kind: "antenna_photo"))
        XCTAssertEqual(photo.symbol, "camera")
        XCTAssertEqual(photo.header, "Camille · \(String(localized: "Photo d’un support"))")

        // Une publication ordinaire n'a pas de type ; son texte tient sur une ligne.
        let post = HomeFeedPreview(item: item("3", text: "Premi\\u00e8re ligne\\nseconde"))
        XCTAssertEqual(post.header, "Camille")
        XCTAssertEqual(post.line, "Première ligne seconde")
        XCTAssertNil(HomeFeedPreview(item: item("4", text: "  ")).line)
    }

    func testOnlyOtherMembersPostsAreShownThreeAtMost() {
        let items = [item("mine", mine: true), item("a"), item("b", mine: false), item("c"), item("d")]
        XCTAssertEqual(HomeFeedPreview.others(in: items).map(\.id), ["a", "b", "c"])
    }
}

/// E3 (audit du 21/11) : l'Accueil demande les sites prévus d'un cadre qui couvre ses 5 km, à une
/// adresse stable d'une position voisine à l'autre, au lieu de la liste du marché entier.
final class HomeEvolutionsBoundsTests: XCTestCase {
    @MainActor
    func testEvolutionsAskForABoxCoveringFiveKilometresAtAStableAddress() {
        let roanne = CLLocationCoordinate2D(latitude: 46.0368, longitude: 4.0726)
        let box = SignalQuestHomeView.evolutionBounds(around: roanne)
        let metresPerDegree = 111_320.0, cosLat = cos(roanne.latitude * .pi / 180)
        XCTAssertGreaterThanOrEqual((box.north - roanne.latitude) * metresPerDegree, 5_000)
        XCTAssertGreaterThanOrEqual((roanne.latitude - box.south) * metresPerDegree, 5_000)
        XCTAssertGreaterThanOrEqual((box.east - roanne.longitude) * metresPerDegree * cosLat, 5_000)
        XCTAssertGreaterThanOrEqual((roanne.longitude - box.west) * metresPerDegree * cosLat, 5_000)
        XCTAssertLessThan((box.north - box.south) * metresPerDegree, 14_000, "un cadre, pas le marché")
        // 300 m plus loin, dans le même centième de degré : même cadre, donc même cache.
        XCTAssertEqual(SignalQuestHomeView.evolutionBounds(around: CLLocationCoordinate2D(latitude: 46.0395, longitude: 4.0741)), box)
        XCTAssertEqual(box.north, (box.north * 10_000).rounded() / 10_000)
    }

    func testPlannedSitesOfABoxSendTheFourBoundsTogether() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let seen = PlannedSitesQueries()
        defer { MockURLProtocol.requestHandler = nil }
        MockURLProtocol.requestHandler = { request in
            seen.append(request.url!)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"sites":[]}"#.utf8))
        }
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("unit-test-session")
        let service = MapSnapshotService(api: APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config)),
                                         cache: DiskCache(folderName: "PlannedBox-\(UUID().uuidString)", evicts: false))
        let box = MapBounds(north: 46.09, south: 45.98, east: 4.15, west: 3.99)
        _ = try await service.plannedSitesLayer(market: "FR", operatorName: "ALL", near: box)
        _ = try await service.plannedSitesLayer(market: "FR", operatorName: "ALL", near: box)
        let urls = seen.urls
        XCTAssertEqual(urls.count, 1, "le second appel lit le cache de 5 min")
        let items = URLComponents(url: try XCTUnwrap(urls.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(urls.first?.path, "/api/map/planned-sites")
        XCTAssertEqual(values["market"], "FR")
        XCTAssertEqual(values["operator"], "ALL")
        XCTAssertEqual(values["north"], "46.09")
        XCTAssertEqual(values["south"], "45.98")
        XCTAssertEqual(values["east"], "4.15")
        XCTAssertEqual(values["west"], "3.99")
    }
}

private final class PlannedSitesQueries: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var urls: [URL] { lock.withLock { stored } }
    func append(_ url: URL) { lock.withLock { stored.append(url) } }
}
