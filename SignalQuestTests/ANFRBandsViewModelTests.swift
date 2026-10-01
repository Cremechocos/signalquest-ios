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
