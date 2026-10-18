import XCTest
@testable import SignalQuest

/// Écran « Générations et bandes » (`view=bands`, contrat v1) : requêtes
/// toujours filtrées, générations de la 2G à la 5G, bandes par fréquence,
/// opérateur en filtre, textes chiffrés.
@MainActor
final class ANFRBandsViewModelTests: XCTestCase {
    /// Service ANFR qui ne sert que les statistiques par bande, et les compte.
    private final class BandsOnlyService: ANFRServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var stats: (_ weeks: Int?, _ generation: String?, _ operatorKey: String?) -> ANFRBandStats = {
            ANFRDemoData.bandStats(generation: $1, operatorKey: $2, weeks: $0)
        }
        var calls: [String] { lock.withLock { recorded } }

        func bandStats(weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats {
            lock.withLock { recorded.append("\(weeks.map(String.init) ?? "-"):\(generation ?? "*"):\(operatorKey ?? "-")") }
            return stats(weeks, generation, operatorKey)
        }

        func current() async throws -> ANFRDataset { throw URLError(.unsupportedURL) }
        func archives() async throws -> [ANFRDataset] { throw URLError(.unsupportedURL) }
        func search(query: String) async throws -> [AntennaSite] { throw URLError(.unsupportedURL) }
        func siteHistory(supId: String) async throws -> ANFRSiteHistory { throw URLError(.unsupportedURL) }
        func stats() async throws -> ANFRStats { throw URLError(.unsupportedURL) }
        func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot { throw URLError(.unsupportedURL) }
        func archiveDates() async throws -> ANFRArchiveDates { throw URLError(.unsupportedURL) }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testTheServiceAlwaysFiltersByGenerationOperatorAndWeeks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-anfr-reader")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let body = try JSONSerialization.data(withJSONObject: [
            "meta": ["firstDate": "2026-07-16", "latestDate": "2026-10-01", "partial": false],
            "bands": [], "series": [], "summary": [],
        ])
        let seen = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, body)
        }
        _ = try await ANFRService(api: api).bandStats(weeks: 53, generation: "5g", operatorKey: "free")
        let url = try XCTUnwrap(seen.first?.0.url)
        XCTAssertEqual(url.path, "/api/anfr/stats")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["view": "bands", "generation": "5g", "operator": "free", "weeks": "53"])
    }

    func testGenerationsComeInOrderAndBandsByFrequency() async {
        let service = BandsOnlyService()
        let model = ANFRBandsViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.generationRows.map(\.key), ["2g", "3g", "4g", "5g"])
        XCTAssertEqual(model.generation, "5g")
        XCTAssertEqual(model.bandRows.map(\.band.key), ["n28", "n1", "n78"], "De la plus basse fréquence à la plus haute")
        XCTAssertEqual(model.selectedSeries.count, ANFRBandsViewModel.weeks)
        XCTAssertEqual(Set(service.calls), ["1:*:all", "53:5g:all"], "Une semaine pour toutes les bandes, 53 pour la génération")

        await model.select(generation: "4g")
        XCTAssertEqual(model.bandRows.map(\.band.key), ["4g700", "4g800", "4g900", "4g1800", "4g2100", "4g2600"])
    }

    func testChoosingAnOperatorReloadsAndAChoiceAlreadySeenComesFromTheCache() async {
        let service = BandsOnlyService()
        let model = ANFRBandsViewModel(service: service)
        await model.load()
        await model.select(operatorKey: "orange")
        XCTAssertEqual(model.operatorKey, "orange")
        XCTAssertTrue(service.calls.contains("53:5g:orange"))
        XCTAssertEqual(model.selectedSeries.first?.operatorKey, "orange")
        let count = service.calls.count
        await model.select(operatorKey: "all")
        XCTAssertEqual(service.calls.count, count, "Déjà chargé : rien à redemander")
        await model.refresh()
        XCTAssertGreaterThan(service.calls.count, count, "Tirer pour actualiser vide le cache")
    }

    /// Une bande que l'opérateur n'a jamais exploitée n'a pas de ligne.
    func testABandTheOperatorNeverUsedHasNoRow() async {
        let service = BandsOnlyService()
        service.stats = { weeks, generation, operatorKey in
            let stats = ANFRDemoData.bandStats(generation: generation, operatorKey: operatorKey, weeks: weeks)
            guard var json = try? JSONSerialization.jsonObject(with: JSONEncoder.bandsFixture(stats)) as? [String: Any],
                  var summary = json["summary"] as? [[String: Any]] else { return stats }
            for index in summary.indices where summary[index]["band"] as? String == "n1" {
                summary[index]["peak"] = ["date": "2026-10-01", "operational": 0]
                summary[index]["shareOfPeakPermille"] = NSNull()
            }
            json["summary"] = summary
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            return (try? JSONDecoder.signalQuest.decode(ANFRBandStats.self, from: data)) ?? stats
        }
        let model = ANFRBandsViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.bandRows.map(\.band.key), ["n28", "n78"])
    }

    /// Évolution (refonte Halo) : une série triée par opérateur sur la bande
    /// filtrée, à l'identité stable, et la hausse lue du premier au dernier relevé.
    func testTrendSeriesPerOperatorAndChangeOverThePeriod() {
        let model = ANFRStatsViewModel(service: BandsOnlyService())
        model.stats = ANFRDemoData.stats
        let orange = model.trendSeries(for: .orange)
        XCTAssertGreaterThan(orange.count, 1)
        XCTAssertEqual(orange.map(\.date), orange.map(\.date).sorted())
        XCTAssertNotEqual(orange.map(\.value), model.trendSeries(for: .free).map(\.value))
        XCTAssertEqual(model.trendSeries.map(\.id), orange.map(\.id), "La carte suit l'opérateur choisi")
        XCTAssertEqual(model.trendSeries(for: .orange).map(\.id), orange.map(\.id), "Le geste ne retrace pas la courbe")

        func points(_ values: Int...) -> [ANFRTrendPoint] {
            values.enumerated().map { ANFRTrendPoint(date: Date(timeIntervalSince1970: Double($0.offset) * 604_800), value: $0.element, generation: .g4) }
        }
        XCTAssertEqual(ANFRStatsViewModel.change(of: points(100, 110, 128)) ?? 0, 0.28, accuracy: 0.0001)
        XCTAssertEqual(ANFRStatsViewModel.change(of: points(100, 90)) ?? 0, -0.1, accuracy: 0.0001)
        XCTAssertNil(ANFRStatsViewModel.change(of: points(100)), "Un seul relevé : pas de hausse")
        XCTAssertNil(ANFRStatsViewModel.change(of: points(0, 5)), "Départ à zéro : pas de pourcentage")
    }

    func testPeakAndChangeTexts() throws {
        let stats = ANFRDemoData.bandStats(generation: "3g", operatorKey: "all", weeks: 1)
        let threeG = try XCTUnwrap(stats.summary(operatorKey: "all", band: "3g"))
        let peak = try XCTUnwrap(ANFRBandsFormat.peak(threeG))
        XCTAssertTrue(peak.contains(ANFRBandsFormat.share(permille: 838)), peak)
        XCTAssertTrue(peak.contains(ANFRBandsFormat.monthYear("2025-10-30")), peak)
        XCTAssertEqual(ANFRBandsFormat.yearChange(threeG), String(localized: "\(ANFRBandsFormat.signed(-9829)) en un an"))

        let fiveG = ANFRDemoData.bandStats(generation: "5g", operatorKey: "all", weeks: 1)
        XCTAssertEqual(ANFRBandsFormat.peak(try XCTUnwrap(fiveG.summary(operatorKey: "all", band: "5g"))),
                       String(localized: "au plus haut"))
        let n78 = try XCTUnwrap(fiveG.summary(operatorKey: "all", band: "5g"))
        XCTAssertEqual(ANFRBandsFormat.projects(n78, generation: "5G"),
                       String(localized: "\(ANFRBandsFormat.sites(n78.latest.projected)) en projet"))
        XCTAssertNil(ANFRBandsFormat.projects(threeG, generation: "3G"), "Comme le web : les projets pour la 4G et la 5G")
        XCTAssertEqual(ANFRBandsFormat.signed(0), 0.formatted())
        XCTAssertTrue(ANFRBandsFormat.signed(5066).hasPrefix("+"))
        XCTAssertFalse(ANFRBandsFormat.signed(-3640).hasPrefix("+"))
    }
}

private extension JSONEncoder {
    /// Réécrit une réponse décodée au format du contrat, pour la modifier.
    static func bandsFixture(_ stats: ANFRBandStats) -> Data {
        func change(_ value: ANFRBandStats.Summary.Change?) -> Any {
            value.map { ["referenceDate": $0.referenceDate, "operational": $0.operational] as [String: Any] } ?? NSNull()
        }
        let bands: [[String: Any]] = stats.bands.map { band in
            ["key": band.key, "generation": band.generation, "kind": band.kind.rawValue,
             "mhz": band.mhz.map { $0 as Any } ?? NSNull(), "nrBand": band.nrBand.map { $0 as Any } ?? NSNull(),
             "label": ["fr": band.label.fr, "en": band.label.en, "short": band.label.short], "firstDate": band.firstDate]
        }
        let series: [[String: Any]] = stats.series.map {
            ["date": $0.date, "operator": $0.operatorKey, "band": $0.band,
             "operational": $0.operational, "projected": $0.projected, "total": $0.total]
        }
        let summary: [[String: Any]] = stats.summary.map { item in
            var row: [String: Any] = ["operator": item.operatorKey, "band": item.band]
            row["latest"] = ["date": item.latest.date, "operational": item.latest.operational, "projected": item.latest.projected]
            row["delta1w"] = change(item.delta1w)
            row["delta4w"] = change(item.delta4w)
            row["delta52w"] = change(item.delta52w)
            row["peak"] = ["date": item.peak.date, "operational": item.peak.operational]
            row["shareOfPeakPermille"] = item.shareOfPeakPermille.map { $0 as Any } ?? NSNull()
            return row
        }
        let json: [String: Any] = [
            "meta": ["firstDate": stats.meta.firstDate, "latestDate": stats.meta.latestDate, "partial": stats.meta.partial],
            "bands": bands, "series": series, "summary": summary,
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}

// MARK: - Carte ANFR : relevé hebdomadaire

/// La carte des changements ANFR : décodage du relevé, filtres, navigation entre
/// semaines, garde-fous (relevés complets, réponses périmées), caches.
@MainActor
final class ANFRMapViewModelTests: XCTestCase {
    private final class FakeService: ANFRServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [String?] = []
        var snapshots: [String: ANFRMapSnapshot] = [:]
        var delays: [String: UInt64] = [:]
        var failing: Set<String> = []
        var dates = ANFRArchiveDates(dates: [], current: nil)
        var weeks: [ANFRWeekSummary] = []

        var requests: [String?] { lock.withLock { requested } }

        func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot {
            let key = date ?? "current"
            lock.withLock { requested.append(date) }
            if let delay = delays[key] { try await Task.sleep(nanoseconds: delay) }
            if failing.contains(key) { throw URLError(.notConnectedToInternet) }
            guard let snapshot = snapshots[key] else { throw URLError(.fileDoesNotExist) }
            return snapshot
        }

        func archiveDates() async throws -> ANFRArchiveDates { dates }
        func archiveWeeks(count: Int) async throws -> [ANFRWeekSummary] { weeks }
        func current() async throws -> ANFRDataset { throw URLError(.unsupportedURL) }
        func archives() async throws -> [ANFRDataset] { throw URLError(.unsupportedURL) }
        func search(query: String) async throws -> [AntennaSite] { throw URLError(.unsupportedURL) }
        func siteHistory(supId: String) async throws -> ANFRSiteHistory { throw URLError(.unsupportedURL) }
        func stats() async throws -> ANFRStats { throw URLError(.unsupportedURL) }
        func bandStats(weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats {
            throw URLError(.unsupportedURL)
        }
    }

    private func antenna(_ id: String, _ op: String, _ type: String, generation: String = "4G",
                         system: String = "LTE 1800", catchUp: Bool = false) -> ANFRMapAntenna {
        ANFRMapAntenna(id: id, supId: nil, operatorRaw: op, system: system, generationRaw: generation, modTypeRaw: type,
                       statut: "En service", dateMaj: "", latitude: nil, longitude: nil, city: nil, address: nil,
                       changeDate: nil, catchUp: catchUp)
    }

    private func site(_ supId: String, _ city: String, _ antennas: [ANFRMapAntenna]) -> ANFRMapSite {
        ANFRMapSite(supId: supId, latitude: 45.0, longitude: 5.0, city: city, antennas: antennas)
    }

    private func snapshot(_ sites: [ANFRMapSite]) -> ANFRMapSnapshot {
        ANFRMapSnapshot(source: "test", snapshotDate: nil, lastUpdate: nil, sites: sites)
    }

    /// Cinq supports qui couvrent les filtres : multi-opérateur, 3G, opérateur non suivi, rattrapage.
    private var mixedSites: [ANFRMapSite] {
        [
            site("1", "LYON", [antenna("a1", "ORANGE", "new", generation: "5G", system: "5G NR 3500")]),
            site("2", "VILLEURBANNE", [antenna("a2", "ORANGE", "activated"), antenna("a3", "FREE MOBILE", "activated")]),
            site("3", "BRON", [antenna("a4", "FREE MOBILE", "deleted", generation: "3G", system: "UMTS 900")]),
            site("4", "SAINT-PRIEST", [antenna("a5", "SRR", "activated")]),
            site("5", "VAULX-EN-VELIN", [antenna("a6", "SFR", "added", catchUp: true)])
        ]
    }

    private func loadedModel(_ service: FakeService) async -> ANFRMapViewModel {
        let model = ANFRMapViewModel(service: service)
        await model.load()
        return model
    }

    /// Les filtres se recalculent après un court délai de regroupement.
    private func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }

    // MARK: Décodage

    func testDecodesRealChangeDateCatchUpAndBuildsTheAddressOnDemand() throws {
        let json = """
        {"source":"current","snapshotDate":"2026-10-15","lastUpdate":"15 oct. 2026","siteCount":2,"sites":[
          {"info":{"sup_id":"29847","lat":"44.5297","lon":"-0.1806","city":"BRANNENS"},
           "antennas":[{"id":"1","adm_lb_nom":"ORANGE","emr_lb_systeme":"5G NR 3500","generation":"5G","type":"activated",
                        "statut":"En service","changeDate":"2018-04-25","catchUp":true,
                        "adr_lb_lieu":"Lulugran","adr_lb_add1":"Centrale solaire","adr_nm_cp":"33124"}]},
          {"info":{"sup_id":"7","lat":"45.1","lon":"5.1","city":"LYON"},
           "antennas":[{"id":"2","adm_lb_nom":"FREE MOBILE","type":"deleted"}]}
        ]}
        """
        let snapshot = try JSONDecoder().decode(ANFRMapSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.sites.count, 2)
        let first = try XCTUnwrap(snapshot.sites.first?.antennas.first)
        XCTAssertEqual(first.changeDate, "2018-04-25")
        XCTAssertTrue(first.catchUp)
        XCTAssertEqual(first.address, "Lulugran, Centrale solaire, 33124")
        // Réponse d'avant ces champs : tolérée.
        let legacy = try XCTUnwrap(snapshot.sites.last?.antennas.first)
        XCTAssertNil(legacy.changeDate)
        XCTAssertFalse(legacy.catchUp)
        XCTAssertNil(legacy.address)
        XCTAssertFalse(snapshot.servedFromCache)
    }

    func testDecodesTheWeeklyBars() throws {
        let json = """
        {"dates":["2026-10-08"],"current":"2026-10-15","weeks":[
          {"date":"2026-10-08","counts":{"new":5,"added":3,"activated":10,"deleted":2,"catchUp":4},"total":20},
          {"date":"2026-10-01","counts":{"new":1}},
          {"counts":{"new":9}}
        ]}
        """
        let weeks = try JSONDecoder().decode(ANFRArchiveWeeks.self, from: Data(json.utf8)).weeks
        XCTAssertEqual(weeks.map(\.date), ["2026-10-08", "2026-10-01"])
        XCTAssertEqual(weeks[0].total, 20)
        XCTAssertEqual(weeks[0].catchUp, 4)
        XCTAssertEqual(weeks[0].count(for: .activated), 10)
        XCTAssertEqual(weeks[1].total, 1, "sans total, la somme des quatre types")
    }

    // MARK: Règles

    func testDominantTypeFollowsTheWebOrder() {
        func dominant(_ types: [String]) -> ANFRModType {
            site("x", "X", types.enumerated().map { antenna("t\($0.offset)", "ORANGE", $0.element) }).dominantModType
        }
        XCTAssertEqual(dominant(["deleted", "activated"]), .activated)
        XCTAssertEqual(dominant(["activated", "added"]), .added)
        XCTAssertEqual(dominant(["added", "new", "deleted"]), .new)
        XCTAssertEqual(dominant(["deleted"]), .deleted)
    }

    func testFullStateRelevésAreRecognisedByTheirDate() {
        XCTAssertTrue(ANFRMapPolicy.isFullStateDate("2022-05-20"))
        XCTAssertTrue(ANFRMapPolicy.isFullStateDate("2022-05-31"))
        XCTAssertFalse(ANFRMapPolicy.isFullStateDate("2025-10-09"))
        XCTAssertFalse(ANFRMapPolicy.isFullStateDate("2026-10-15"))
        XCTAssertFalse(ANFRMapPolicy.isFullStateDate("not-a-date"))
    }

    func testCityAndTechnologyAreRewrittenForReading() {
        XCTAssertEqual(ANFRText.city("ST REMY EN ROLLAT"), "St Remy en Rollat")
        XCTAssertEqual(ANFRText.city("SAINT-JEAN-DE-LUZ"), "Saint-Jean-de-Luz")
        XCTAssertEqual(ANFRText.city("L'ISLE-D'ABEAU"), "L’Isle-d’Abeau")
        XCTAssertEqual(ANFRText.city("  "), "")
        XCTAssertEqual(ANFRText.technology(system: "LTE 700", generation: "4G"), "4G 700")
        XCTAssertEqual(ANFRText.technology(system: "GSM 900", generation: ""), "GSM 900")
        let nr = ANFRText.technology(system: "5G NR 3500", generation: "5G")
        XCTAssertTrue(nr.hasPrefix("5G 3") && nr.hasSuffix("GHz"), nr)
        XCTAssertEqual(ANFRText.technology(system: "", generation: ""), "")
    }

    func testDatesAreSaidInTheServerTimeZone() {
        // Minuit UTC ne doit pas devenir la veille à l'ouest de Greenwich.
        let text = ANFRText.date("2026-10-08", month: .abbreviated, year: false)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("8") ?? false, text ?? "")
    }

    // MARK: Filtres

    func testFiltersCountsAndSitesWithAnUntrackedOperator() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        let model = await loadedModel(service)
        XCTAssertEqual(model.filteredSites.count, 5)
        XCTAssertEqual(model.modTypeCounts[.new], 1)
        XCTAssertEqual(model.modTypeCounts[.activated], 2)
        XCTAssertEqual(model.modTypeCounts[.deleted], 1)
        XCTAssertEqual(model.modTypeCounts[.added], 1)
        XCTAssertEqual(model.operatorCounts[.orange], 2)
        XCTAssertEqual(model.operatorCounts[.free], 2)
        XCTAssertEqual(model.operatorCounts[.sfr], 1)
        XCTAssertNil(model.operatorCounts[.bouygues])

        model.operatorFilters = [.free]
        await settle()
        // Le repère ne garde que les antennes de Free ; l'opérateur non suivi est écarté avec le filtre.
        XCTAssertEqual(model.filteredSites.map(\.supId).sorted(), ["2", "3"])
        XCTAssertEqual(model.filteredSites.first { $0.supId == "2" }?.antennas.count, 1)

        model.resetFilters()
        model.hidesCatchUp = true
        await settle()
        XCTAssertFalse(model.filteredSites.contains { $0.supId == "5" })
        XCTAssertEqual(model.filteredSites.count, 4)

        model.resetFilters()
        model.selectedGenerations = [.g5]
        await settle()
        XCTAssertEqual(model.filteredSites.map(\.supId), ["1"])
        XCTAssertEqual(model.activeFilterCount, 1)
        model.resetFilters()
        XCTAssertFalse(model.hasActiveFilters)
    }

    func testAnUntrackedOperatorKeepsANeutralMarkerStyle() {
        let style = ANFRMarkerStyle(site: site("4", "SAINT-PRIEST", [antenna("a5", "SRR", "activated")]))
        XCTAssertTrue(style.operators.isEmpty)
        XCTAssertNil(style.dominantOperator)
    }

    // MARK: Relevés

    func testThePreviousRelevéStaysDrawnWhileAnotherLoads() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot([site("1", "LYON", [antenna("a", "ORANGE", "new")])])
        service.snapshots["2026-10-08"] = snapshot(mixedSites)
        service.delays["2026-10-08"] = 300_000_000
        let model = await loadedModel(service)
        XCTAssertEqual(model.sites.count, 1)

        let pending = Task { await model.selectDate("2026-10-08") }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.sites.count, 1, "la carte n'est pas vidée pendant le chargement")
        XCTAssertNil(model.displayedDate)
        XCTAssertEqual(model.selectedDate, "2026-10-08")
        await pending.value
        XCTAssertEqual(model.sites.count, 5)
        XCTAssertEqual(model.displayedDate, "2026-10-08")
        XCTAssertFalse(model.isLoading)
    }

    func testAFailedLoadKeepsTheRelevéOnScreen() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.failing = ["2026-10-08"]
        let model = await loadedModel(service)
        await model.selectDate("2026-10-08")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.sites.count, 5)
        XCTAssertNil(model.displayedDate)
    }

    func testALateResponseForAnotherDateIsIgnored() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot([])
        service.snapshots["2026-10-01"] = snapshot([site("old", "OLD", [antenna("o", "ORANGE", "new")])])
        service.snapshots["2026-10-08"] = snapshot(mixedSites)
        service.delays["2026-10-01"] = 400_000_000
        service.delays["2026-10-08"] = 50_000_000
        let model = await loadedModel(service)
        let first = Task { await model.selectDate("2026-10-01") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await model.selectDate("2026-10-08")
        await first.value
        XCTAssertEqual(model.displayedDate, "2026-10-08")
        XCTAssertEqual(model.sites.count, 5)
    }

    func testGoingBackToAViewedWeekDoesNotDownloadItAgain() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.snapshots["2026-10-08"] = snapshot([site("1", "LYON", [antenna("a", "ORANGE", "new")])])
        let model = await loadedModel(service)
        await model.selectDate("2026-10-08")
        await model.selectDate(nil)
        await model.selectDate("2026-10-08")
        XCTAssertEqual(service.requests.count, 2, "un aller-retour entre deux semaines ne retélécharge rien")
        XCTAssertEqual(model.sites.count, 1)
    }

    func testAFullStateRelevéOpensTheLatestInstead() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        let model = await loadedModel(service)
        await model.selectDate("2022-05-20")
        XCTAssertNil(model.selectedDate)
        XCTAssertFalse(service.requests.contains { $0 == "2022-05-20" })
    }

    func testLatestRelevéRetriesAfterAFailedFirstLoad() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.failing = ["current"]
        let model = await loadedModel(service)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.hasLoadedSnapshot)
        service.failing = []
        await model.selectDate(nil)
        XCTAssertTrue(model.hasLoadedSnapshot)
        XCTAssertEqual(model.sites.count, 5)
        XCTAssertNil(model.errorMessage)
    }

    func testDatePickerHidesFullStateRelevésAndTheLatestOne() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.dates = ANFRArchiveDates(dates: ["2022-05-20", "2026-10-08", "2022-05-31", "2026-10-01"], current: "2026-10-15")
        let model = await loadedModel(service)
        XCTAssertEqual(model.selectableDates, ["2026-10-08", "2026-10-01"])
        XCTAssertTrue(model.hidesFullStateDates)
        XCTAssertEqual(model.dateSections.map(\.year), ["2026"])
        XCTAssertEqual(model.timeline, [nil, "2026-10-08", "2026-10-01"])
    }

    func testStepsBetweenWeeksAndStopsAtTheEnds() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.snapshots["2026-10-08"] = snapshot([])
        service.snapshots["2026-10-01"] = snapshot([])
        service.dates = ANFRArchiveDates(dates: ["2026-10-08", "2026-10-01"], current: "2026-10-15")
        let model = await loadedModel(service)
        XCTAssertFalse(model.canStepNewer)
        XCTAssertTrue(model.canStepOlder)
        await model.step(1)
        XCTAssertEqual(model.selectedDate, "2026-10-08")
        await model.step(1)
        XCTAssertEqual(model.selectedDate, "2026-10-01")
        XCTAssertFalse(model.canStepOlder)
        await model.step(1)
        XCTAssertEqual(model.selectedDate, "2026-10-01")
        await model.step(-1)
        await model.step(-1)
        XCTAssertNil(model.selectedDate)
    }

    func testWeekBarsGoFromTheOldestToTheLatestRelevé() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.dates = ANFRArchiveDates(dates: ["2026-10-08", "2026-10-01"], current: "2026-10-15")
        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 3, added: 0, activated: 2, deleted: 0),
                         ANFRWeekSummary(date: "2022-05-20", new: 99, added: 0, activated: 0, deleted: 0)]
        let model = await loadedModel(service)
        XCTAssertEqual(model.weekBars.map(\.date), ["2026-10-01", "2026-10-08", nil])
        XCTAssertEqual(model.weekBars[1].total, 5)
        XCTAssertNil(model.weekBars[0].total, "sans compteur serveur, pas de hauteur inventée")
        XCTAssertEqual(model.weekBars[2].total, 6, "le dernier relevé compte ses antennes")
        XCTAssertEqual(model.weekBars[2].displayDate, "2026-10-15")
    }

    // MARK: Ouverture ciblée

    func testAFocusOpensTheAnnouncedWeekAndTheZone() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot([])
        service.snapshots["2026-10-08"] = snapshot(mixedSites)
        service.dates = ANFRArchiveDates(dates: ["2026-10-08"], current: "2026-10-15")
        let model = ANFRMapViewModel(service: service)
        await model.load(focus: ANFRFocus.parse(date: "2026-10-08", latitude: "45.76", longitude: "4.83", radiusMeters: "2000"))
        XCTAssertEqual(model.displayedDate, "2026-10-08")
        XCTAssertEqual(model.sites.count, 5)
        XCTAssertEqual(model.zone?.radiusMeters, 2000)
        XCTAssertEqual(model.cameraRequest.id, 1)
    }

    func testAFocusOnAnUnknownOrFullStateWeekOpensTheLatest() async {
        for date in ["2022-05-20", "2024-01-04", "2026-10-15"] {
            let service = FakeService()
            service.snapshots["current"] = snapshot(mixedSites)
            service.dates = ANFRArchiveDates(dates: ["2022-05-20", "2026-10-08"], current: "2026-10-15")
            let model = ANFRMapViewModel(service: service)
            await model.load(focus: ANFRFocus.parse(date: date, latitude: nil, longitude: nil, radiusMeters: nil))
            XCTAssertNil(model.selectedDate, date)
            XCTAssertEqual(model.sites.count, 5, date)
            XCTAssertNil(model.zone, date)
        }
    }

    // MARK: Liste

    func testTheListSearchesCityCodeAndAddressWithoutCaseOrAccents() {
        let sites = [
            site("29847", "BRANNENS", [antenna("a", "ORANGE", "activated")]),
            site("555", "ÉCULLY", [antenna("b", "FREE MOBILE", "new")]),
            ANFRMapSite(supId: "9", latitude: 45, longitude: 5, city: "LYON", antennas: [
                ANFRMapAntenna(id: "c", supId: nil, operatorRaw: "SFR", system: "", generationRaw: "", modTypeRaw: "added",
                               statut: "", dateMaj: "", latitude: nil, longitude: nil, city: nil, address: "12 rue de la République")
            ])
        ]
        func ids(_ query: String, _ sort: ANFRSiteListSort = .type) -> [String] {
            ANFRSiteList.rows(from: sites, query: query, sort: sort, origin: nil).map(\.id)
        }
        XCTAssertEqual(ids("ecully"), ["555"])
        XCTAssertEqual(ids("298"), ["29847"])
        XCTAssertEqual(ids("REPUBLIQUE"), ["9"])
        XCTAssertEqual(ids("zzz"), [])
        XCTAssertEqual(ids("", .type).first, "555", "le type le plus marquant d'abord")
        XCTAssertEqual(ids("", .city), ["29847", "555", "9"].sorted { lhs, rhs in
            let names = ["29847": "Brannens", "555": "Écully", "9": "Lyon"]
            return names[lhs]!.localizedStandardCompare(names[rhs]!) == .orderedAscending
        })
    }

    func testTheListSortsByDistanceFromTheOrigin() {
        let near = ANFRMapSite(supId: "near", latitude: 45.001, longitude: 5.0, city: "A", antennas: [antenna("n", "ORANGE", "new")])
        let far = ANFRMapSite(supId: "far", latitude: 46.0, longitude: 5.0, city: "B", antennas: [antenna("f", "ORANGE", "new")])
        let rows = ANFRSiteList.rows(from: [far, near], query: "", sort: .distance, origin: CLLocationCoordinate2D(latitude: 45, longitude: 5))
        XCTAssertEqual(rows.map(\.id), ["near", "far"])
        XCTAssertLessThan(rows[0].distance ?? .infinity, rows[1].distance ?? 0)
    }

    // MARK: Fiche

    func testSharedTextUsesTheCommonLinePrefixesAndAPointDecimal() {
        let shared = ANFRSiteDetailSheet.shareText(
            for: ANFRMapSite(supId: "29847", latitude: 44.5297, longitude: -0.1806, city: "BRANNENS",
                             antennas: [antenna("a", "ORANGE", "new")]),
            baseURL: URL(string: "https://signalquest.fr/")!
        )
        let lines = shared.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Support ANFR 29847 (Brannens)")
        XCTAssertTrue(lines.contains("Opérateur: Orange"))
        XCTAssertTrue(lines.contains("Support: 29847"))
        XCTAssertTrue(lines.contains("Marché: FR"))
        XCTAssertTrue(lines.contains("Position: 44.52970, -0.18060"))
        XCTAssertTrue(lines.contains("Lien: https://signalquest.fr/carte?lat=44.52970&lng=-0.18060&siteId=29847&market=FR&open=antenna"))
        XCTAssertEqual(ANFRSiteDetailSheet.cartoradioURL(ANFRMapSite(supId: "1", latitude: 44.5297, longitude: -0.1806, city: "", antennas: []))?.absoluteString,
                       "https://cartoradio.fr/index.html#/cartographie/lonlat/-0.18060/44.52970")
    }

    // MARK: Caches

    func testTheDiskCacheKeepsOnlyTheNewestRelevés() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anfr-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ANFRSnapshotDiskCache(directory: directory, maxFiles: 2)
        for key in ["2026-10-01", "2026-10-08", "2026-10-15"] {
            cache.write(Data(key.utf8), key: key)
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNil(cache.read(key: "2026-10-01"))
        XCTAssertEqual(cache.read(key: "2026-10-15"), Data("2026-10-15".utf8))
        XCTAssertEqual(cache.read(key: "2026-10-08"), Data("2026-10-08".utf8))
    }

    func testServiceReadsADatedRelevéFromDiskAndFallsBackToTheCopyOfTheLatest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anfr-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-anfr-map-reader")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let body = Data("""
        {"source":"archive","snapshotDate":"2026-10-08","siteCount":1,"sites":[
         {"info":{"sup_id":"1","lat":"45.0","lon":"5.0","city":"LYON"},"antennas":[{"id":"a","adm_lb_nom":"ORANGE","type":"new"}]}]}
        """.utf8)
        let seen = LockedRequests()
        let offline = LockedFlag()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            if offline.value { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, body)
        }
        let service = ANFRService(api: api, diskCache: ANFRSnapshotDiskCache(directory: directory))

        let first = try await service.mapSnapshot(date: "2026-10-08")
        XCTAssertEqual(first.sites.count, 1)
        let second = try await service.mapSnapshot(date: "2026-10-08")
        XCTAssertEqual(second.sites.count, 1)
        XCTAssertEqual(seen.all.count, 1, "un relevé daté est immuable : lu sur le disque la seconde fois")

        _ = try await service.mapSnapshot(date: nil)
        offline.value = true
        let copy = try await service.mapSnapshot(date: nil)
        XCTAssertTrue(copy.servedFromCache)
        XCTAssertEqual(copy.sites.count, 1)
        do {
            _ = try await service.mapSnapshot(date: "2026-10-01")
            XCTFail("sans copie ni réseau, l'erreur remonte")
        } catch {
            XCTAssertFalse(error.isCancellation)
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
