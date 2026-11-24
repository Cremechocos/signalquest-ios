import XCTest
import CoreLocation
import MapKit
import SwiftUI
@testable import SignalQuest

@MainActor
final class MapFilterSelectionTests: XCTestCase {
    private let preferenceKeys = [MapMarketStore.marketKey, MapMarketStore.operatorKey,
                                  "map.manualMarket.v1", MapRegionStore.key, MapBandMatchStore.key, MapAzimuthStyleStore.key,
                                  MapMarketStore.accountDefaultKey, MapMarketStore.deducedMarketKey]
    private var savedPreferences: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in preferenceKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedPreferences[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    override func tearDown() {
        for key in preferenceKeys { UserDefaults.standard.set(savedPreferences[key], forKey: key) }
        savedPreferences = [:]
        super.tearDown()
    }

    func testCountryChangePrunesIncompatibleRadioFiltersAndKeepsLayerChoices() throws {
        let canada = try market("CA")
        var selection = MapFilterSelection.defaults(market: "FR", operatorName: "SFR")
        selection.bands = [3, 20, 71]
        selection.sharing = ["ZTD"]
        selection.technologies = ["4G", "5G"]
        selection.layers = [.antenna, .photo, .friend, .coverage, .planned]
        let changed = selection.normalized(for: canada, dromRegion: nil)
        XCTAssertEqual(changed.market, "CA")
        XCTAssertEqual(changed.operatorName, "BELL")
        XCTAssertEqual(changed.bands, [71])
        XCTAssertTrue(changed.sharing.isEmpty)
        XCTAssertEqual(changed.technologies, ["4G", "5G"])
        XCTAssertEqual(changed.layers, [.antenna, .photo, .friend, .coverage, .planned])
        XCTAssertEqual(selection.market, "FR", "Normalizing a draft must not mutate its source value")
    }

    func testCommunityMarketKeepsAllExistingConsumerLayers() throws {
        var selection = MapFilterSelection.defaults(market: "FR", operatorName: "SFR")
        selection.layers = [.antenna, .customSite, .photo, .friend, .coverage, .speedtest]
        let changed = selection.normalized(for: try market("DE"), dromRegion: nil)
        XCTAssertEqual(changed.operatorName, "ALL")
        XCTAssertEqual(changed.layers, selection.layers, "The old four-chip menu was not a capability contract")
    }

    func testDromOperatorChoicesMatchTheVisibleTerritory() throws {
        let drom = try market("DROM")
        let keys = MapFilterSelection.operatorOptions(for: drom, dromRegion: .reunion)
        XCTAssertTrue(keys.contains("SRR"))
        XCTAssertTrue(keys.contains("ALL"))
        XCTAssertFalse(keys.contains("DIGICEL"))
        var selection = MapFilterSelection.defaults(market: "DROM", operatorName: "DIGICEL")
        XCTAssertEqual(selection.normalized(for: drom, dromRegion: .reunion).operatorName, "ORANGE")
        selection.operatorName = "SRR"
        XCTAssertEqual(selection.normalized(for: drom, dromRegion: .reunion).operatorName, "SRR")
    }

    func testDefaultsAndRenderOnlyChangesDoNotRequireNetworkReload() {
        let baseline = MapFilterSelection.defaults(market: "FR", operatorName: "SFR")
        XCTAssertEqual(baseline.azimuthStyle, .lobes, "Secteurs par défaut, comme le web et Android")
        var changed = baseline
        changed.azimuthStyle = .hidden
        changed.plannedStatuses = []
        XCTAssertFalse(changed.requiresNetworkReload(comparedTo: baseline))
        changed.includeObserved = false
        XCTAssertTrue(changed.requiresNetworkReload(comparedTo: baseline))
        changed = baseline
        changed.coverageDays = 7
        XCTAssertTrue(changed.requiresNetworkReload(comparedTo: baseline))
    }

    func testPhotosShowEveryMemberUntilFriendsOnlyIsChosen() {
        let baseline = MapFilterSelection.defaults(market: "FR", operatorName: "SFR")
        XCTAssertTrue(baseline.layers.contains(.friend))
        XCTAssertFalse(baseline.photosFriendsOnly, "La couche Amis ne restreint pas les photos")
        var changed = baseline
        changed.photosFriendsOnly = true
        XCTAssertTrue(changed.requiresNetworkReload(comparedTo: baseline))
    }

    func testBandMatchWithoutBandsStillInvalidatesTheRawLoadContext() {
        let baseline = MapFilterSelection.defaults(market: "FR", operatorName: "SFR")
        var changed = baseline
        changed.bandMatch = .all
        XCTAssertTrue(changed.requiresNetworkReload(comparedTo: baseline),
                      "LoadContext still compares bandMatch; omitting a replacement load would reject its pending response")
    }

    func testInitialResolutionCannotOverwriteAManualApply() async throws {
        let defaults = UserDefaults.standard
        let previousMarket = defaults.object(forKey: MapMarketStore.marketKey)
        let previousOperator = defaults.object(forKey: MapMarketStore.operatorKey)
        defer {
            defaults.set(previousMarket, forKey: MapMarketStore.marketKey)
            defaults.set(previousOperator, forKey: MapMarketStore.operatorKey)
        }
        let payload = try registry()
        let started = expectation(description: "Initial registry resolution is suspended")
        let markets = DeferredSelectionMarkets(payload: payload, mode: .initial, started: { started.fulfill() })
        let model = makeModel(markets: markets)
        model.registryMarkets = payload.markets
        model.marketFilter = "FR"
        let network = NetworkPathMonitor()
        defer { network.stop(); model.endInitialSelection() }
        let driver = FilterLocationDriver()
        let location = LocationService(manager: driver, makeOneShotManager: { FilterLocationDriver() })
        let initial = Task {
            await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(), location: location)
        }
        await fulfillment(of: [started], timeout: 2)
        var selected = MapFilterSelection.defaults(market: "CA", operatorName: "BELL")
        selected.bands = [71]
        let applied = try XCTUnwrap(model.applyFilterSelection(selected))
        MapMarketStore.save(market: applied.market, operator: applied.operatorName)
        await markets.release()
        await initial.value
        XCTAssertEqual(model.marketFilter, "CA")
        XCTAssertEqual(model.currentMarketEntry?.marketCode, "CA")
        XCTAssertEqual(model.operatorFilter, "BELL")
        XCTAssertEqual(model.bandFilters, [71])
        XCTAssertEqual(MapMarketStore.lastMarket(), "CA")
    }

    func testCameraMovementKeepsTheManualCountryWithoutLocationRequests() async throws {
        let lookup = expectation(description: "Panning must not resolve a new country")
        lookup.isInverted = true
        let payload = try registry()
        let markets = LocatedFilterMarkets(payload: payload, locatedCode: "FR", onLocation: { lookup.fulfill() })
        let model = makeModel(markets: markets)
        model.registryMarkets = payload.markets
        _ = try XCTUnwrap(model.applyFilterSelection(.defaults(market: "CA", operatorName: "BELL")))
        model.recordViewportCenter(CLLocationCoordinate2D(latitude: 45, longitude: 5))
        await fulfillment(of: [lookup], timeout: 1.6)
        XCTAssertEqual(model.marketFilter, "CA")
        XCTAssertEqual(model.currentMarketEntry?.marketCode, "CA")
        XCTAssertEqual(model.operatorFilter, "BELL")
    }

    func testManualCountrySurvivesANewMapModelAndDifferentPhysicalLocation() async throws {
        let payload = try registry()
        let markets = LocatedFilterMarkets(payload: payload, locatedCode: "FR")
        let first = makeModel(markets: markets)
        first.registryMarkets = payload.markets
        _ = try XCTUnwrap(first.applyFilterSelection(.defaults(market: "CA", operatorName: "BELL")))
        // Mirrors the existing view's persistence hook as well as the model commit.
        MapMarketStore.save(market: first.marketFilter, operator: first.operatorFilter)
        let reopened = makeModel(markets: markets)
        reopened.registryMarkets = payload.markets
        let network = NetworkPathMonitor()
        let location = makeLocation(latitude: 45.188, longitude: 5.7129)
        defer { network.stop(); reopened.endInitialSelection() }
        await reopened.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(), location: location)
        XCTAssertEqual(reopened.marketFilter, "CA", "A saved explicit country wins over a new location")
        XCTAssertEqual(reopened.operatorFilter, "BELL")
        XCTAssertEqual(MapMarketStore.lastMarket(), "CA")
    }

    func testInitialCountryUsesPhysicalLocationBeforeDeviceLocale() async throws {
        MapMarketStore.reset()
        let payload = try registry()
        let markets = LocatedFilterMarkets(payload: payload, locatedCode: "CA")
        let model = makeModel(markets: markets)
        model.registryMarkets = payload.markets
        let network = NetworkPathMonitor()
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(),
                                            location: makeLocation(latitude: 45.5019, longitude: -73.5674))
        XCTAssertEqual(model.marketFilter, "CA")
        XCTAssertEqual(model.currentMarketEntry?.marketCode, "CA")
    }

    /// « Mon pays » passe après la position et avant le dernier pays ; il n'est pas « déduit ».
    func testAccountCountryWinsOverTheLastCountryWithoutLocation() async throws {
        MapMarketStore.save(market: "FR", operator: "SFR")
        MapMarketStore.saveAccountDefault("CA")
        let payload = try registry()
        let model = makeModel(markets: LocatedFilterMarkets(payload: payload, locatedCode: "FR"))
        let network = NetworkPathMonitor()
        let denied = LocationService(manager: FilterLocationDriver(), makeOneShotManager: { FilterLocationDriver() })
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(), location: denied)
        XCTAssertEqual(model.marketFilter, "CA")
        XCTAssertFalse(model.countryDeduced)
    }

    /// Sans position, réglage ni dernier pays : pays déduit, signalé jusqu'à la
    /// réponse de l'utilisateur, même après réouverture.
    func testAnInferredCountryIsFlaggedUntilKeptOrChanged() async throws {
        let payload = try registry()
        let markets = LocatedFilterMarkets(payload: payload, locatedCode: "FR")
        let network = NetworkPathMonitor()
        defer { network.stop() }
        func open() async -> MapExplorerViewModel {
            let model = makeModel(markets: markets)
            model.registryMarkets = payload.markets
            let denied = LocationService(manager: FilterLocationDriver(), makeOneShotManager: { FilterLocationDriver() })
            await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(), location: denied)
            model.endInitialSelection()
            return model
        }
        let first = await open()
        XCTAssertTrue(first.countryDeduced)
        let again = await open()
        XCTAssertTrue(again.countryDeduced, "le dernier pays, encore déduit, reste signalé")
        first.keepDeducedCountry()
        let kept = await open()
        XCTAssertFalse(kept.countryDeduced)
        MapMarketStore.saveDeduced(kept.marketFilter)
        let reopened = await open()
        XCTAssertTrue(reopened.countryDeduced)
        _ = try XCTUnwrap(reopened.applyFilterSelection(.defaults(market: "CA", operatorName: "BELL")))
        XCTAssertFalse(reopened.countryDeduced)
        XCTAssertNil(MapMarketStore.deducedMarket())
    }

    func testInitialGPSReplacesAnOldViewportFromAnotherCountry() async throws {
        MapMarketStore.save(market: "FR", operator: "SFR")
        let model = makeModel(markets: LocatedFilterMarkets(payload: try registry(), locatedCode: "CA"))
        let network = NetworkPathMonitor()
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(),
            location: makeLocation(latitude: 45.5019, longitude: -73.5674))
        let paris = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
                                      latitudinalMeters: 2000, longitudinalMeters: 2000)
        let region = try XCTUnwrap(model.takeInitialMapRegion(restoring: paris))
        XCTAssertEqual(region.center.latitude, 45.5019, accuracy: 0.0001)
        XCTAssertEqual(region.center.longitude, -73.5674, accuracy: 0.0001)
        XCTAssertNil(model.takeInitialMapRegion(restoring: paris), "Returning to the same map must not recenter again")
    }

    func testDromGPSFramesTheDetectedTerritoryInsteadOfTheRegistryPlaceholder() async throws {
        let payload = try registry()
        let model = makeModel(markets: LocatedFilterMarkets(payload: payload, locatedCode: "DROM"))
        model.registryMarkets = payload.markets
        let network = NetworkPathMonitor()
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(),
            location: makeLocation(latitude: -20.8823, longitude: 55.4504))
        let region = try XCTUnwrap(model.takeInitialMapRegion(restoring: nil))
        XCTAssertEqual(DromRegion.from(region.center), .reunion)
        XCTAssertEqual(region.center.latitude, -20.8823, accuracy: 0.0001)
        XCTAssertEqual(model.currentDromRegion, .reunion)
    }

    func testManualDromDefaultFramesARealTerritory() throws {
        let payload = try registry()
        let model = makeModel(markets: LocatedFilterMarkets(payload: payload, locatedCode: "FR"))
        model.registryMarkets = payload.markets
        _ = try XCTUnwrap(model.applyFilterSelection(.defaults(market: "DROM", operatorName: "ALL")))
        let region = model.defaultMapRegion(forMarketCode: "DROM")
        XCTAssertNotNil(DromRegion.from(region.center), "The registry placeholder (0,-3) is not a DROM territory")
    }

    func testManualCountryRestoresIntentionalExplorationOutsideThatCountry() async throws {
        MapMarketStore.saveManual(market: "CA", operator: "BELL")
        let model = makeModel(markets: LocatedFilterMarkets(payload: try registry(), locatedCode: "FR"))
        let network = NetworkPathMonitor()
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(),
            location: makeLocation(latitude: 48.8, longitude: 2.3))
        let saved = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 44, longitude: -72),
                                      latitudinalMeters: 10000, longitudinalMeters: 10000)
        let restored = try XCTUnwrap(model.takeInitialMapRegion(restoring: saved))
        XCTAssertEqual(restored.center.latitude, 44)
        XCTAssertEqual(restored.center.longitude, -72)
        XCTAssertNil(model.takeInitialMapRegion(restoring: saved))
    }

    func testManualDromOperatorSurvivesAnExplorationOutsideItsTerritories() async throws {
        MapMarketStore.saveManual(market: "DROM", operator: "SRR")
        let model = makeModel(markets: LocatedFilterMarkets(payload: try registry(), locatedCode: "FR"))
        model.recordViewportCenter(CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35))
        let network = NetworkPathMonitor()
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(),
            location: makeLocation(latitude: 48.85, longitude: 2.35))
        XCTAssertEqual(model.marketFilter, "DROM")
        XCTAssertEqual(model.operatorFilter, "SRR", "A framing fallback must not override an explicit carrier")
        XCTAssertNil(model.currentDromRegion)
    }

    func testMissingGPSKeepsThePreviousCountryAndRestoredDromTerritory() async throws {
        MapMarketStore.save(market: "DROM", operator: "SRR")
        let saved = MKCoordinateRegion(center: DromRegion.reunion.center, latitudinalMeters: 8000, longitudinalMeters: 8000)
        MapRegionStore.save(saved)
        let model = makeModel(markets: LocatedFilterMarkets(payload: try registry(), locatedCode: "FR"))
        model.recordViewportCenter(saved.center)
        let network = NetworkPathMonitor()
        let location = LocationService(manager: FilterLocationDriver(), makeOneShotManager: { FilterLocationDriver() })
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(), location: location)
        XCTAssertEqual(model.marketFilter, "DROM")
        XCTAssertEqual(model.operatorFilter, "SRR")
        XCTAssertEqual(model.currentDromRegion, .reunion)
        XCTAssertEqual(try XCTUnwrap(model.takeInitialMapRegion(restoring: saved)).center.latitude, saved.center.latitude)
    }

    func testStartupObservationKeepsItsOriginAfterTheTaskEndsAndManualApplyInvalidatesIt() async throws {
        let payload = try registry()
        let model = makeModel(markets: LocatedFilterMarkets(payload: payload, locatedCode: "CA"))
        model.registryMarkets = payload.markets
        model.marketFilter = "FR"
        let network = NetworkPathMonitor()
        defer { network.stop(); model.endInitialSelection() }
        await model.resolveInitialSelection(networkPath: network, networkOperator: NoNetworkOperator(),
            location: makeLocation(latitude: 45.5019, longitude: -73.5674))
        model.endInitialSelection()
        XCTAssertTrue(model.consumeInitialSelectionObservation(model.filterSelection(layers: [])))
        XCTAssertFalse(model.consumeInitialSelectionObservation(model.filterSelection(layers: [])))
        _ = try XCTUnwrap(model.applyFilterSelection(.defaults(market: "FR", operatorName: "SFR")))
        XCTAssertFalse(model.consumeInitialSelectionObservation(model.filterSelection(layers: [])))
    }

    func testChangingCountryOrCarrierClearsAnIncompatibleSiteFocus() throws {
        let payload = try registry()
        let model = makeModel(markets: LocatedFilterMarkets(payload: payload, locatedCode: "FR"))
        model.registryMarkets = payload.markets
        _ = try XCTUnwrap(model.applyFilterSelection(.defaults(market: "FR", operatorName: "SFR")))
        let focus = AntennaCoverageFocus(siteLabel: "Antenne synthétique", operatorKey: "SFR", enb: "123", gnb: nil)
        model.coverageFocus = focus
        _ = try XCTUnwrap(model.applyFilterSelection(.defaults(market: "FR", operatorName: "SFR")))
        XCTAssertEqual(model.coverageFocus, focus, "Editing the same network must keep the explicit site restriction")
        _ = try XCTUnwrap(model.applyFilterSelection(.defaults(market: "CA", operatorName: "BELL")))
        XCTAssertNil(model.coverageFocus, "A French site's radio identity must not filter Canadian data")
        _ = try XCTUnwrap(model.applyFilterSelection(.defaults(market: "FR", operatorName: "SFR")))
        model.coverageFocus = focus
        model.chooseOperatorManually("ORANGE")
        XCTAssertNil(model.coverageFocus, "A radio site identity belongs to its carrier")
    }

    private func makeLocation(latitude: Double, longitude: Double) -> LocationService {
        let driver = FilterLocationDriver(authorizationStatus: .authorizedWhenInUse)
        let service = LocationService(manager: driver, makeOneShotManager: { FilterLocationDriver() })
        service.receiveLocations([CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0, horizontalAccuracy: 50, verticalAccuracy: -1, timestamp: Date())])
        return service
    }

    func testDraftDoesNotWritePreferencesAndApplyCopiesEveryChoice() throws {
        let defaults = UserDefaults.standard
        let oldBand = defaults.object(forKey: MapBandMatchStore.key)
        let oldAzimuth = defaults.object(forKey: MapAzimuthStyleStore.key)
        defer {
            defaults.set(oldBand, forKey: MapBandMatchStore.key)
            defaults.set(oldAzimuth, forKey: MapAzimuthStyleStore.key)
        }
        MapBandMatchStore.save(.any)
        MapAzimuthStyleStore.save(.lines)
        let registry = try registry()
        let model = makeModel(markets: ControlledMarkets(registry: registry))
        model.registryMarkets = registry.markets
        model.marketFilter = "FR"
        model.operatorFilter = "SFR"
        var draft = model.filterSelection(layers: [.antenna])
        draft.operatorName = "ORANGE"
        draft.technologies = ["5G"]
        draft.bands = [78]
        draft.bandMatch = .only
        draft.azimuthStyle = .hidden
        draft.sharing = ["ZTD"]
        draft.speedtestDays = 7
        draft.coverageDays = 30
        draft.layers = [.coverage, .planned]
        draft.includeObserved = false
        draft.plannedStatuses = []
        XCTAssertEqual(model.operatorFilter, "SFR")
        XCTAssertEqual(MapBandMatchStore.last(), .any)
        XCTAssertEqual(MapAzimuthStyleStore.last(), .lines)
        let applied = try XCTUnwrap(model.applyFilterSelection(draft))
        XCTAssertEqual(model.filterSelection(layers: applied.layers), draft)
        XCTAssertEqual(MapBandMatchStore.last(), .only)
        XCTAssertEqual(MapAzimuthStyleStore.last(), .hidden)
    }

    func testLateCountryAlignmentCannotReplaceANewerCountry() async throws {
        let started = expectation(description: "First France lookup is suspended")
        let markets = ControlledMarkets(registry: try registry(), onDelayed: { started.fulfill() })
        let model = makeModel(markets: markets)
        model.marketFilter = "FR"
        let old = Task { await model.alignWithMarket(code: "FR", resetOperator: false) }
        await fulfillment(of: [started], timeout: 2)
        model.marketFilter = "CA"
        model.operatorFilter = "BELL"
        model.bandFilters = [71]
        await model.alignWithMarket(code: "CA", resetOperator: false)
        await markets.releaseFirst()
        await old.value
        XCTAssertEqual(model.currentMarketEntry?.marketCode, "CA")
        XCTAssertEqual(model.operatorFilter, "BELL")
        XCTAssertEqual(model.bandFilters, [71])
    }

    func testLateAlignmentCannotReplaceANewerVisitToTheSameCountry() async throws {
        let started = expectation(description: "Old France lookup is suspended")
        let markets = ControlledMarkets(registry: try registry(), onDelayed: { started.fulfill() })
        let model = makeModel(markets: markets)
        model.marketFilter = "FR"
        let old = Task { await model.alignWithMarket(code: "FR", resetOperator: false) }
        await fulfillment(of: [started], timeout: 2)
        model.marketFilter = "CA"
        await model.alignWithMarket(code: "CA", resetOperator: false)
        model.marketFilter = "FR"
        await model.alignWithMarket(code: "FR", resetOperator: false)
        XCTAssertEqual(model.currentMarketEntry?.label, "France récente")
        await markets.releaseFirst()
        await old.value
        XCTAssertEqual(model.currentMarketEntry?.label, "France récente")
    }

    private func registry() throws -> MarketRegistryPayload {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "market_registry_fallback", withExtension: "json"))
        return try JSONDecoder.signalQuest.decode(MarketRegistryPayload.self, from: Data(contentsOf: url))
    }
    private func market(_ code: String) throws -> MarketRegistryEntry {
        try XCTUnwrap(registry().markets.first { $0.marketCode == code })
    }
    private func makeModel(markets: MarketRegistryServicing) -> MapExplorerViewModel {
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: .ephemeral))
        return MapExplorerViewModel(map: MapSnapshotService(api: api), antennas: AntennasService(api: api),
                                    markets: markets, communityOutages: CommunityOutageService(api: api))
    }
}

private struct NoNetworkOperator: NetworkOperatorServicing {
    func resolve(viaVpn: Bool) async -> DetectedOperator? { nil }
}

@MainActor
private final class FilterLocationDriver: LocationManagerDriving {
    weak var delegate: (any CLLocationManagerDelegate)?
    let authorizationStatus: CLAuthorizationStatus
    init(authorizationStatus: CLAuthorizationStatus = .denied) { self.authorizationStatus = authorizationStatus }
    var desiredAccuracy: CLLocationAccuracy = 100
    var distanceFilter: CLLocationDistance = 0
    var allowsBackgroundLocationUpdates = false
    var pausesLocationUpdatesAutomatically = true
    var headingFilter: CLLocationDegrees = 0
    func requestWhenInUseAuthorization() { XCTFail("The denied fixture must not request permission") }
    func requestLocation() { XCTFail("The denied fixture must not acquire a location") }
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
}

private actor DeferredSelectionMarkets: MarketRegistryServicing {
    enum Mode { case initial, location }
    let payload: MarketRegistryPayload
    let mode: Mode
    let started: @Sendable () -> Void
    let repeated: @Sendable () -> Void
    private var initial: CheckedContinuation<MarketRegistryPayload, Never>?
    private var location: CheckedContinuation<MarketRegistryEntry?, Never>?
    private var locationCalls = 0
    init(payload: MarketRegistryPayload, mode: Mode, started: @escaping @Sendable () -> Void,
         repeated: @escaping @Sendable () -> Void = {}) {
        self.payload = payload; self.mode = mode; self.started = started; self.repeated = repeated
    }
    func registry() async -> MarketRegistryPayload {
        guard mode == .initial else { return payload }
        return await withCheckedContinuation { initial = $0; started() }
    }
    func market(forCode code: String?) async -> MarketRegistryEntry? {
        payload.markets.first { $0.marketCode == code }
    }
    func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry? {
        locationCalls += 1
        if locationCalls == 1 {
            return await withCheckedContinuation { location = $0; started() }
        }
        repeated()
        return payload.markets.first { $0.marketCode == "FR" }
    }
    func release() {
        initial?.resume(returning: MarketRegistryPayload(markets: payload.markets.filter { $0.marketCode == "FR" }))
        location?.resume(returning: payload.markets.first { $0.marketCode == "FR" })
        initial = nil; location = nil
    }
    nonisolated func marketAreaContainsLocation(marketCode: String?, latitude: Double, longitude: Double) -> Bool { false }
    nonisolated func franceHysteresisContains(latitude: Double, longitude: Double) -> Bool { false }
}

private actor ControlledMarkets: MarketRegistryServicing {
    let payload: MarketRegistryPayload
    let onDelayed: (@Sendable () -> Void)?
    private var firstFrance: CheckedContinuation<MarketRegistryEntry?, Never>?
    private var didDelay = false
    init(registry: MarketRegistryPayload, onDelayed: (@Sendable () -> Void)? = nil) {
        payload = registry
        self.onDelayed = onDelayed
    }
    func registry() async -> MarketRegistryPayload { payload }
    func market(forCode code: String?) async -> MarketRegistryEntry? {
        guard let entry = payload.markets.first(where: { $0.marketCode == code }) else { return nil }
        if code == "FR", onDelayed != nil {
            if !didDelay {
                didDelay = true
                return await withCheckedContinuation { continuation in
                    firstFrance = continuation
                    onDelayed?()
                }
            }
            var object = try! JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(entry)) as! [String: Any]
            object["label"] = "France récente"
            return try! JSONDecoder.signalQuest.decode(MarketRegistryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        }
        return entry
    }
    func releaseFirst() {
        firstFrance?.resume(returning: payload.markets.first { $0.marketCode == "FR" })
        firstFrance = nil
    }
    func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry? { nil }
    nonisolated func marketAreaContainsLocation(marketCode: String?, latitude: Double, longitude: Double) -> Bool { false }
    nonisolated func franceHysteresisContains(latitude: Double, longitude: Double) -> Bool { false }
}

private struct LocatedFilterMarkets: MarketRegistryServicing {
    let payload: MarketRegistryPayload
    let locatedCode: String
    var onLocation: @Sendable () -> Void = {}
    func registry() async -> MarketRegistryPayload { payload }
    func market(forCode code: String?) async -> MarketRegistryEntry? {
        payload.markets.first { $0.marketCode == code }
    }
    func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry? {
        onLocation()
        return payload.markets.first { $0.marketCode == locatedCode }
    }
    nonisolated func marketAreaContainsLocation(marketCode: String?, latitude: Double, longitude: Double) -> Bool { false }
    nonisolated func franceHysteresisContains(latitude: Double, longitude: Double) -> Bool { false }
}

/// IOS-037 lot 3 : la couche Débits se colore selon la métrique choisie, avec les seuils
/// d'Android et les six teintes du contrat ; une métrique absente est grise, jamais une autre.
final class SpeedtestMapMetricTests: XCTestCase {
    private func feature(download: Double = 120, upload: Double? = 30, ping: Double? = 12) -> SpeedtestFeature {
        SpeedtestFeature(id: "m", coordinate: .init(latitude: 48.85, longitude: 2.35), downloadMbps: download,
                         uploadMbps: upload, pingMs: ping, tech: nil, band: nil, frequency: nil, timestamp: nil)
    }

    func testEachMetricUsesItsOwnValueAndThresholds() {
        XCTAssertEqual(SpeedtestMapMetric.download.tier(for: feature(download: 120)), .good)
        XCTAssertEqual(SpeedtestMapMetric.upload.tier(for: feature(upload: 30)), .veryGood)
        XCTAssertEqual(SpeedtestMapMetric.upload.tier(for: feature(upload: 1.5)), .verySlow)
        XCTAssertEqual(SpeedtestMapMetric.upload.tier(for: feature(upload: 50)), .exceptional)
        XCTAssertEqual(SpeedtestMapMetric.ping.tier(for: feature(ping: 12)), .exceptional)
        XCTAssertEqual(SpeedtestMapMetric.ping.tier(for: feature(ping: 20)), .veryGood)
        XCTAssertEqual(SpeedtestMapMetric.ping.tier(for: feature(ping: 150)), .verySlow)
        XCTAssertEqual(SpeedtestMapMetric.upload.hex(for: feature(upload: nil)), SQQualityScale.unknownHex)
        XCTAssertEqual(SpeedtestMapMetric.ping.hex(for: feature(ping: nil)), SQQualityScale.unknownHex)
        let contractHexes = Set(SQQualityScale.Throughput.allCases.map(\.hex))
        for metric in SpeedtestMapMetric.allCases {
            XCTAssertEqual(metric.legendRows.count, 6, "\(metric)")
            XCTAssertTrue(metric.legendRows.allSatisfy { contractHexes.contains($0.hex) }, "jamais de cyan ni de bleu : \(metric)")
        }
        XCTAssertEqual(SpeedtestMapMetric.ping.legendRows.first?.hex, SQQualityScale.Throughput.exceptional.hex)
    }
}

/// IOS-037 lot 3 : filtres de sites appliqués sur la carte, sans requête, comme Android.
final class MapSiteFiltersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func site(height: Double? = 30, photos: Int = 0, enb: Bool = false, commissioned: Date? = nil,
                      power: Double? = nil, gain: Double? = nil, structure: Double? = nil) -> AntennaSite {
        var site = AntennaSite(id: "s", siteId: "1", latitude: 44.8, longitude: -0.6, operators: ["ORANGE"],
                               technologies: ["4G"], bands: [], azimuths: [], sharingType: nil, crozonLeader: nil,
                               address: nil, height: height, owner: nil)
        site.photoCount = photos
        site.hasEnb = enb
        site.commissionedAt = commissioned
        site.caTxPowerW = power
        site.caAntennaGainDbi = gain
        site.caStructureHeightMeters = structure
        return site
    }

    func testPhotosAndIdentificationFilterOnlyWithNeighbourhoodData() {
        var filters = MapSiteFilters()
        filters.photos = .with
        XCTAssertTrue(filters.matches(site(photos: 2), market: "FR", contributionDataAvailable: true))
        XCTAssertFalse(filters.matches(site(photos: 0), market: "FR", contributionDataAvailable: true))
        XCTAssertTrue(filters.matches(site(photos: 0), market: "FR", contributionDataAvailable: false),
                      "sous le zoom 13, rien n'est servi : le filtre est suspendu, il ne vide pas la carte")
        filters = MapSiteFilters()
        filters.identification = .notIdentified
        XCTAssertTrue(filters.matches(site(enb: false), market: "FR", contributionDataAvailable: true))
        XCTAssertFalse(filters.matches(site(enb: true), market: "FR", contributionDataAvailable: true))
    }

    func testSupportHeightAndCommissioningFollowANFRDataOnly() {
        var filters = MapSiteFilters()
        filters.supportHeight = .from20To40
        XCTAssertTrue(filters.matches(site(height: 20), market: "FR", contributionDataAvailable: true))
        XCTAssertTrue(filters.matches(site(height: 40), market: "DROM", contributionDataAvailable: true))
        XCTAssertFalse(filters.matches(site(height: 40.5), market: "FR", contributionDataAvailable: true))
        XCTAssertFalse(filters.matches(site(height: nil), market: "FR", contributionDataAvailable: true), "hauteur inconnue")
        XCTAssertTrue(filters.matches(site(height: nil), market: "BE", contributionDataAvailable: true), "hors ANFR, sans effet")

        filters = MapSiteFilters()
        filters.commissionedWithinMonths = 6
        XCTAssertTrue(filters.matches(site(commissioned: now.addingTimeInterval(-100 * 86_400)), market: "FR",
                                      contributionDataAvailable: true, now: now))
        XCTAssertFalse(filters.matches(site(commissioned: now.addingTimeInterval(-200 * 86_400)), market: "FR",
                                       contributionDataAvailable: true, now: now), "6 mois = 180 jours")
        XCTAssertFalse(filters.matches(site(commissioned: nil), market: "FR", contributionDataAvailable: true, now: now))
        filters.commissionedSince = now.addingTimeInterval(-300 * 86_400)
        XCTAssertTrue(filters.matches(site(commissioned: now.addingTimeInterval(-200 * 86_400)), market: "FR",
                                      contributionDataAvailable: true, now: now), "la date choisie prime sur les mois")
    }

    func testCanadaBucketsUseInclusiveUpperBounds() {
        var filters = MapSiteFilters()
        filters.caPower = .low
        filters.caGain = .mid
        filters.caHeight = .high
        let inside = site(power: 10, gain: 20, structure: 40.1)
        XCTAssertTrue(filters.matches(inside, market: "CA", contributionDataAvailable: true))
        XCTAssertFalse(filters.matches(site(power: 10.1, gain: 20, structure: 41), market: "CA", contributionDataAvailable: true))
        XCTAssertFalse(filters.matches(site(power: nil, gain: 20, structure: 41), market: "CA", contributionDataAvailable: true),
                       "valeur inconnue exclue")
        XCTAssertTrue(filters.matches(site(power: nil), market: "CA", contributionDataAvailable: true, isedDataAvailable: false),
                      "liste filtrée côté serveur, sans champs ISED : suspendu")
        XCTAssertTrue(filters.matches(site(power: nil), market: "FR", contributionDataAvailable: true), "hors Canada")
    }

    func testCountrySpecificFiltersResetOnAnotherMarket() {
        var filters = MapSiteFilters()
        filters.supportHeight = .over40
        filters.commissionedWithinMonths = 12
        filters.caGain = .high
        filters.photos = .with
        let belgium = filters.normalized(forMarket: "BE")
        XCTAssertEqual(belgium.supportHeight, .all)
        XCTAssertEqual(belgium.commissionedWithinMonths, 0)
        XCTAssertEqual(belgium.caGain, .all)
        XCTAssertEqual(belgium.photos, .with, "photos et identification valent partout")
        XCTAssertEqual(filters.normalized(forMarket: "FR").supportHeight, .over40)
        XCTAssertEqual(filters.normalized(forMarket: "CA").caGain, .high)
    }

    func testTileMarkerReadsCommissioningAndISEDValues() throws {
        let json = Data(#"""
        {"id":"a","lat":44.8,"lng":-0.6,"derniere_mise_en_service":"2025-06-01","txPowerMaxW":"12,5",
         "tx_antenna_gain_max":17.2,"structure_height":null,"hauteur_antenne":"35"}
        """#.utf8)
        let marker = try JSONDecoder().decode(AndroidAntennaMarker.self, from: json)
        XCTAssertEqual(marker.commissionedAt, ISO8601DateFormatter().date(from: "2025-06-01T00:00:00Z"))
        XCTAssertEqual(marker.caTxPowerW, 12.5)
        XCTAssertEqual(marker.caAntennaGainDbi, 17.2)
        XCTAssertEqual(marker.caStructureHeightMeters, 35, "repli sur la hauteur d'antenne, comme Android")
        XCTAssertNotNil(AndroidAntennaMarker.commissioningDate("2024-03-12T08:30:00.000Z"))
        XCTAssertNil(AndroidAntennaMarker.commissioningDate("inconnue"))
    }
}

/// IOS-057 : l'ombre d'une carte est portée par la forme de son fond. Posée sur la carte
/// entière, SwiftUI la calculait pour chaque texte du contenu (≈ 360 rendus hors écran par
/// image en faisant défiler la fiche speedtest sur un iPhone, le 24/11).
@MainActor
final class CardShadowLayerTests: XCTestCase {
    func testCardShadowIsCastByTheBackgroundOnly() async throws {
        let card = VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<12, id: \.self) { index in Text(verbatim: "Ligne \(index) · valeur") }
        }
        .padding(14)
        .sqCardBackground()
        .padding(20)
        let host = UIHostingController(rootView: card)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        func shadowed(_ layer: CALayer) -> Int {
            (layer.shadowOpacity > 0 && layer.shadowColor != nil ? 1 : 0)
                + (layer.sublayers ?? []).reduce(0) { $0 + shadowed($1) }
        }
        let count = shadowed(host.view.layer)
        window.isHidden = true
        XCTAssertLessThanOrEqual(count, 1, "\(count) calques portent une ombre : une seule est attendue, celle du fond")
    }
}
