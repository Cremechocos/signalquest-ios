import Foundation

// Données de démonstration : absentes des builds Release (MES-33).
#if DEBUG
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

    // MARK: Générations et bandes (`view=bands`)

    /// (clé, génération, MHz, bande NR, libellé FR, libellé EN, court, dernier
    /// relevé, écart sur 52 semaines, pic, date du pic), d'après les ordres de
    /// grandeur publiés par l'ANFR au 01/10/2026, tous opérateurs.
    private static let bandRows: [(String, String, Int?, String?, String, String, String, Int, Int, Int, String)] = [
        ("2g", "2G", nil, nil, "2G (tous supports)", "2G (all sites)", "2G", 34446, -3640, 39736, "2024-01-04"),
        ("2g900", "2G", 900, nil, "2G 900 MHz", "2G 900 MHz", "900", 34322, -3586, 39419, "2024-01-04"),
        ("2g1800", "2G", 1800, nil, "2G 1800 MHz", "2G 1800 MHz", "1800", 358, -371, 4522, "2021-12-29"),
        ("3g", "3G", nil, nil, "3G (tous supports)", "3G (all sites)", "3G", 51334, -9829, 61290, "2025-10-30"),
        ("3g900", "3G", 900, nil, "3G 900 MHz", "3G 900 MHz", "900", 50806, -9757, 60709, "2025-10-30"),
        ("3g2100", "3G", 2100, nil, "3G 2100 MHz", "3G 2100 MHz", "2100", 4881, -1473, 36974, "2021-12-29"),
        ("4g", "4G", nil, nil, "4G (tous supports)", "4G (all sites)", "4G", 65384, 2375, 65384, "2026-10-01"),
        ("4g700", "4G", 700, nil, "4G 700 MHz", "4G 700 MHz", "700", 53917, 2595, 53917, "2026-10-01"),
        ("4g800", "4G", 800, nil, "4G 800 MHz", "4G 800 MHz", "800", 54267, 2063, 54267, "2026-10-01"),
        ("4g900", "4G", 900, nil, "4G 900 MHz", "4G 900 MHz", "900", 24746, 16878, 24746, "2026-10-01"),
        ("4g1800", "4G", 1800, nil, "4G 1800 MHz", "4G 1800 MHz", "1800", 57045, 2471, 57045, "2026-10-01"),
        ("4g2100", "4G", 2100, nil, "4G 2100 MHz", "4G 2100 MHz", "2100", 49405, 1669, 49779, "2026-09-03"),
        ("4g2600", "4G", 2600, nil, "4G 2600 MHz", "4G 2600 MHz", "2600", 45087, 2173, 45087, "2026-10-01"),
        ("5g", "5G", nil, nil, "5G (tous supports)", "5G (all sites)", "5G", 49367, 5066, 49367, "2026-10-01"),
        ("n28", "5G", 700, "n28", "5G n28 700 MHz", "5G n28 700 MHz", "n28", 32086, 2693, 32086, "2026-10-01"),
        ("n1", "5G", 2100, "n1", "5G n1 2100 MHz", "5G n1 2100 MHz", "n1", 24030, 4536, 24030, "2026-10-01"),
        ("n78", "5G", 3500, "n78", "5G n78 3,5 GHz", "5G n78 3.5 GHz", "n78", 33066, 3424, 33066, "2026-10-01"),
    ]

    /// Réponse de démonstration au format du contrat, filtrée comme le serveur :
    /// séries hebdomadaires linéaires sur la fenêtre, résumé sur tout l'historique.
    static func bandStats(generation: String?, operatorKey: String?, weeks: Int?) -> ANFRBandStats {
        let operatorKey = operatorKey ?? "all"
        let scales: [String: Double] = ["all": 1, "orange": 0.46, "sfr": 0.41, "bytel": 0.39, "free": 0.43]
        let scale = scales[operatorKey] ?? 1
        let rows = bandRows.filter { generation == nil || $0.1.lowercased() == generation?.lowercased() }
        let weekCount = max(1, min(weeks ?? 53, 520))
        let latest = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                    year: 2026, month: 10, day: 1).date ?? Date()
        func day(_ weeksBack: Int) -> String {
            let date = latest.addingTimeInterval(-Double(weeksBack) * 7 * 86_400)
            return date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        }
        var bands: [[String: Any]] = []
        var series: [[String: Any]] = []
        var summary: [[String: Any]] = []
        for row in rows {
            let value = { (count: Int) in Int((Double(count) * scale).rounded()) }
            let now = value(row.7), delta52 = value(row.8)
            var band: [String: Any] = [
                "key": row.0, "generation": row.1, "kind": row.2 == nil ? "generation" : "band",
                "label": ["fr": row.4, "en": row.5, "short": row.6], "firstDate": "2021-12-29",
            ]
            band["mhz"] = row.2.map { $0 as Any } ?? NSNull()
            band["nrBand"] = row.3.map { $0 as Any } ?? NSNull()
            bands.append(band)
            for weeksBack in stride(from: weekCount - 1, through: 0, by: -1) {
                let operational = now - delta52 * weeksBack / 52
                series.append([
                    "date": day(weeksBack), "operator": operatorKey, "band": row.0,
                    "operational": operational, "projected": operational / 12, "total": operational + operational / 12,
                ])
            }
            let peak = max(value(row.9), now)
            func change(_ weeksBack: Int) -> [String: Any] {
                ["referenceDate": day(weeksBack), "operational": delta52 * weeksBack / 52]
            }
            var item: [String: Any] = ["operator": operatorKey, "band": row.0]
            item["latest"] = ["date": day(0), "operational": now, "projected": now / 12] as [String: Any]
            item["delta1w"] = change(1)
            item["delta4w"] = change(4)
            item["delta52w"] = change(52)
            item["peak"] = ["date": row.10, "operational": peak] as [String: Any]
            let share: Any = peak > 0 ? Int((1_000 * Double(now) / Double(peak)).rounded()) : NSNull()
            item["shareOfPeakPermille"] = share
            summary.append(item)
        }
        let json: [String: Any] = [
            "meta": ["firstDate": day(weekCount - 1), "latestDate": day(0), "partial": false],
            "bands": bands, "series": series, "summary": summary,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        // Construite ici, au format du contrat : un échec serait un défaut de ce fichier.
        return try! JSONDecoder.signalQuest.decode(ANFRBandStats.self, from: data)
    }
}
#endif
