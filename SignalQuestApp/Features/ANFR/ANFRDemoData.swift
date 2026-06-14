import Foundation

/// Données de démonstration ANFR pour le mode `--mock-auth`
/// (`AppEnvironment.usesDemoData`) : permet aux vues de s'afficher sans réseau.
/// Les chiffres sont représentatifs des ordres de grandeur réels (juin 2026).
enum ANFRDemoData {

    // MARK: Stats

    static let stats: ANFRStats = {
        ANFRStats(
            latestDate: "2026-06-11",
            series: demoSeries,
            latest: demoLatest,
            regions: demoRegions
        )
    }()

    /// Dernier relevé par opérateur × bande phare.
    private static let demoLatest: [ANFRStatsLatest] = {
        // (opérateur, label, [(band, bandLabel, techno, op, proj, dOp, dTotal)])
        let table: [(String, String, [(String, String, String, Int, Int, Int, Int)])] = [
            ("orange", "Orange", [
                ("4g", "4G globale", "4G", 30410, 1980, 41, 55),
                ("n78", "5G n78 3.5 GHz", "5G", 18250, 3120, 62, 80),
                ("n1", "5G n1 2100 MHz", "5G", 9320, 2510, 12, 18),
                ("n28", "5G n28 700 MHz", "5G", 3469, 980, 7, 9)
            ]),
            ("sfr", "SFR", [
                ("4g", "4G globale", "4G", 29870, 1450, 33, 40),
                ("n78", "5G n78 3.5 GHz", "5G", 14110, 2280, 48, 60),
                ("n1", "5G n1 2100 MHz", "5G", 6510, 1990, 9, 14),
                ("n28", "5G n28 700 MHz", "5G", 2364, 610, 4, 6)
            ]),
            ("bytel", "Bouygues Telecom", [
                ("4g", "4G globale", "4G", 31742, 1797, 39, 17),
                ("n78", "5G n78 3.5 GHz", "5G", 16980, 2640, 51, 64),
                ("n1", "5G n1 2100 MHz", "5G", 8920, 2310, 11, 16),
                ("n28", "5G n28 700 MHz", "5G", 3641, 720, 5, 7)
            ]),
            ("free", "Free Mobile", [
                ("4g", "4G globale", "4G", 28630, 2210, 58, 72),
                ("n78", "5G n78 3.5 GHz", "5G", 12880, 1980, 44, 58),
                ("n28", "5G n28 700 MHz", "5G", 19340, 4120, 70, 95),
                ("n1", "5G n1 2100 MHz", "5G", 7220, 1840, 8, 12)
            ])
        ]
        return table.flatMap { op, label, bands in
            bands.map { band, bandLabel, techno, opCount, proj, dOp, dTotal in
                ANFRStatsLatest(
                    date: "2026-06-11",
                    operatorKey: op,
                    operatorLabel: label,
                    band: band,
                    bandLabel: bandLabel,
                    technology: techno,
                    operational: opCount,
                    projected: proj,
                    total: opCount + proj,
                    deltaOperational: dOp,
                    deltaTotal: dTotal
                )
            }
        }
    }()

    /// Série temporelle (2 ans, pas mensuel) pour 4G globale + 5G par opérateur.
    private static let demoSeries: [ANFRStatsPoint] = {
        var points: [ANFRStatsPoint] = []
        let operators: [(String, String)] = [
            ("orange", "Orange"), ("sfr", "SFR"),
            ("bytel", "Bouygues Telecom"), ("free", "Free Mobile")
        ]
        // valeurs finales (op) pour interpoler une montée crédible
        let final4g: [String: Int] = ["orange": 30410, "sfr": 29870, "bytel": 31742, "free": 28630]
        let final5g_n78: [String: Int] = ["orange": 18250, "sfr": 14110, "bytel": 16980, "free": 12880]
        let final5g_n1: [String: Int] = ["orange": 9320, "sfr": 6510, "bytel": 8920, "free": 7220]
        let final5g_n28: [String: Int] = ["orange": 3469, "sfr": 2364, "bytel": 3641, "free": 19340]
        let months = 24
        for monthIndex in 0...months {
            let year = 2024 + (monthIndex / 12)
            let month = (monthIndex % 12) + 1
            let date = String(format: "%04d-%02d-01", year, month)
            let t = Double(monthIndex) / Double(months)
            for (key, label) in operators {
                let v4 = Int(Double(final4g[key] ?? 28000) * (0.78 + 0.22 * t))
                let v5_78 = Int(Double(final5g_n78[key] ?? 12000) * (0.40 + 0.60 * t))
                let v5_1 = Int(Double(final5g_n1[key] ?? 6000) * (0.35 + 0.65 * t))
                let v5_28 = Int(Double(final5g_n28[key] ?? 3000) * (0.30 + 0.70 * t))
                points.append(ANFRStatsPoint(date: date, operatorKey: key, operatorLabel: label, band: "4g", bandLabel: "4G globale", technology: "4G", operational: v4, projected: 1800, total: v4 + 1800))
                points.append(ANFRStatsPoint(date: date, operatorKey: key, operatorLabel: label, band: "n78", bandLabel: "5G n78 3.5 GHz", technology: "5G", operational: v5_78, projected: 2400, total: v5_78 + 2400))
                points.append(ANFRStatsPoint(date: date, operatorKey: key, operatorLabel: label, band: "n1", bandLabel: "5G n1 2100 MHz", technology: "5G", operational: v5_1, projected: 800, total: v5_1 + 800))
                points.append(ANFRStatsPoint(date: date, operatorKey: key, operatorLabel: label, band: "n28", bandLabel: "5G n28 700 MHz", technology: "5G", operational: v5_28, projected: 1200, total: v5_28 + 1200))
            }
        }
        return points
    }()

    private static let demoRegions: [ANFRTerritoryMetric] = {
        let regionData: [(String, [String: Int])] = [
            ("Île-de-France", ["orange": 5210, "sfr": 5080, "bytel": 5360, "free": 4920]),
            ("Auvergne-Rhône-Alpes", ["orange": 4335, "sfr": 4110, "bytel": 4480, "free": 3990]),
            ("Nouvelle-Aquitaine", ["orange": 3620, "sfr": 3410, "bytel": 3700, "free": 3290]),
            ("Occitanie", ["orange": 3540, "sfr": 3320, "bytel": 3610, "free": 3180]),
            ("Grand Est", ["orange": 3120, "sfr": 2980, "bytel": 3210, "free": 2870]),
            ("Hauts-de-France", ["orange": 2980, "sfr": 2840, "bytel": 3050, "free": 2710])
        ]
        return regionData.flatMap { label, byOp in
            byOp.flatMap { op, value in
                [
                    ANFRTerritoryMetric(key: label, label: label, operatorKey: op, band: "4g", technology: "4G", operational: value, total: value + 200),
                    ANFRTerritoryMetric(key: label, label: label, operatorKey: op, band: "n78", technology: "5G", operational: Int(Double(value) * 0.55), total: Int(Double(value) * 0.55) + 100),
                    ANFRTerritoryMetric(key: label, label: label, operatorKey: op, band: "n1", technology: "5G", operational: Int(Double(value) * 0.30), total: Int(Double(value) * 0.30) + 50),
                    ANFRTerritoryMetric(key: label, label: label, operatorKey: op, band: "n28", technology: "5G", operational: Int(Double(value) * 0.25), total: Int(Double(value) * 0.25) + 40)
                ]
            }
        }
    }()

    // MARK: Map snapshot

    static let mapSnapshot: ANFRMapSnapshot = {
        ANFRMapSnapshot(
            source: "demo",
            snapshotDate: nil,
            lastUpdate: "11 juin 2026",
            sites: demoSites
        )
    }()

    static let archiveDates = ANFRArchiveDates(
        dates: ["2026-06-04", "2026-05-28", "2026-05-21", "2026-05-14", "2026-05-07"],
        current: "2026-06-11"
    )

    static let siteHistory = ANFRSiteHistory(
        supId: "29847",
        currentSnapshotDate: "2026-06-11",
        entries: [
            ANFRSiteHistoryEntry(
                archiveDate: "2026-06-11",
                isCurrentSnapshot: true,
                city: "BRANNENS",
                address: "Lulugran, Centrale solaire de Brannens, 33124",
                operators: ["BOUYGUES TELECOM"],
                modTypes: ["new"],
                changeCount: 1,
                changes: [
                    ANFRSiteHistoryChange(id: "163", operatorRaw: "BOUYGUES TELECOM", technology: "LTE 2100", generation: "4G", modTypeRaw: "new", statut: "En service", effectiveDate: "2026-06-11")
                ]
            ),
            ANFRSiteHistoryEntry(
                archiveDate: "2025-12-04",
                isCurrentSnapshot: false,
                city: "BRANNENS",
                address: "Lulugran, Centrale solaire de Brannens, 33124",
                operators: ["FREE MOBILE"],
                modTypes: ["deleted"],
                changeCount: 1,
                changes: [
                    ANFRSiteHistoryChange(id: "214904", operatorRaw: "FREE MOBILE", technology: "UMTS 900", generation: "3G", modTypeRaw: "deleted", statut: "En service", effectiveDate: "2025-12-04")
                ]
            ),
            ANFRSiteHistoryEntry(
                archiveDate: "2025-10-17",
                isCurrentSnapshot: false,
                city: "BRANNENS",
                address: "Lulugran, Centrale solaire de Brannens, 33124",
                operators: ["ORANGE"],
                modTypes: ["activated"],
                changeCount: 1,
                changes: [
                    ANFRSiteHistoryChange(id: "420614", operatorRaw: "ORANGE", technology: "5G NR 2100", generation: "5G", modTypeRaw: "activated", statut: "Techniquement opérationnel", effectiveDate: "2025-10-06")
                ]
            )
        ]
    )

    private static let demoSites: [ANFRMapSite] = {
        func antenna(_ id: String, _ op: String, _ sys: String, _ gen: String, _ type: String, _ statut: String) -> ANFRMapAntenna {
            ANFRMapAntenna(id: id, supId: nil, operatorRaw: op, system: sys, generationRaw: gen, modTypeRaw: type, statut: statut, dateMaj: "2026-06-11", latitude: nil, longitude: nil, city: nil, address: "Le bourg")
        }
        return [
            ANFRMapSite(supId: "29847", latitude: 44.5297, longitude: -0.1806, city: "BRANNENS", antennas: [
                antenna("163", "BOUYGUES TELECOM", "LTE 2100", "4G", "new", "En service")
            ]),
            ANFRMapSite(supId: "71445", latitude: 46.1869, longitude: 5.0689, city: "CHAVEYRIAT", antennas: [
                antenna("403952", "ORANGE", "5G NR 2100", "5G", "activated", "Techniquement opérationnel")
            ]),
            ANFRMapSite(supId: "72975", latitude: 43.1411, longitude: 2.8867, city: "BIZANET", antennas: [
                antenna("404097", "ORANGE", "5G NR 2100", "5G", "activated", "Techniquement opérationnel"),
                antenna("404098", "ORANGE", "LTE 1800", "4G", "activated", "En service")
            ]),
            ANFRMapSite(supId: "81342", latitude: 50.4092, longitude: 3.6042, city: "VICQ", antennas: [
                antenna("615459", "SFR", "UMTS 900", "3G", "deleted", "Projet approuvé")
            ]),
            ANFRMapSite(supId: "101113", latitude: 45.6475, longitude: 2.5550, city: "BOURG LASTIC", antennas: [
                antenna("405515", "ORANGE", "5G NR 2100", "5G", "new", "Projet approuvé")
            ]),
            ANFRMapSite(supId: "120044", latitude: 48.8566, longitude: 2.3522, city: "PARIS", antennas: [
                antenna("700001", "FREE MOBILE", "5G NR 700", "5G", "activated", "En service"),
                antenna("700002", "SFR", "LTE 2600", "4G", "added", "En service")
            ]),
            ANFRMapSite(supId: "130088", latitude: 45.7640, longitude: 4.8357, city: "LYON", antennas: [
                antenna("700101", "BOUYGUES TELECOM", "5G NR 3500", "5G", "new", "En service")
            ]),
            ANFRMapSite(supId: "140122", latitude: 43.2965, longitude: 5.3698, city: "MARSEILLE", antennas: [
                antenna("700201", "ORANGE", "LTE 800", "4G", "activated", "En service"),
                antenna("700202", "FREE MOBILE", "5G NR 3500", "5G", "activated", "En service")
            ])
        ]
    }()
}
