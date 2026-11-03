import XCTest
@testable import SignalQuest

/// Carte des modifications du Canada (contrat ISED-STATS v1, §10), sur un extrait
/// réel de la réponse servie le 03/11 (registre public ISED).
@MainActor
final class ISEDChangesMapTests: XCTestCase {
    static let fixture = ##"{"meta": {"market": "CA"}, "cadence": "monthly", "types": ["new", "added", "deleted", "modified"], "operators": [{"key": "BELL", "label": "Bell", "color": "#0F5BDC"}, {"key": "ROGERS", "label": "Rogers", "color": "#D62D20"}, {"key": "TELUS", "label": "TELUS", "color": "#00A67E"}, {"key": "VIDEOTRON_FREEDOM", "label": "Videotron/Freedom", "color": "#7A3DF0"}, {"key": "REGIONAL", "label": "Regionaux", "color": "#D97706"}], "from": "2026-09-01", "to": "2026-10-06", "weeks": ["2026-10-06"], "siteCount": 5, "antennaCount": 8, "sites": [{"supId": "00a1959b3381a805444aab53c5217f29d3fa1bf0", "siteKeys": ["00a1959b3381a805444aab53c5217f29d3fa1bf0"], "lat": 45.5863, "lon": -70.86746, "city": "4660 RUE VILLENEUVE", "province": "QC", "operators": ["TELUS"], "changes": {"new": 1, "added": 0, "deleted": 0, "modified": 0}, "lastChangeDate": "2026-10-06", "items": [{"type": "new", "technology": "4G", "band": "1900", "operator": "TELUS", "siteKey": "00a1959b3381a805444aab53c5217f29d3fa1bf0"}]}, {"supId": "0000b3e053f3d46eacca0ff3703348fc49dedc7c", "siteKeys": ["0000b3e053f3d46eacca0ff3703348fc49dedc7c", "0aa47ba84e2394e7ba421f34413512882af47b91"], "lat": 49.35061, "lon": -98.66007, "city": "NE 31-4-9 W, St. Leon, MB Canada", "province": "MB", "operators": ["REGIONAL"], "holderName": "Xplore Inc.", "changes": {"new": 0, "added": 0, "deleted": 0, "modified": 2}, "lastChangeDate": "2026-10-06", "items": [{"type": "modified", "technology": "4G", "band": "3500", "operator": "REGIONAL", "what": "carriers", "siteKey": "4882867e0338525d1c9f685cc972ff5fc3b7e58e"}, {"type": "modified", "technology": "5G", "band": "3500", "operator": "REGIONAL", "what": "carriers", "siteKey": "0aa47ba84e2394e7ba421f34413512882af47b91"}]}, {"supId": "000ab5538579568f95a864afb393f96c180aca05", "siteKeys": ["000ab5538579568f95a864afb393f96c180aca05", "01ca11a46d6af004a66080133bfc8a6733206797"], "lat": 47.55972, "lon": -52.74639, "city": "LA019LA-20 Crosbie Place", "province": "NL", "operators": ["REGIONAL"], "holderName": "Bragg Communications Inc.", "changes": {"new": 0, "added": 0, "deleted": 1, "modified": 0}, "lastChangeDate": "2026-10-06", "items": [{"type": "deleted", "technology": "5G", "band": "3500", "operator": "REGIONAL", "siteKey": null}]}, {"supId": "0032c9cbb48f78427f23fd454a4edb4abc9dd27c", "siteKeys": ["0032c9cbb48f78427f23fd454a4edb4abc9dd27c", "02aca0bb0b38a68fc44b72073b066bb57bdbe075"], "lat": 50.45019, "lon": -104.63423, "city": "1734 ELPHINSTONE ST REGINA S REGINA", "province": "SK", "operators": ["REGIONAL"], "holderName": "Saskatchewan Telecommunications", "changes": {"new": 0, "added": 0, "deleted": 0, "modified": 3}, "lastChangeDate": "2026-10-06", "items": [{"type": "modified", "technology": "4G", "band": "AWS", "operator": "REGIONAL", "what": "carriers", "siteKey": "0de1363d2f807d25624ed733f40bd76d18ec12d6"}, {"type": "modified", "technology": "5G", "band": "3500", "operator": "REGIONAL", "what": "azimuths", "siteKey": "1cd3058d0dda4d0c5744a31a446e06fe2643d2a5"}, {"type": "modified", "technology": "5G", "band": "AWS", "operator": "REGIONAL", "what": "azimuths", "siteKey": "046d0ac36d6256b302690378d3237755db794b2f"}]}, {"supId": "0007e808c78ec1b80b0ad57f06065f49f4d91c44", "siteKeys": ["0007e808c78ec1b80b0ad57f06065f49f4d91c44", "05007a247994b67b6f32878d9a85d0312c256f62"], "lat": 52.14689, "lon": -106.57731, "city": "850 ATTRIDGE DR SASKATOON", "province": "SK", "operators": ["REGIONAL"], "holderName": "Saskatchewan Telecommunications", "changes": {"new": 0, "added": 0, "deleted": 0, "modified": 1}, "lastChangeDate": "2026-10-06", "items": [{"type": "modified", "technology": "5G", "band": "3500", "operator": "REGIONAL", "what": "carriers", "siteKey": "05007a247994b67b6f32878d9a85d0312c256f62"}]}]}"##

    private func diff() throws -> ANFRMapDiff {
        try JSONDecoder.signalQuest.decode(ANFRMapDiff.self, from: Data(Self.fixture.utf8))
    }

    func testCanadianDiffDecodesMarketOperatorsAndItems() throws {
        let diff = try diff()
        XCTAssertEqual(diff.market, "CA")
        XCTAssertTrue(ANFRMapMarket.ca.accepts(served: diff.market))
        XCTAssertFalse(ANFRMapMarket.ca.accepts(served: nil), "a reply that does not name its market is refused")
        XCTAssertEqual(diff.operators.map(\.key), ["BELL", "ROGERS", "TELUS", "VIDEOTRON_FREEDOM", "REGIONAL"])
        XCTAssertEqual(diff.operators.last?.label, String(localized: "Autres"))
        XCTAssertEqual(diff.sites.count, 5)

        let new = try XCTUnwrap(diff.sites.first)
        XCTAssertEqual(new.market, .ca)
        XCTAssertEqual(new.mapOperators.map(\.key), ["TELUS"])
        XCTAssertEqual(new.summary?.presentTypes, [.new])
        XCTAssertEqual(new.summary?.catchUp, 0)
        XCTAssertEqual(new.displayName, "4660 RUE VILLENEUVE", "ISED site names are shown as published")
        XCTAssertEqual(new.summary?.ised?.province, "QC")
        XCTAssertEqual(new.summary?.ised?.items.first?.title, "4G 1900 MHz")

        let regional = diff.sites[1]
        XCTAssertEqual(regional.summary?.ised?.holderName, "Xplore Inc.")
        XCTAssertEqual(regional.summary?.ised?.items.first?.whatLabel, String(localized: "Fréquences modifiées"))
        XCTAssertNotNil(regional.summary?.ised?.items.first?.siteKey)

        let removed = try XCTUnwrap(diff.sites[2].summary?.ised?.items.first)
        XCTAssertEqual(removed.type, .deleted)
        XCTAssertNil(removed.siteKey, "a removed transmitter has no licence line to open")

        let azimuths = diff.sites[3].summary?.ised?.items.compactMap(\.whatLabel)
        XCTAssertTrue(azimuths?.contains(String(localized: "Azimuts modifiés")) == true)
        XCTAssertEqual(diff.sites[3].summary?.ised?.items.first?.title, "4G AWS")
    }

    func testCanadaNeverSaysActivatedAndRenamesModified() {
        XCTAssertFalse(ANFRMapMarket.ca.modTypes.contains(.activated))
        XCTAssertEqual(ANFRMapMarket.fr.modTypes, ANFRModType.allCases)
        XCTAssertEqual(ANFRModType.modified.label(in: .ca), String(localized: "Émetteur modifié"))
        XCTAssertEqual(ANFRModType.modified.label(in: .fr), ANFRModType.modified.label)
        XCTAssertNotEqual(ANFRModType.modified.glyph(in: .ca), ANFRModType.modified.glyph)
    }

    func testAMissingISEDNameFallsBackToTheProvince() {
        let site = ANFRMapSite(supId: "k", latitude: 45, longitude: -73, city: "#N/A", antennas: [], summary: ANFRSiteChangeSummary(
            operators: [], hasOtherOperator: false, counts: [.added: 1], catchUp: 0, lastChangeDate: nil,
            rawOperators: ["BELL"], ised: ISEDSiteChanges(siteKeys: ["k"], province: "QC", holderName: nil, items: [])
        ))
        XCTAssertEqual(site.displayName, String(localized: "Site ISED, QC"))
    }

    /// Le décodage tient sur la réponse complète servie (3 337 sites), quand le fichier est là.
    func testTheFullServedMonthDecodes() throws {
        let url = URL(fileURLWithPath: "/private/tmp/ised-ca-samples/3-map-diff-ca-full.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("réponse complète absente") }
        let diff = try JSONDecoder.signalQuest.decode(ANFRMapDiff.self, from: data)
        XCTAssertEqual(diff.sites.count, 3_337)
        XCTAssertTrue(diff.sites.allSatisfy { $0.market == .ca && !$0.mapOperators.isEmpty })
        XCTAssertEqual(diff.sites.reduce(0) { $0 + ($1.summary?.ised?.items.count ?? 0) }, 6_985)
    }

    // MARK: Modèle de la carte

    private final class CanadaService: ANFRServicing, @unchecked Sendable {
        var diffCalls: [String] = []
        let diff: ANFRMapDiff
        init(diff: ANFRMapDiff) { self.diff = diff }

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
        func archiveDates(market: ANFRMapMarket) async throws -> ANFRArchiveDates {
            ANFRArchiveDates(dates: ["2026-10-06", "2026-09-01"], current: "2026-10-06")
        }
        func mapDiff(from: String, to: String?, market: ANFRMapMarket) async throws -> ANFRMapDiff {
            diffCalls.append("\(market.rawValue)|\(from)|\(to ?? "current")")
            return diff
        }
    }

    func testACanadianMonthIsTheDiffFromThePreviousExtract() async throws {
        let service = CanadaService(diff: try diff())
        let model = ANFRMapViewModel(service: service, market: .ca)
        await model.load()
        XCTAssertEqual(service.diffCalls, ["CA|2026-09-01|current"])
        XCTAssertTrue(model.selectableDates.isEmpty, "the base extract has nothing before it, and the latest has its own row")
        XCTAssertTrue(model.supportsLite)
        XCTAssertEqual(model.mapOperators.map(\.key).last, "REGIONAL")
        XCTAssertEqual(model.filteredSites.count, 5)
        XCTAssertEqual(model.operatorCounts["REGIONAL"], 4)
        XCTAssertEqual(model.operatorCounts["TELUS"], 1)

        model.operatorFilters = ["TELUS"]
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.filteredSites.map(\.supId), [try diff().sites[0].supId])
        XCTAssertEqual(model.activeFilterCount, 1)
        model.resetFilters()
        XCTAssertEqual(model.activeFilterCount, 0)
    }
}
