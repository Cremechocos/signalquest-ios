import XCTest
import SwiftUI
@testable import SignalQuest

/// Statistiques ANFR d'outre-mer (contrats ANFR DROM v1 et bandes DROM v2) :
/// `market=DROM` seulement en outre-mer, opérateurs et départements servis par
/// le serveur, et jamais de chiffres d'un marché sous le nom de l'autre.
@MainActor
final class ANFRDromStatsTests: XCTestCase {
    private final class MarketService: ANFRServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var responses: [ANFRStatsMarket: ANFRStats] = [:]
        var bands: (ANFRStatsMarket) -> ANFRBandStats? = { _ in nil }
        var calls: [String] { lock.withLock { recorded } }

        func stats(market: ANFRStatsMarket) async throws -> ANFRStats {
            lock.withLock { recorded.append("stats:\(market.rawValue)") }
            guard let stats = responses[market] else { throw URLError(.fileDoesNotExist) }
            return stats
        }

        func bandStats(market: ANFRStatsMarket, weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats {
            lock.withLock { recorded.append("bands:\(market.rawValue):\(operatorKey ?? "-")") }
            guard let stats = bands(market) else { throw URLError(.fileDoesNotExist) }
            return stats
        }

        func stats() async throws -> ANFRStats { throw URLError(.unsupportedURL) }
        func bandStats(weeks: Int?, generation: String?, operatorKey: String?) async throws -> ANFRBandStats {
            throw URLError(.unsupportedURL)
        }
        func current() async throws -> ANFRDataset { throw URLError(.unsupportedURL) }
        func archives() async throws -> [ANFRDataset] { throw URLError(.unsupportedURL) }
        func search(query: String) async throws -> [AntennaSite] { throw URLError(.unsupportedURL) }
        func siteHistory(supId: String) async throws -> ANFRSiteHistory { throw URLError(.unsupportedURL) }
        func mapSnapshot(date: String?) async throws -> ANFRMapSnapshot { throw URLError(.unsupportedURL) }
        func archiveDates() async throws -> ANFRArchiveDates { throw URLError(.unsupportedURL) }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: Décodage

    private func row(_ op: String, _ band: String, _ operational: Int, delta: Int = 0) -> [String: Any] {
        ["date": "2026-10-22", "operator": op, "operatorLabel": op, "band": band, "bandLabel": band,
         "technology": band.hasPrefix("n") ? "5G" : "4G", "operational": operational, "projected": 2,
         "total": operational + 2, "deltaOperational": delta, "deltaProjected": 0, "deltaTotal": delta]
    }

    private func department(_ key: String, _ label: String, _ op: String, _ operational: Int) -> [String: Any] {
        ["key": key, "label": label, "kind": "department", "operator": op, "operatorLabel": op, "band": "4g",
         "bandLabel": "4G globale", "technology": "4G", "operational": operational, "projected": 0,
         "total": operational, "shareOfNational": 0.2]
    }

    private func statsJSON(market: String?, operators: [[String: Any]], latest: [[String: Any]],
                           departments: [[String: Any]] = []) throws -> ANFRStats {
        var meta: [String: Any] = ["latestDate": "2026-10-22", "partial": false]
        meta["market"] = market
        let object: [String: Any] = [
            "meta": meta,
            "national": ["series": latest, "latest": latest],
            "territories": ["regions": [], "departments": departments, "crozon": []],
            "rankings": ["regions": ["top": [], "flop": []]],
            "filters": ["operators": operators, "bands": [], "statuses": [],
                        "territories": ["regions": [], "departments": ["971", "972", "973", "974", "976"]]],
        ]
        return try JSONDecoder().decode(ANFRStats.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private var dromOperators: [[String: Any]] {
        [["key": "ORANGE", "label": "Orange", "color": "#FF7900"],
         ["key": "DIGICEL", "label": "Digicel", "color": "#B91C1C"],
         ["key": "DROM_OTHER", "label": "Autres", "color": "#6B7280"]]
    }

    func testOverseasStatsCarryOperatorsDepartmentsAndMarket() throws {
        let stats = try statsJSON(
            market: "DROM", operators: dromOperators,
            latest: [row("ORANGE", "4g", 300), row("DIGICEL", "4g", 420)],
            departments: [department("971", "Guadeloupe", "ORANGE", 223), department("974", "La Réunion", "DIGICEL", 0)]
        )
        XCTAssertEqual(stats.market, "DROM")
        XCTAssertEqual(stats.operators.map(\.key), ["ORANGE", "DIGICEL", "DROM_OTHER"])
        XCTAssertEqual(stats.operators.first?.label, "Orange")
        // « Autres » dans la langue de l'app, pas le libellé du serveur.
        XCTAssertEqual(stats.operators.last?.label, String(localized: "Autres"))
        XCTAssertEqual(stats.departments.map(\.key), ["971", "974"])
        XCTAssertEqual(stats.departments.first?.label, "Guadeloupe")
    }

    /// En métropole, les départements ne sont pas lus (une centaine, sans usage à l'écran).
    func testFranceStatsSkipDepartments() throws {
        let stats = try statsJSON(market: "FR", operators: [], latest: [row("orange", "4g", 30_000)],
                                  departments: [department("38", "Isère", "orange", 900)])
        XCTAssertEqual(stats.market, "FR")
        XCTAssertTrue(stats.departments.isEmpty)
    }

    func testMarketGuard() {
        XCTAssertTrue(ANFRStatsMarket.fr.accepts(served: nil), "vue par bande de la métropole, sans meta.market")
        XCTAssertTrue(ANFRStatsMarket.fr.accepts(served: "FR"))
        XCTAssertFalse(ANFRStatsMarket.fr.accepts(served: "DROM"))
        XCTAssertTrue(ANFRStatsMarket.drom.accepts(served: "DROM"))
        XCTAssertFalse(ANFRStatsMarket.drom.accepts(served: nil))
        XCTAssertFalse(ANFRStatsMarket.drom.accepts(served: "FR"))
        XCTAssertFalse(ANFRStatsMarket.drom.accepts(served: "drom"))
    }

    // MARK: Requêtes

    /// `market=DROM` en outre-mer seulement : la requête de la métropole reste
    /// celle d'avant, à l'octet près (réponse et cache inchangés).
    func testServiceSendsTheMarketOnlyOverseas() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-anfr-reader")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let seen = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            let isBands = request.url?.query?.contains("view=bands") == true
            let object: [String: Any] = isBands
                ? ["meta": ["firstDate": "2021-12-29", "latestDate": "2026-10-22", "partial": false, "market": "DROM"],
                   "bands": [], "series": [], "summary": []]
                : ["meta": ["latestDate": "2026-10-22", "market": "DROM"], "national": ["series": [], "latest": []]]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!,
                    try! JSONSerialization.data(withJSONObject: object))
        }
        let service = ANFRService(api: api)
        _ = try await service.stats(market: .fr)
        _ = try await service.stats(market: .drom)
        _ = try await service.bandStats(market: .drom, weeks: 1, generation: nil, operatorKey: "all")
        let queries = seen.all.map { request -> [String: String] in
            Dictionary(uniqueKeysWithValues: (URLComponents(url: request.0.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries[0], [:])
        XCTAssertEqual(queries[1], ["market": "DROM"])
        XCTAssertEqual(queries[2], ["view": "bands", "market": "DROM", "operator": "all", "weeks": "1"])
    }

    // MARK: Écran des statistiques

    func testSwitchingToOverseasUsesTheServedOperators() async throws {
        let service = MarketService()
        service.responses[.fr] = try statsJSON(market: "FR", operators: [], latest: [row("orange", "4g", 30_000), row("sfr", "4g", 25_000)])
        service.responses[.drom] = try statsJSON(
            market: "DROM", operators: dromOperators,
            latest: [row("ORANGE", "4g", 300, delta: 2), row("DIGICEL", "4g", 420), row("DROM_OTHER", "4g", 0)],
            departments: [department("971", "Guadeloupe", "ORANGE", 223), department("972", "Martinique", "ORANGE", 77)]
        )
        let model = ANFRStatsViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.operators.map(\.key), ["orange", "sfr", "bytel", "free"])
        XCTAssertEqual(model.totalOperational, 55_000)

        await model.select(market: .drom)
        XCTAssertEqual(model.market, .drom)
        XCTAssertEqual(model.operators.map(\.key), ["ORANGE", "DIGICEL", "DROM_OTHER"])
        XCTAssertEqual(model.selectedOperator.key, "ORANGE", "Orange existe des deux côtés : le choix est gardé")
        XCTAssertEqual(model.totalOperational, 720)
        XCTAssertEqual(model.operatorBreakdown.map(\.operator.key), ["DIGICEL", "ORANGE"], "Pas de ligne « 0 stable »")
        XCTAssertEqual(model.operatorBreakdown.last?.delta, 2)
        XCTAssertEqual(model.territories.map(\.key), ["971", "972"])

        // Retour à la métropole : rien n'est redemandé.
        await model.select(market: .fr)
        XCTAssertEqual(model.totalOperational, 55_000)
        XCTAssertEqual(service.calls, ["stats:FR", "stats:DROM"])
    }

    func testAnOperatorMissingOverseasGivesWayToTheFirstServed() async throws {
        let service = MarketService()
        service.responses[.fr] = try statsJSON(market: "FR", operators: [], latest: [row("sfr", "4g", 25_000)])
        service.responses[.drom] = try statsJSON(
            market: "DROM",
            operators: [["key": "DIGICEL", "label": "Digicel", "color": "#B91C1C"]],
            latest: [row("DIGICEL", "4g", 420)]
        )
        let model = ANFRStatsViewModel(service: service)
        await model.load()
        model.selectedOperator = ANFRStatsOperator(.sfr)
        await model.select(market: .drom)
        XCTAssertEqual(model.selectedOperator.key, "DIGICEL")
    }

    /// Une réponse qui ne se dit pas d'outre-mer n'est jamais affichée comme telle.
    func testOverseasRequestAnsweredWithFranceIsRefused() async throws {
        let service = MarketService()
        service.responses[.drom] = try statsJSON(market: "FR", operators: [], latest: [row("orange", "4g", 30_000)])
        let model = ANFRStatsViewModel(service: service)
        await model.select(market: .drom)
        XCTAssertNil(model.stats)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: Générations et bandes

    private func bandsJSON(market: String?) throws -> ANFRBandStats {
        var meta: [String: Any] = ["firstDate": "2021-12-29", "latestDate": "2026-10-22", "partial": false]
        meta["market"] = market
        let generation: [String: Any] = ["key": "4g", "generation": "4G", "kind": "generation", "mhz": NSNull(), "nrBand": NSNull(),
                                         "label": ["fr": "4G (tous supports)", "en": "4G (all sites)", "short": "4G"],
                                         "firstDate": "2021-12-29"]
        let summary: [String: Any] = ["operator": "all", "band": "4g", "latest": ["date": "2026-10-22", "operational": 1_100, "projected": 40],
                                      "peak": ["date": "2026-10-22", "operational": 1_100], "shareOfPeakPermille": 1_000]
        let object: [String: Any] = ["meta": meta, "bands": [generation], "series": [], "summary": [summary]]
        return try JSONDecoder().decode(ANFRBandStats.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testOverseasBandsUseTheMarketAndItsOperators() async throws {
        let service = MarketService()
        let labelled = try bandsJSON(market: "DROM")
        service.bands = { $0 == .drom ? labelled : nil }
        let operators = [ANFRStatsOperator(key: "ORANGE", label: "Orange", color: .orange),
                         ANFRStatsOperator(key: "ZEOP", label: "Zeop", color: .yellow)]
        let model = ANFRBandsViewModel(service: service, market: .drom, operators: operators)
        XCTAssertEqual(model.operators.map(\.key), ["all", "ORANGE", "ZEOP"])
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.generationRows.first?.summary.latest.operational, 1_100)
        XCTAssertTrue(service.calls.allSatisfy { $0.hasPrefix("bands:DROM:") })
    }

    func testOverseasBandsWithoutTheMarketAreRefused() async throws {
        let service = MarketService()
        let unlabelled = try bandsJSON(market: nil)
        service.bands = { _ in unlabelled }
        let model = ANFRBandsViewModel(service: service, market: .drom, operators: [])
        await model.load()
        XCTAssertNil(model.overview)
        XCTAssertNotNil(model.errorMessage)
    }
}
