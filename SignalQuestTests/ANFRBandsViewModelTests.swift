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
        var reorientationWeeks: [String: ANFRReorientationsWeek] = [:]
        var liteSnapshots: [String: ANFRMapSnapshot] = [:]
        var diffs: [String: ANFRMapDiff] = [:]
        var diffError: Error?
        private var liteRequested: [String] = []

        var requests: [String?] { lock.withLock { requested } }
        var liteRequests: [String] { lock.withLock { liteRequested } }

        func mapSnapshotLite(date: String) async throws -> ANFRMapSnapshot {
            lock.withLock { liteRequested.append(date) }
            guard let snapshot = liteSnapshots[date] else { throw URLError(.fileDoesNotExist) }
            return snapshot
        }

        func mapDiff(from: String, to: String?) async throws -> ANFRMapDiff {
            if let diffError { throw diffError }
            guard let diff = diffs["\(from)|\(to ?? "current")"] else { throw URLError(.fileDoesNotExist) }
            return diff
        }

        func reorientations(date: String?) async throws -> ANFRReorientationsWeek? {
            reorientationWeeks[date ?? "current"]
        }

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
        XCTAssertEqual(dominant(["modified", "deleted"]), .modified)
        XCTAssertEqual(dominant(["modified", "activated"]), .activated)
    }

    /// `modified` (retour d'« En service » à un projet) a son propre type, et non « ajoutée ».
    func testModifiedIsItsOwnTypeAndCountedInTheWeek() throws {
        XCTAssertEqual(ANFRModType.from(raw: "modified"), .modified)
        XCTAssertEqual(ANFRModType.from(raw: "inconnu"), .added)
        let json = #"{"weeks":[{"date":"2026-10-15","counts":{"new":1,"modified":3}}]}"#
        let week = try XCTUnwrap(JSONDecoder().decode(ANFRArchiveWeeks.self, from: Data(json.utf8)).weeks.first)
        XCTAssertEqual(week.count(for: .modified), 3)
        XCTAssertEqual(week.total, 4)
        let served = #"{"weeks":[{"date":"2026-10-15","counts":{"new":1,"modified":3},"total":1}]}"#
        let servedWeek = try XCTUnwrap(JSONDecoder().decode(ANFRArchiveWeeks.self, from: Data(served.utf8)).weeks.first)
        XCTAssertEqual(servedWeek.total, 4, "le total du serveur ne compte pas les antennes repassées en projet")
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

    /// Le bouton Partager et l'envoi en conversation écrivent le même texte : le format commun
    /// au web, à iOS et à Android (P2-47).
    func testSharedTextUsesTheCommonFormatAndAPointDecimal() {
        let shared = ANFRSiteDetailSheet.conversationShareText(
            for: ANFRMapSite(supId: "29847", latitude: 44.5297, longitude: -0.1806, city: "BRANNENS",
                             antennas: [antenna("a", "ORANGE", "new")]),
            baseURL: URL(string: "https://signalquest.fr/")!
        )
        let lines = shared.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Antenne Orange")
        XCTAssertTrue(lines.contains("Opérateur: Orange"))
        XCTAssertTrue(lines.contains("Support: 29847"))
        XCTAssertTrue(lines.contains("Marché: FR"))
        XCTAssertTrue(lines.contains("Position: 44.52970, -0.18060"))
        XCTAssertTrue(lines.contains("Lien: https://signalquest.fr/carte?lat=44.52970&lng=-0.18060&siteId=29847&market=FR&operator=ORANGE&open=antenna"))
        XCTAssertFalse(shared.contains("Support ANFR"), "plus de second format")
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

    /// Un relevé relu récemment survit à un relevé écrit plus tard mais jamais consulté.
    func testTheDiskCacheEvictsTheLeastRecentlyUsedRelevé() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anfr-cache-lru-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ANFRSnapshotDiskCache(directory: directory, maxFiles: 2)
        cache.write(Data("a".utf8), key: "2026-10-01")
        Thread.sleep(forTimeInterval: 0.05)
        cache.write(Data("b".utf8), key: "2026-10-08")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNotNil(cache.read(key: "2026-10-01"), "relu : devient le plus récent")
        Thread.sleep(forTimeInterval: 0.05)
        cache.write(Data("c".utf8), key: "2026-10-15")
        XCTAssertNotNil(cache.read(key: "2026-10-01"))
        XCTAssertNil(cache.read(key: "2026-10-08"), "le moins récemment utilisé part")
        XCTAssertNotNil(cache.read(key: "2026-10-15"))
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

// MARK: - Azimuts et réorientations (ANFR-AZ)

@MainActor
extension ANFRMapViewModelTests {
    func testAzimuthsAreReadAsNumbersOrStringsSortedAndDeduplicated() throws {
        let json = """
        {"sites":[{"info":{"sup_id":"1","lat":"45.0","lon":"5.0","city":"LYON"},"antennas":[
          {"id":"a","adm_lb_nom":"ORANGE","type":"new","azimuts":["240",360,120.4,"x",120,-5,400]},
          {"id":"b","adm_lb_nom":"ORANGE","type":"added","azimuts":[30]},
          {"id":"c","adm_lb_nom":"SFR","type":"added"}]}]}
        """
        let site = try XCTUnwrap(JSONDecoder().decode(ANFRMapSnapshot.self, from: Data(json.utf8)).sites.first)
        XCTAssertEqual(site.antennas[0].azimuths, [0, 120, 240], "360 se lit 0 ; les valeurs illisibles ou hors bornes partent")
        XCTAssertEqual(site.antennas[2].azimuths, [], "une copie sans azimut reste lisible")
        XCTAssertEqual(site.sectorsByOperator, [ANFRSiteSectors(operator: .orange, azimuths: [0, 30, 120, 240])],
                       "un opérateur sans azimut publié n'a pas d'éventail")
        XCTAssertEqual(ANFRAzimuth.list([0, 120]), "0°, 120°")
    }

    func testTheWeekCarriesItsReorientationsOutsideTheTotal() throws {
        let json = #"{"weeks":[{"date":"2026-10-08","counts":{"new":2,"added":1,"activated":0,"deleted":0},"total":3,"reoriented":17},{"date":"2026-10-01","counts":{"new":1},"total":1}]}"#
        let weeks = try JSONDecoder().decode(ANFRArchiveWeeks.self, from: Data(json.utf8)).weeks
        XCTAssertEqual(weeks[0].total, 3)
        XCTAssertEqual(weeks[0].reoriented, 17)
        XCTAssertNil(weeks[1].reoriented, "absent tant que la semaine n'est pas calculée")
    }

    func testReorientationsJoinTheOperatorsOfASharedSite() throws {
        let json = """
        {"date":"2026-10-15","previousDate":"2026-10-08","requestId":"r","reorientations":[
          {"sup_id":"120044","lat":"48.8566","lon":"2.3522","city":"PARIS","operator":"FREE MOBILE","systems":["5G NR 700"],"before":[10,130,250],"after":[0,120,"240"]},
          {"sup_id":"120044","lat":"48.8566","lon":"2.3522","city":"PARIS","operator":"ORANGE","systems":["LTE 800"],"before":[40],"after":[60]},
          {"sup_id":"9","lat":"","lon":"","city":"NULLE PART","operator":"SFR","systems":[],"before":[1],"after":[2]},
          {"lat":"45","lon":"5","operator":"SFR","before":[],"after":[]}]}
        """
        let week = try JSONDecoder().decode(ANFRReorientationsWeek.self, from: Data(json.utf8))
        XCTAssertEqual(week.previousDate, "2026-10-08")
        XCTAssertEqual(week.reorientations.count, 3, "une ligne sans support est écartée")
        XCTAssertEqual(week.reorientations[0].after, [0, 120, 240])
        XCTAssertEqual(week.reorientations[0].latitude, 48.8566, accuracy: 0.000_1)
        XCTAssertNotEqual(week.reorientations[0].id, week.reorientations[1].id, "un support partagé revient une fois par opérateur")
        let sites = week.sites
        XCTAssertEqual(sites.map(\.supId), ["120044"], "un support sans position valide n'a pas de repère")
        XCTAssertEqual(sites[0].operators, [.orange, .free])
        XCTAssertEqual(sites[0].sectorsByOperator.first { $0.operator == .free }?.azimuths, [0, 120, 240])
    }

    func testTheReorientationLayerDrawsReorientedSitesFilteredByOperator() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 1, added: 0, activated: 0, deleted: 0, reoriented: 4)]
        service.dates = ANFRArchiveDates(dates: ["2026-10-08"], current: "2026-10-15")
        service.reorientationWeeks["current"] = ANFRReorientationsWeek(date: "2026-10-15", previousDate: "2026-10-08", reorientations: [
            ANFRReorientation(supId: "2", latitude: 45, longitude: 5, city: "VILLEURBANNE", operatorRaw: "ORANGE", systems: [], before: [10], after: [20]),
            ANFRReorientation(supId: "2", latitude: 45, longitude: 5, city: "VILLEURBANNE", operatorRaw: "FREE MOBILE", systems: [], before: [10], after: [30]),
            ANFRReorientation(supId: "77", latitude: 46, longitude: 4, city: "MÂCON", operatorRaw: "SFR", systems: [], before: [90], after: [100])
        ])
        let model = await loadedModel(service)
        XCTAssertEqual(model.filteredSites.count, mixedSites.count)

        model.layer = .reorientations
        await model.loadReorientations()
        XCTAssertEqual(model.reorientationState, .loaded)
        XCTAssertEqual(Set(model.filteredSites.map(\.supId)), ["2", "77"])
        XCTAssertEqual(model.reorientations(supId: "2").count, 2)
        XCTAssertEqual(model.weekBars.map(\.total), [4, 2], "les barres comptent les supports réorientés")
        XCTAssertEqual(model.operatorCounts[.orange], 1)

        model.toggleOperator(.sfr)
        await settle()
        XCTAssertEqual(model.filteredSites.map(\.supId), ["2"])
        XCTAssertEqual(model.activeFilterCount, 1)

        model.layer = .changes
        XCTAssertEqual(model.weekBars.map(\.total), [1, 6], "retour aux changements et aux antennes du relevé")
        XCTAssertFalse(model.filteredSites.contains { $0.supId == "77" }, "la couche des changements ne montre que le relevé")
    }

    func testAWeekWithoutKnownReorientationsSaysSo() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        let model = await loadedModel(service)
        model.layer = .reorientations
        await model.loadReorientations()
        XCTAssertEqual(model.reorientationState, .unknown)
        XCTAssertTrue(model.filteredSites.isEmpty)
        XCTAssertNil(model.currentWeekReoriented)
    }

    func testTheServiceReadsAMissingWeekAsNoKnownReorientation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-anfr-reorientation-reader")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let seen = LockedRequests()
        let missing = LockedFlag()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            if missing.value {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!,
                        Data(#"{"code":"NOT_FOUND","message":"x","requestId":"r"}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"date":"2026-10-08","previousDate":"2026-10-01","reorientations":[],"requestId":"r"}"#.utf8))
        }
        let service = ANFRService(api: api)
        let week = try await service.reorientations(date: "2026-10-08")
        XCTAssertEqual(week?.date, "2026-10-08")
        let url = try XCTUnwrap(seen.all.first?.0.url)
        XCTAssertEqual(url.path, "/api/anfr/reorientations")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "date", value: "2026-10-08")])
        missing.value = true
        let none = try await service.reorientations(date: "2026-09-01")
        XCTAssertNil(none)
    }

    // MARK: Relevé léger et comparaison (ANFR-MAP v1.1)

    private func liteSite(_ supId: String, _ operators: [ANFROperator], _ counts: [ANFRModType: Int],
                          other: Bool = false, catchUp: Int = 0) -> ANFRMapSite {
        ANFRMapSite(supId: supId, latitude: 45, longitude: 5, city: "LYON", antennas: [], summary: ANFRSiteChangeSummary(
            operators: operators, hasOtherOperator: other, counts: counts, catchUp: catchUp, lastChangeDate: "2026-10-08"
        ))
    }

    func testDecodesALiteSnapshotWithoutAntennas() throws {
        let json = """
        {"source":"archive","snapshotDate":"2022-05-20","lastUpdate":"x","fields":"lite","siteCount":3,"antennaCount":169742,"sites":[
          {"supId":"29847","lat":44.5297,"lon":-0.1806,"city":"BRANNENS","operators":["FREE MOBILE","ORANGE","TDF"],
           "changes":{"new":0,"added":2,"activated":5,"deleted":0,"modified":1},"catchUp":3},
          {"supId":"7","lat":"45.1","lon":"5.1","city":null,"operators":[],"changes":{"new":1},"catchUp":0},
          {"supId":"8","lat":null,"lon":5,"operators":["SFR"],"changes":{"new":1},"catchUp":0}]}
        """
        let snapshot = try JSONDecoder.signalQuest.decode(ANFRMapSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.isLite)
        XCTAssertEqual(snapshot.antennaCount, 169_742, "le poids annoncé par le serveur, pas un recomptage")
        XCTAssertEqual(snapshot.sites.map(\.supId), ["29847", "7"], "un support sans position n'a pas de repère")
        let site = snapshot.sites[0]
        XCTAssertTrue(site.antennas.isEmpty)
        XCTAssertEqual(site.operators, [.orange, .free])
        XCTAssertEqual(site.summary?.hasOtherOperator, true)
        XCTAssertEqual(site.summary?.count(for: .activated), 5)
        XCTAssertEqual(site.summary?.catchUp, 3)
        XCTAssertEqual(site.changeCount, 8)
        XCTAssertEqual(site.dominantModType, .added, "même priorité que le relevé complet")
        XCTAssertEqual(site.dominantOperator, .orange)
        XCTAssertNil(site.highestGeneration)
        XCTAssertEqual(snapshot.sites[1].city, "")

        let full = try JSONDecoder.signalQuest.decode(ANFRMapSnapshot.self, from: Data(#"{"sites":[]}"#.utf8))
        XCTAssertFalse(full.isLite)
    }

    func testDecodesAComparisonAndTheWeightOfAWeek() throws {
        let json = """
        {"from":"2026-09-17","to":"current","weeks":["2026-09-24","2026-10-01"],"siteCount":1,"antennaCount":4,"sites":[
          {"supId":"5","lat":45,"lon":5,"city":"LYON","operators":["SFR"],"changes":{"new":0,"added":0,"activated":3,"deleted":1,"modified":0},
           "catchUp":0,"lastChangeDate":"2026-10-01"}]}
        """
        let diff = try JSONDecoder.signalQuest.decode(ANFRMapDiff.self, from: Data(json.utf8))
        XCTAssertEqual(diff.weeks, ["2026-09-24", "2026-10-01"])
        XCTAssertEqual(diff.sites.first?.summary?.lastChangeDate, "2026-10-01")
        XCTAssertTrue(diff.snapshot.isLite)
        XCTAssertEqual(diff.snapshot.antennaCount, 4)

        let week = try JSONDecoder.signalQuest.decode(ANFRWeekSummary.self, from: Data(
            #"{"date":"2022-05-20","counts":{"new":10,"added":0,"activated":0,"deleted":0,"catchUp":0},"total":10,"siteCount":25860,"antennaCount":169742}"#.utf8
        ))
        XCTAssertEqual(week.siteCount, 25_860)
        XCTAssertEqual(week.antennaCount, 169_742)
    }

    /// Corps servis par la prod le 19/10 (a24e00cc5), `dates` et `sites` réduits.
    func testDecodesTheServedLiteFormatAndComparison() throws {
        let archives = """
        {"dates":["2026-10-08","2026-10-07","2026-10-01"],"current":"2026-10-15","weeks":[
          {"date":"2026-10-08","counts":{"new":6,"added":20,"activated":82,"deleted":62,"catchUp":33,"modified":0},"total":170,"siteCount":55,"antennaCount":170},
          {"date":"2026-10-07","counts":{"new":465,"added":390,"activated":534,"deleted":1955,"catchUp":94,"modified":0},"total":3344,"siteCount":2159,"antennaCount":3344},
          {"date":"2026-10-01","counts":{"new":428,"added":353,"activated":982,"deleted":739,"catchUp":114,"modified":1},"total":2502,"siteCount":852,"antennaCount":2503}],
         "requestId":"e52f8982"}
        """
        let weeks = try JSONDecoder.signalQuest.decode(ANFRArchiveWeeks.self, from: Data(archives.utf8)).weeks
        XCTAssertEqual(weeks.map(\.date), ["2026-10-08", "2026-10-07", "2026-10-01"])
        XCTAssertEqual(weeks.map(\.siteCount), [55, 2159, 852], "le serveur annonce le format léger")
        XCTAssertEqual(weeks.last?.antennaCount, 2503)

        let lite = """
        {"source":"archive","snapshotDate":"2026-10-08","lastUpdate":"08 oct. 2026","fields":"lite","siteCount":55,"antennaCount":170,"sites":[
          {"supId":"444456","lat":48.684999999999995,"lon":-1.3619444444444446,"city":"AVRANCHES","operators":["ORANGE"],"changes":{"new":0,"added":0,"activated":1,"deleted":0,"modified":0},"catchUp":0},
          {"supId":"465938","lat":49.11083333333333,"lon":6.173055555555556,"city":"METZ","operators":["ORANGE"],"changes":{"new":0,"added":0,"activated":4,"deleted":0,"modified":0},"catchUp":0}]}
        """
        let snapshot = try JSONDecoder.signalQuest.decode(ANFRMapSnapshot.self, from: Data(lite.utf8))
        XCTAssertTrue(snapshot.isLite)
        XCTAssertEqual(snapshot.antennaCount, 170)
        XCTAssertEqual(snapshot.sites.map(\.supId), ["444456", "465938"])
        XCTAssertEqual(snapshot.sites[1].operators, [.orange])
        XCTAssertEqual(snapshot.sites[1].summary?.count(for: .activated), 4)

        let diff = """
        {"from":"2026-10-07","to":"current","weeks":["2026-10-08","2026-10-15"],"siteCount":4761,"antennaCount":6363,"sites":[
          {"supId":"29489","lat":44.52583333333333,"lon":-0.10555555555555556,"city":"SAVIGNAC","operators":["SFR"],"changes":{"new":0,"added":0,"activated":0,"deleted":1,"modified":0},"catchUp":0,"lastChangeDate":"2026-10-15"},
          {"supId":"36929","lat":47.7175,"lon":7.166666666666667,"city":"BURNHAUPT LE BAS","operators":["BOUYGUES TELECOM"],"changes":{"new":0,"added":0,"activated":0,"deleted":2,"modified":0},"catchUp":0,"lastChangeDate":"2026-10-15"}],
         "requestId":"5e9e7b11"}
        """
        let comparison = try JSONDecoder.signalQuest.decode(ANFRMapDiff.self, from: Data(diff.utf8))
        XCTAssertEqual(comparison.weeks, ["2026-10-08", "2026-10-15"])
        XCTAssertEqual(comparison.siteCount, 4761)
        XCTAssertEqual(comparison.antennaCount, 6363, "le poids annoncé, pas le recomptage des sites reçus")
        XCTAssertEqual(comparison.sites[1].operators, [.bouygues])
        XCTAssertEqual(comparison.sites[1].dominantModType, .deleted)
        XCTAssertEqual(comparison.sites[1].summary?.lastChangeDate, "2026-10-15")
        XCTAssertTrue(comparison.snapshot.isLite)
    }

    func testTheOld2022RelevésOpenInLiteOnlyWhenTheServerOffersIt() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.dates = ANFRArchiveDates(dates: ["2026-10-08", "2022-05-31", "2022-05-20"], current: "2026-10-15")
        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 1, added: 0, activated: 0, deleted: 0)]
        var model = await loadedModel(service)
        XCTAssertFalse(model.supportsLite)
        XCTAssertEqual(model.selectableDates, ["2026-10-08"])
        XCTAssertTrue(model.hidesFullStateDates)

        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 1, added: 0, activated: 0, deleted: 0, siteCount: 1, antennaCount: 1)]
        service.liteSnapshots["2022-05-20"] = ANFRMapSnapshot(source: "archive", snapshotDate: "2022-05-20", lastUpdate: nil,
                                                              sites: [liteSite("9", [.sfr], [.new: 4])], isLite: true)
        model = await loadedModel(service)
        XCTAssertTrue(model.supportsLite)
        XCTAssertEqual(model.selectableDates, ["2026-10-08", "2022-05-31", "2022-05-20"])
        XCTAssertFalse(model.hidesFullStateDates)
        await model.selectDate("2022-05-20")
        XCTAssertEqual(service.liteRequests, ["2022-05-20"])
        XCTAssertFalse(service.requests.contains("2022-05-20"), "jamais le relevé complet de 2022")
        XCTAssertTrue(model.displaysLite)
        XCTAssertEqual(model.filteredSites.map(\.supId), ["9"])
    }

    func testLiteSitesFilterAsAWholeAndIgnoreTheGenerationFilter() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.dates = ANFRArchiveDates(dates: ["2026-10-08", "2026-10-01"], current: "2026-10-15")
        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 1, added: 0, activated: 0, deleted: 0, siteCount: 1)]
        service.diffs["2026-10-01|current"] = ANFRMapDiff(from: "2026-10-01", to: "current", weeks: ["2026-10-08", "2026-10-15"], sites: [
            liteSite("A", [.orange, .free], [.activated: 2, .new: 1]),
            liteSite("B", [.sfr], [.deleted: 1]),
            liteSite("C", [], [.added: 1], other: true),
            liteSite("D", [.bouygues], [.activated: 2], catchUp: 2),
            liteSite("E", [.bouygues], [.activated: 2], catchUp: 1)
        ])
        let model = await loadedModel(service)
        model.selectedGenerations = [.g5]
        await settle()
        let fullCount = model.filteredSites.count
        await model.compare(from: "2026-10-01", to: nil)
        XCTAssertEqual(model.displayedComparison, ANFRComparison(from: "2026-10-01", to: nil))
        XCTAssertEqual(model.filteredSites.count, 5, "la génération ne filtre pas un relevé léger")
        XCTAssertEqual(model.activeFilterCount, 0)
        XCTAssertEqual(model.comparisonWeeks, ["2026-10-08", "2026-10-15"])
        XCTAssertEqual(model.weekBars.filter(\.inComparison).map(\.date), ["2026-10-08", nil])
        XCTAssertNotEqual(fullCount, 0)

        model.toggleOperator(.sfr)
        model.toggleOperator(.bouygues)
        await settle()
        XCTAssertEqual(model.filteredSites.map(\.supId), ["A"], "un opérateur non suivi disparaît dès qu'un opérateur est écarté")
        XCTAssertEqual(model.modTypeCounts[.new], 1)

        model.resetFilters()
        model.selectedModTypes = [.deleted]
        await settle()
        XCTAssertEqual(model.filteredSites.map(\.supId), ["B"])

        model.resetFilters()
        model.hidesCatchUp = true
        await settle()
        XCTAssertEqual(Set(model.filteredSites.map(\.supId)), ["A", "B", "C", "E"], "seul un support tout en rattrapage disparaît")
    }

    func testAComparisonForcesTheChangesLayerAndEndsOnADateChoice() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.snapshots["2026-10-08"] = snapshot([site("8", "BRON", [antenna("x", "SFR", "new")])])
        service.dates = ANFRArchiveDates(dates: ["2026-10-08", "2026-10-01"], current: "2026-10-15")
        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 1, added: 0, activated: 0, deleted: 0, siteCount: 1)]
        service.diffs["2026-10-01|2026-10-08"] = ANFRMapDiff(from: "2026-10-01", to: "2026-10-08", weeks: ["2026-10-08"],
                                                             sites: [liteSite("A", [.orange], [.new: 1])])
        let model = await loadedModel(service)
        model.layer = .reorientations
        await model.compare(from: "2026-10-01", to: "2026-10-08")
        XCTAssertEqual(model.layer, .changes)
        model.layer = .reorientations
        XCTAssertEqual(model.layer, .changes, "les réorientations sont celles d'une semaine")
        XCTAssertEqual(model.filteredSites.map(\.supId), ["A"])
        XCTAssertNotNil(model.comparisonLabel)

        await model.endComparison()
        XCTAssertNil(model.comparison)
        XCTAssertFalse(model.displaysLite)
        XCTAssertEqual(model.filteredSites.count, mixedSites.count)

        await model.compare(from: "2026-10-01", to: "2026-10-08")
        await model.selectDate("2026-10-08")
        XCTAssertNil(model.comparison)
        XCTAssertEqual(model.filteredSites.map(\.supId), ["8"])
    }

    func testComparisonBoundsFollowTheServerCeiling() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot([])
        var ascending: [String] = []
        for index in 0..<30 {
            ascending.append(String(format: "2026-%02d-%02d", 1 + index / 28, 1 + index % 28))
        }
        let dates: [String] = ascending.reversed()
        service.dates = ANFRArchiveDates(dates: dates, current: "2026-10-15")
        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 1, added: 0, activated: 0, deleted: 0, siteCount: 1)]
        let model = await loadedModel(service)
        let starts = model.comparisonStarts(to: nil)
        XCTAssertEqual(starts.count, ANFRMapPolicy.maxComparedWeeks)
        XCTAssertEqual(starts.first, dates.first)
        XCTAssertEqual(model.comparisonEnds.first, .some(nil), "le dernier relevé d'abord")
        XCTAssertFalse(model.comparisonEnds.contains(.some(dates.last!)), "le plus ancien n'a rien avant lui")
        let older = model.comparisonStarts(to: dates.first)
        XCTAssertFalse(older.contains(dates.first!))
        XCTAssertTrue(older.allSatisfy { $0 < dates.first! })
    }

    func testATooLongComparisonSaysTheCeiling() async {
        let service = FakeService()
        service.snapshots["current"] = snapshot(mixedSites)
        service.dates = ANFRArchiveDates(dates: ["2026-10-08", "2026-10-01"], current: "2026-10-15")
        service.weeks = [ANFRWeekSummary(date: "2026-10-08", new: 1, added: 0, activated: 0, deleted: 0, siteCount: 1)]
        service.diffError = APIError.http(status: 422, code: "RANGE_TOO_LONG", message: "x", requestId: nil, retryAfter: nil)
        let model = await loadedModel(service)
        await model.compare(from: "2026-10-01", to: nil)
        XCTAssertEqual(model.errorMessage, String(localized: "Compare au plus \(ANFRMapPolicy.maxComparedWeeks) relevés d’écart."))
        XCTAssertEqual(model.filteredSites.count, mixedSites.count, "le relevé affiché reste à l'écran")
    }

    func testTheServiceAsksForTheLiteFormatAndTheComparison() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-anfr-map-reader")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let seen = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            let body = request.url?.path == "/api/anfr/map-diff"
                ? #"{"from":"2026-10-01","to":"2026-10-08","weeks":["2026-10-08"],"siteCount":0,"antennaCount":0,"sites":[]}"#
                : #"{"fields":"lite","snapshotDate":"2022-05-20","siteCount":0,"antennaCount":0,"sites":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ANFRService(api: api, diskCache: ANFRSnapshotDiskCache(directory: directory))

        let lite = try await service.mapSnapshotLite(date: "2022-05-20")
        XCTAssertTrue(lite.isLite)
        _ = try await service.mapSnapshotLite(date: "2022-05-20")
        let diff = try await service.mapDiff(from: "2026-10-01", to: "2026-10-08")
        XCTAssertEqual(diff.weeks, ["2026-10-08"])
        _ = try await service.mapDiff(from: "2026-10-01", to: "2026-10-08")
        _ = try await service.mapDiff(from: "2026-10-01", to: nil)

        let urls = seen.all.compactMap(\.0.url)
        XCTAssertEqual(urls.count, 3, "un relevé léger daté et une comparaison figée se relisent du disque")
        func query(_ url: URL) -> [URLQueryItem] { URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        XCTAssertEqual(urls[0].path, "/api/anfr/map-snapshot")
        XCTAssertEqual(query(urls[0]), [URLQueryItem(name: "date", value: "2022-05-20"), URLQueryItem(name: "fields", value: "lite")])
        XCTAssertEqual(query(urls[1]), [URLQueryItem(name: "from", value: "2026-10-01"), URLQueryItem(name: "to", value: "2026-10-08")])
        XCTAssertEqual(query(urls[2]), [URLQueryItem(name: "from", value: "2026-10-01"), URLQueryItem(name: "to", value: "current")])
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

// MARK: - Comparateur de zone (CMP-1)

/// Requête, erreurs et états de l'onglet Antennes du comparateur d'opérateurs.
@MainActor
final class ANFRZoneCompareTests: XCTestCase {
    private final class ZoneService: ANFRServicing, @unchecked Sendable {
        struct Call: Equatable {
            let latitude: Double
            let longitude: Double
            let radius: Int
            let market: String
            let bands: Bool
        }
        private let lock = NSLock()
        private var recorded: [Call] = []
        var failure: Error?
        var calls: [Call] { lock.withLock { recorded } }

        func zoneCompare(latitude: Double, longitude: Double, radius: ANFRZoneRadius,
                         market: String, includeBands: Bool) async throws -> ANFRZoneCompare {
            lock.withLock {
                recorded.append(Call(latitude: latitude, longitude: longitude, radius: radius.kilometers,
                                     market: market, bands: includeBands))
            }
            if let failure { throw failure }
            let bands = includeBands ? [ANFRZoneBandCount(band: "B20", count: 3)] : nil
            return ANFRZoneCompare(
                market: market, activeDefinition: "def", snapshotDate: "2026-09-24", snapshotSource: "ANFR",
                radiusKm: radius.kilometers, totalActive: 10, totalPlanned: 2, totalByGeneration: .zero,
                operators: [ANFRZoneOperator(key: "ORANGE", active: 10, planned: 2, generations: .zero, bands: bands)]
            )
        }

        func current() async throws -> ANFRDataset { throw URLError(.unsupportedURL) }
        func archives() async throws -> [ANFRDataset] { throw URLError(.unsupportedURL) }
        func search(query: String) async throws -> [AntennaSite] { throw URLError(.unsupportedURL) }
        func siteHistory(supId: String) async throws -> ANFRSiteHistory { throw URLError(.unsupportedURL) }
        func stats() async throws -> ANFRStats { throw URLError(.unsupportedURL) }
        func bandStats(weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats {
            throw URLError(.unsupportedURL)
        }
        func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot { throw URLError(.unsupportedURL) }
        func archiveDates() async throws -> ANFRArchiveDates { throw URLError(.unsupportedURL) }
    }

    /// Un marché par code ; `nil` pour une position hors de tout marché.
    private struct FixedMarkets: MarketRegistryServicing {
        let code: String?
        func registry() async -> MarketRegistryPayload { .empty }
        func market(forCode code: String?) async -> MarketRegistryEntry? { entry(code) }
        func marketForLocation(latitude: Double, longitude: Double) async -> MarketRegistryEntry? { entry(code) }
        func marketAreaContainsLocation(marketCode: String?, latitude: Double, longitude: Double) -> Bool { false }
        func franceHysteresisContains(latitude: Double, longitude: Double) -> Bool { false }
        private func entry(_ code: String?) -> MarketRegistryEntry? {
            guard let code else { return nil }
            let json = ##"{"code":"\##(code)","marketCode":"\##(code)","label":"\##(code)","operators":[{"key":"ORANGE","label":"Orange","color":"#FF7900"}]}"##
            return try? JSONDecoder.signalQuest.decode(MarketRegistryEntry.self, from: Data(json.utf8))
        }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeModel(_ service: ZoneService, market: String? = "FR",
                           latitude: Double = 45.7640, longitude: Double = 4.8357) -> ZoneCompareModel {
        let model = ZoneCompareModel(latitude: latitude, longitude: longitude)
        model.attach(service: service, markets: FixedMarkets(code: market))
        return model
    }

    private func httpError(_ status: Int, _ code: String?) -> APIError {
        .http(status: status, code: code, message: "", requestId: "req", retryAfter: nil)
    }

    // MARK: Requête

    func testTheRequestCarriesTheCenterTheRadiusTierAndTheMarketOnAPublicRoute() throws {
        for tier in ANFRZoneRadius.presets {
            let endpoint = ANFRService.zoneCompareEndpoint(latitude: 45.76401, longitude: 4.83569, radius: tier,
                                                           market: "FR", includeBands: false)
            XCTAssertEqual(endpoint.path, "/api/anfr/zone-compare")
            XCTAssertTrue(endpoint.authenticated, "lecture ANFR de l'app : avec la session")
            let query = Dictionary(uniqueKeysWithValues: endpoint.query.map { ($0.name, $0.value ?? "") })
            // Le centre part sur la case de grille du serveur (pas = rayon × 0,001°), à quatre décimales.
            let expected = [20: ("45.7600", "4.8400"), 50: ("45.7500", "4.8500"), 100: ("45.8000", "4.8000")][tier.kilometers]
            XCTAssertEqual(query, ["lat": expected?.0 ?? "", "lon": expected?.1 ?? "", "radiusKm": String(tier.kilometers), "market": "FR"])
        }
        XCTAssertEqual(ANFRZoneRadius.presets.map(\.kilometers), [20, 50, 100])
        XCTAssertEqual(ANFRZoneRadius.default, .km50)
        // Échelle du serveur : au km jusqu'à 20, puis par pas de 5.
        XCTAssertEqual([0, 1, 7, 20, 21, 23, 24, 37, 38, 99, 140].map { ANFRZoneRadius(kilometers: $0).kilometers },
                       [1, 1, 7, 20, 20, 25, 25, 35, 40, 100, 100])
        XCTAssertEqual(ANFRZoneRadius.steps.count, 36)
        XCTAssertEqual(ANFRZoneRadius.km50.gridDegrees, 0.05, accuracy: 1e-9)
        XCTAssertEqual(ANFRZoneRadius(kilometers: 7).gridDegrees, 0.007, accuracy: 1e-9)
        let bands = ANFRService.zoneCompareEndpoint(latitude: -21.1, longitude: 55.5, radius: .km20, market: "DROM", includeBands: true)
        let names = bands.query.map(\.name)
        XCTAssertEqual(names, ["lat", "lon", "radiusKm", "market", "bands"])
        XCTAssertEqual(bands.query.first { $0.name == "bands" }?.value, "1")
        XCTAssertEqual(bands.query.first { $0.name == "lat" }?.value, "-21.1000", "Séparateur décimal fixe, quelle que soit la langue")
        // Un point déjà sur la grille ne bouge pas, et un point proche rejoint le même centre que côté serveur.
        XCTAssertEqual(ANFRZoneRadius.km20.snapped(45.76401), 45.76, accuracy: 1e-9)
        XCTAssertEqual(ANFRZoneRadius.km20.snapped(ANFRZoneRadius.km20.snapped(45.76401)), 45.76, accuracy: 1e-9)
        XCTAssertEqual(ANFRZoneRadius(kilometers: 1).snapped(4.83569), 4.836, accuracy: 1e-9)
        XCTAssertEqual(bands.query.first { $0.name == "market" }?.value, "DROM")
    }

    func testTheServiceDecodesTheServerAnswerOverTheWire() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-zone-reader")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let body = Data(#"{"market":"FR","total":{"active":4,"planned":1},"radiusKm":20,"operators":[{"key":"SFR","active":4}]}"#.utf8)
        let seen = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, body)
        }
        let zone = try await ANFRService(api: api).zoneCompare(latitude: 45.7, longitude: 4.8, radius: .km20,
                                                               market: "FR", includeBands: true)
        XCTAssertEqual(zone.totalActive, 4)
        XCTAssertEqual(zone.operators.map(\.key), ["SFR"])
        let url = try XCTUnwrap(seen.first?.0.url)
        XCTAssertEqual(url.path, "/api/anfr/zone-compare")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["lat": "45.7000", "lon": "4.8000", "radiusKm": "20", "market": "FR", "bands": "1"])
        XCTAssertNotNil(seen.first?.0.value(forHTTPHeaderField: "Cookie"), "la session part avec la demande")
    }

    /// Corps réel servi le 19/10 (Grenoble, 10 km, `bands=1`), deux opérateurs sur quatre.
    func testDecodesTheServedResponse() throws {
        let json = #"""
        {"market":"FR","unit":"site","activeDefinition":"statut ANFR « En service » ; « Techniquement opérationnel » et « Projet approuvé » sont comptés dans planned, jamais dans active","snapshot":{"date":"2026-09-30","source":"anfr-map"},"center":{"lat":45.19,"lon":5.72},"radiusKm":10,"total":{"active":274,"planned":29},"totalByGeneration":{"2G":158,"3G":201,"4G":274,"5G":261},"operators":[{"key":"BOUYGUES","active":103,"planned":12,"generations":{"2G":75,"3G":100,"4G":103,"5G":93},"bands":{"2G":{"GSM900":75},"3G":{"U1":1,"U900":100},"4G":{"B1":86,"B20":101,"B28":88,"B3":100,"B7":93},"5G":{"n1":93,"n78":80}}},{"key":"ORANGE","active":95,"planned":3,"generations":{"2G":51,"3G":74,"4G":95,"5G":88},"bands":{"2G":{"GSM900":51},"3G":{"U1":1,"U900":73},"4G":{"B1":92,"B20":91,"B28":45,"B3":93,"B7":88},"5G":{"n1":1,"n28":84,"n78":87}}}],"requestId":"r"}
        """#
        let zone = try JSONDecoder.signalQuest.decode(ANFRZoneCompare.self, from: Data(json.utf8))
        XCTAssertEqual(zone.snapshotDate, "2026-09-30")
        XCTAssertEqual(zone.radiusKm, 10)
        XCTAssertEqual(zone.totalActive, 274)
        XCTAssertEqual(zone.totalPlanned, 29)
        XCTAssertEqual(zone.totalByGeneration.g5, 261)
        XCTAssertEqual(zone.operators.map(\.key), ["BOUYGUES", "ORANGE"])
        let orange = try XCTUnwrap(zone.operators.last)
        XCTAssertEqual(orange.generations.g4, 95)
        let bands = ANFRZoneBandCount.sorted(orange.bands ?? [])
        XCTAssertEqual(bands.count, 11)
        XCTAssertEqual(bands.first?.band, "GSM900")
        XCTAssertEqual(bands.first { $0.band == "n28" }?.displayName, "5G 700")
        XCTAssertEqual(bands.first { $0.band == "U1" }?.megahertz, 2100)
        XCTAssertTrue(bands.allSatisfy { $0.generation != nil }, "toutes les bandes servies sont dans le registre")
    }

    // MARK: Erreurs

    func testServerErrorsMapToTheirStates() async throws {
        XCTAssertEqual(ZoneCompareModel.phase(for: httpError(404, nil)), .failed, "Une route absente est une panne : avec « Réessayer »")
        XCTAssertEqual(ZoneCompareModel.phase(for: httpError(404, "NOT_FOUND")), .failed)
        XCTAssertEqual(ZoneCompareModel.phase(for: httpError(422, "MARKET_NO_ANTENNA_DATA")), .noAntennaData)
        XCTAssertEqual(ZoneCompareModel.phase(for: httpError(422, "OUT_OF_MARKET")), .outOfMarket)
        XCTAssertEqual(ZoneCompareModel.phase(for: httpError(400, "INVALID_PARAMS")), .failed)
        XCTAssertEqual(ZoneCompareModel.phase(for: httpError(400, "INVALID_MARKET")), .failed)
        XCTAssertEqual(ZoneCompareModel.phase(for: httpError(503, nil)), .failed)
        XCTAssertEqual(ZoneCompareModel.phase(for: APIError.transport("offline")), .failed)
        XCTAssertEqual(ZoneCompareModel.phase(for: APIError.decoding("zone")), .failed)
        XCTAssertNil(ZoneCompareModel.phase(for: APIError.cancelled), "Une annulation n'est jamais un échec")
        XCTAssertNil(ZoneCompareModel.phase(for: CancellationError()))
    }

    func testTheErrorBodyOfTheRealClientReachesTheMapping() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: configuration))
        func fail(status: Int, body: String) async -> Error? {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                 headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
            }
            do {
                _ = try await ANFRService(api: api).zoneCompare(latitude: 1, longitude: 2, radius: .km50, market: "FR", includeBands: false)
                return nil
            } catch { return error }
        }
        let missing = await fail(status: 404, body: "<html>404</html>")
        XCTAssertEqual(missing.flatMap { ZoneCompareModel.phase(for: $0) }, .failed)
        let noData = await fail(status: 422, body: #"{"code":"MARKET_NO_ANTENNA_DATA","message":"x","requestId":"r"}"#)
        XCTAssertEqual(noData.flatMap { ZoneCompareModel.phase(for: $0) }, .noAntennaData)
        let outside = await fail(status: 422, body: #"{"code":"OUT_OF_MARKET","message":"x","requestId":"r"}"#)
        XCTAssertEqual(outside.flatMap { ZoneCompareModel.phase(for: $0) }, .outOfMarket)
    }

    func testTheDefaultImplementationOfAFakeReadsAsAFailure() async {
        final class Bare: ANFRServicing, @unchecked Sendable {
            func current() async throws -> ANFRDataset { throw URLError(.unsupportedURL) }
            func archives() async throws -> [ANFRDataset] { throw URLError(.unsupportedURL) }
            func search(query: String) async throws -> [AntennaSite] { throw URLError(.unsupportedURL) }
            func siteHistory(supId: String) async throws -> ANFRSiteHistory { throw URLError(.unsupportedURL) }
            func stats() async throws -> ANFRStats { throw URLError(.unsupportedURL) }
            func bandStats(weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats {
                throw URLError(.unsupportedURL)
            }
            func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot { throw URLError(.unsupportedURL) }
            func archiveDates() async throws -> ANFRArchiveDates { throw URLError(.unsupportedURL) }
        }
        do {
            _ = try await Bare().zoneCompare(latitude: 0, longitude: 0, radius: .km50, market: "FR", includeBands: false)
            XCTFail("L'implémentation par défaut ne sert rien")
        } catch {
            XCTAssertEqual(ZoneCompareModel.phase(for: error), .failed)
        }
    }

    // MARK: États et chargements

    func testFranceLoadsOnceAndAZoneAlreadySeenComesFromMemory() async throws {
        let service = ZoneService()
        let model = makeModel(service)
        await model.load()
        guard case .loaded(let zone) = model.phase else { return XCTFail("attendu : chargé, reçu \(model.phase)") }
        XCTAssertEqual(zone.totalActive, 10)
        XCTAssertEqual(service.calls, [.init(latitude: 45.7640, longitude: 4.8357, radius: 50, market: "FR", bands: false)])
        XCTAssertEqual(model.marketEntry?.code, "FR")

        await model.load()
        XCTAssertEqual(service.calls.count, 1, "Même case, même rayon : rien à redemander")

        model.radius = .km100
        await model.load()
        XCTAssertEqual(service.calls.map(\.radius), [50, 100])
        model.radius = .km50
        await model.load()
        XCTAssertEqual(service.calls.count, 2, "Le rayon déjà vu se relit en mémoire")

        model.reload()
        await model.load()
        XCTAssertEqual(service.calls.count, 3, "Réessayer vide la mémoire")
    }

    func testTwoPointsOfTheSameGridCellShareTheCacheKeyAndTwoCellsDoNot() {
        let a = ZoneCompareModel.cacheKey(market: "FR", radius: .km50, latitude: 45.761, longitude: 4.801, bands: false)
        let b = ZoneCompareModel.cacheKey(market: "FR", radius: .km50, latitude: 45.789, longitude: 4.823, bands: false)
        let c = ZoneCompareModel.cacheKey(market: "FR", radius: .km50, latitude: 45.81, longitude: 4.801, bands: false)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, ZoneCompareModel.cacheKey(market: "FR", radius: .km20, latitude: 45.761, longitude: 4.801, bands: false))
        XCTAssertNotEqual(a, ZoneCompareModel.cacheKey(market: "DROM", radius: .km50, latitude: 45.761, longitude: 4.801, bands: false))
        XCTAssertNotEqual(a, ZoneCompareModel.cacheKey(market: "FR", radius: .km50, latitude: 45.761, longitude: 4.801, bands: true))
    }

    func testTheBandDetailReloadsOnDemandWithoutEmptyingTheList() async throws {
        let service = ZoneService()
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(service.calls.map(\.bands), [false])
        model.wantsBands = true
        await model.load()
        XCTAssertEqual(service.calls.map(\.bands), [false, true])
        guard case .loaded(let zone) = model.phase else { return XCTFail("la liste reste affichée") }
        XCTAssertTrue(zone.hasBands)
        XCTAssertFalse(model.bandsLoading)
        XCTAssertFalse(model.bandsFailed)

        model.wantsBands = false
        await model.load()
        XCTAssertEqual(service.calls.count, 2, "Le détail déjà chargé répond aussi à la liste simple")
    }

    func testABandDetailFailureKeepsTheListAndSaysSo() async {
        let service = ZoneService()
        let model = makeModel(service)
        await model.load()
        service.failure = APIError.transport("offline")
        model.wantsBands = true
        await model.load()
        XCTAssertTrue(model.bandsFailed)
        if case .loaded = model.phase {} else { XCTFail("la liste reste affichée") }
    }

    func testEachServerErrorLandsOnItsState() async {
        let cases: [(Error, ZoneCompareModel.Phase)] = [
            (httpError(404, nil), .failed),
            (httpError(422, "MARKET_NO_ANTENNA_DATA"), .noAntennaData),
            (httpError(422, "OUT_OF_MARKET"), .outOfMarket),
            (APIError.transport("offline"), .failed),
        ]
        for (error, expected) in cases {
            let service = ZoneService()
            service.failure = error
            let model = makeModel(service)
            await model.load()
            XCTAssertEqual(model.phase, expected)
        }
    }

    func testOnlyFranceAndOverseasAreQueriedTheOtherMarketsStopLocally() async {
        let service = ZoneService()
        let canada = makeModel(service, market: "CA")
        await canada.load()
        XCTAssertEqual(canada.phase, .noAntennaData)
        let sea = makeModel(service, market: nil)
        await sea.load()
        XCTAssertEqual(sea.phase, .outOfMarket)
        XCTAssertTrue(service.calls.isEmpty, "Ni le Canada ni le large ne partent au serveur")

        let overseas = makeModel(service, market: "DROM", latitude: 16.24, longitude: -61.53)
        await overseas.load()
        XCTAssertEqual(service.calls.map(\.market), ["DROM"])
        XCTAssertEqual(ANFRZoneMarket.apiCode(forMarket: " fr "), "FR")
        XCTAssertNil(ANFRZoneMarket.apiCode(forMarket: "BE"))
        XCTAssertNil(ANFRZoneMarket.apiCode(forMarket: nil))
    }

    /// Le registre réel (embarqué) et ses aires : Lyon et Pointe-à-Pitre sont interrogeables, Montréal et l'Atlantique non.
    func testTheBundledRegistryResolvesTheMarketFromTheGPS() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: configuration))
        let markets = MarketRegistryService(api: api, cache: DiskCache(folderName: "ZoneCompareTests-\(UUID())"))
        func code(_ latitude: Double, _ longitude: Double) async -> String? {
            await markets.marketForLocation(latitude: latitude, longitude: longitude)?.code
        }
        let lyon = await code(45.764, 4.8357)
        let guadeloupe = await code(16.24, -61.53)
        let reunion = await code(-21.115, 55.536)
        let montreal = await code(45.5019, -73.5674)
        let atlantic = await code(30.0, -40.0)
        XCTAssertEqual(lyon, "FR")
        XCTAssertEqual(guadeloupe, "DROM")
        XCTAssertEqual(reunion, "DROM")
        XCTAssertEqual(montreal, "CA")
        XCTAssertNil(atlantic)
    }
}
