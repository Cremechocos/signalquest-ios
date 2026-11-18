import Foundation

/// FREQ-BLOCKS r0 à r0.6 (contrat Backend du 18/11) : les bornes de fréquences du site, par
/// opérateur. Servi sous `antenna.frequencyBlocks` de `android/map/antenna/{id}`. `nil` : pas de
/// source pour ce pays, site sans bande relevée, ou serveur antérieur. En France, le champ reste
/// `nil` jusqu'au passage mensuel qui suit le déploiement.
struct FrequencyBlocks: Decodable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Bornes déclarées à l'ANFR (fichier SUP_BANDE du jeu mensuel).
        case anfr
        /// Porteuses inscrites à ISED (Canada).
        case ised
        /// Plages entières des bandes relevées par la communauté (Belgique, Suisse…).
        case bandPlan
        /// Valeur que cette version ne connaît pas : le cadre s'affiche sans pied de source.
        case unrecognized

        init(raw: String?) {
            switch raw {
            case "anfr_sup_bande": self = .anfr
            case "ised": self = .ised
            case "3gpp_band_plan": self = .bandPlan
            default: self = .unrecognized
            }
        }
    }

    struct Operator: Decodable, Equatable, Sendable {
        let operatorKey: String
        let blocks: [Block]

        enum CodingKeys: String, CodingKey { case operatorKey, blocks }

        init(operatorKey: String, blocks: [Block]) {
            self.operatorKey = operatorKey
            self.blocks = blocks
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            operatorKey = c.decodeFlexibleString(forKey: .operatorKey) ?? ""
            blocks = c.decodeLossyArray([LossyBlock].self, forKey: .blocks).compactMap(\.block)
        }
    }

    /// Une plage [bas, haut] en MHz.
    struct Range: Equatable, Hashable, Sendable {
        let low: Double
        let high: Double
    }

    struct Block: Equatable, Sendable {
        /// Libellé brut de la source (« LTE 800 », « UMTS 2100 »), affiché quand `band` est nul.
        let system: String
        /// « 2G », « 3G », « 4G » ou « 5G ».
        let generation: String
        /// Libellé 3GPP (« B20 », « n78 ») ; nul en 2G et 3G.
        let band: String?
        let bandMhz: Double?
        let dl: Range?
        let ul: Range?
        /// Plage seule quand le sens est inconnu (`duplex` nul) : dl et ul sont alors nuls.
        let range: Range?
        let widthMhz: Double?
        /// « FDD », « TDD », « SDL » ou nul (sens inconnu).
        let duplex: String?
        let planned: Bool
        /// Part du temps en descente d'un TDD (Canada seulement).
        let dlSharePercent: Double?

        /// Deux blocs aux bornes identiques sont strictement égaux (r0.4) : ils se regroupent.
        var boundsKey: BoundsKey { BoundsKey(dl: dl, ul: ul, range: range, duplex: duplex) }

        /// La plage dessinée sur la règle : la descente, sinon la plage seule, sinon la montée.
        var drawnRange: Range? { dl ?? range ?? ul }
    }

    struct BoundsKey: Hashable, Sendable {
        let dl: Range?
        let ul: Range?
        let range: Range?
        let duplex: String?
    }

    let source: Source
    let datasetDate: String?
    let operators: [Operator]

    enum CodingKeys: String, CodingKey { case source, datasetDate, operators }

    init(source: Source, datasetDate: String?, operators: [Operator]) {
        self.source = source
        self.datasetDate = datasetDate
        self.operators = operators
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = Source(raw: c.decodeFlexibleString(forKey: .source))
        datasetDate = c.decodeFlexibleString(forKey: .datasetDate)
        operators = c.decodeLossyArray([Operator].self, forKey: .operators)
            .filter { !$0.operatorKey.isEmpty && !$0.blocks.isEmpty }
    }

    /// Un bloc mal formé est écarté sans faire tomber les autres.
    private struct LossyBlock: Decodable {
        let block: Block?

        enum CodingKeys: String, CodingKey {
            case system, generation, band, bandMhz, dlMhz, ulMhz, rangeMhz, widthMhz, duplex, planned, dlSharePercent
        }

        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { block = nil; return }
            func range(_ key: CodingKeys) -> Range? {
                guard let values = try? c.decodeIfPresent([Double].self, forKey: key), values.count == 2,
                      values[0].isFinite, values[1].isFinite, values[0] > 0, values[0] <= values[1] else { return nil }
                return Range(low: values[0], high: values[1])
            }
            func number(_ key: CodingKeys) -> Double? {
                (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 }.flatMap { $0.isFinite ? $0 : nil }
            }
            let generation = c.decodeFlexibleString(forKey: .generation)?.uppercased() ?? ""
            let dl = range(.dlMhz), ul = range(.ulMhz), plage = range(.rangeMhz)
            guard ["2G", "3G", "4G", "5G"].contains(generation), dl != nil || ul != nil || plage != nil else {
                block = nil
                return
            }
            let band = c.decodeFlexibleString(forKey: .band)?.trimmingCharacters(in: .whitespaces)
            let duplex = c.decodeFlexibleString(forKey: .duplex)?.uppercased()
            block = Block(
                system: c.decodeFlexibleString(forKey: .system) ?? "",
                generation: generation,
                band: band?.isEmpty == false ? band : nil,
                bandMhz: number(.bandMhz),
                dl: dl,
                ul: ul,
                range: plage,
                widthMhz: number(.widthMhz),
                duplex: ["FDD", "TDD", "SDL"].contains(duplex ?? "") ? duplex : nil,
                planned: (try? c.decodeIfPresent(Bool.self, forKey: .planned)) as? Bool ?? false,
                dlSharePercent: number(.dlSharePercent)
            )
        }
    }
}

// MARK: - Ce que le cadre affiche

extension FrequencyBlocks {
    /// Les blocs d'un opérateur à afficher : un bloc en projet identique à un bloc en service n'est
    /// pas répété (r0.1 §4, comme le Web). L'ordre servi est gardé (r0.6 §3).
    static func visibleBlocks(_ blocks: [Block]) -> [Block] {
        let inService = Set(blocks.filter { !$0.planned }.map(\.sameBlockKey))
        return blocks.filter { !$0.planned || !inService.contains($0.sameBlockKey) }
    }

    /// Un groupe de bornes identiques d'un opérateur, avec les générations qui les déclarent.
    struct BoundsGroup: Equatable, Sendable {
        let operatorKey: String
        let blocks: [Block]
        var first: Block { blocks[0] }
        /// Générations dans l'ordre servi, chacune « en projet » si tous ses blocs le sont.
        var generations: [(generation: String, planned: Bool)] {
            var order: [String] = []
            var planned: [String: Bool] = [:]
            for block in blocks {
                if planned[block.generation] == nil { order.append(block.generation) }
                planned[block.generation] = (planned[block.generation] ?? true) && block.planned
            }
            return order.map { ($0, planned[$0] ?? false) }
        }
        var isPlanned: Bool { blocks.allSatisfy(\.planned) }
        var dlSharePercent: Double? { blocks.lazy.compactMap(\.dlSharePercent).first }

        static func == (lhs: BoundsGroup, rhs: BoundsGroup) -> Bool {
            lhs.operatorKey == rhs.operatorKey && lhs.blocks == rhs.blocks
        }
    }

    /// Une rangée de la liste : une bande (même fréquence et même mode de duplex), ses groupes de
    /// bornes, tous opérateurs confondus sur un support partagé.
    struct BandRow: Equatable, Sendable, Identifiable {
        let id: String
        let bandMhz: Double?
        /// Libellé 3GPP du premier bloc qui en a un, sinon le système brut (2G, 3G).
        let label: String
        let duplex: String?
        let groups: [BoundsGroup]

        var isPlanned: Bool { groups.allSatisfy(\.isPlanned) }

        /// Générations de la rangée, dans l'ordre 2G → 5G ; « en projet » si aucun bloc n'est en service.
        var generations: [(generation: String, planned: Bool)] {
            var planned: [String: Bool] = [:]
            for group in groups {
                for entry in group.generations {
                    planned[entry.generation] = (planned[entry.generation] ?? true) && entry.planned
                }
            }
            return ["2G", "3G", "4G", "5G"].compactMap { gen in planned[gen].map { (gen, $0) } }
        }
    }

    /// Les rangées de la liste, de la plus basse fréquence à la plus haute.
    var bandRows: [BandRow] {
        var rows: [String: (bandMhz: Double?, label: String?, system: String, duplex: String?, groups: [BoundsGroup])] = [:]
        var order: [String] = []
        for op in operators {
            var groups: [BoundsKey: [Block]] = [:]
            var groupOrder: [BoundsKey] = []
            for block in Self.visibleBlocks(op.blocks) {
                if groups[block.boundsKey] == nil { groupOrder.append(block.boundsKey) }
                groups[block.boundsKey, default: []].append(block)
            }
            for key in groupOrder {
                let blocks = groups[key] ?? []
                guard let first = blocks.first else { continue }
                let mhz = first.bandMhz ?? first.drawnRange.map { ($0.low).rounded() }
                let rowKey = "\(mhz.map { String(Int($0.rounded())) } ?? first.system)|\(first.duplex ?? "-")"
                let group = BoundsGroup(operatorKey: op.operatorKey, blocks: blocks)
                let label = blocks.lazy.compactMap(\.band).first
                if var row = rows[rowKey] {
                    row.groups.append(group)
                    if row.label == nil { row.label = label }
                    rows[rowKey] = row
                } else {
                    rows[rowKey] = (mhz, label, first.system, first.duplex, [group])
                    order.append(rowKey)
                }
            }
        }
        // La liste suit la règle de gauche à droite (planche) : par fréquence, puis génération,
        // puis ordre servi. Le serveur range par génération d'abord, ce qui mettait 2100 (3G) en tête.
        let rank = ["2G": 2, "3G": 3, "4G": 4, "5G": 5]
        let indexed = order.enumerated().compactMap { index, key -> (Int, BandRow)? in
            guard let row = rows[key] else { return nil }
            return (index, BandRow(id: key, bandMhz: row.bandMhz, label: row.label ?? row.system,
                                   duplex: row.duplex, groups: row.groups))
        }
        return indexed.sorted { a, b in
            let fa = a.1.bandMhz ?? .infinity, fb = b.1.bandMhz ?? .infinity
            if fa != fb { return fa < fb }
            let ga = a.1.groups.compactMap { rank[$0.first.generation] }.min() ?? 9
            let gb = b.1.groups.compactMap { rank[$0.first.generation] }.min() ?? 9
            return ga != gb ? ga < gb : a.0 < b.0
        }.map(\.1)
    }

    /// Le cadre n'a rien à montrer.
    var isEmpty: Bool { operators.allSatisfy { Self.visibleBlocks($0.blocks).isEmpty } }

    /// Un bloc en projet est-il affiché ? Commande « Pointillé : en projet. » en pied de cadre.
    var showsPlanned: Bool { operators.contains { Self.visibleBlocks($0.blocks).contains(where: \.planned) } }

    /// Une ligne de la règle : une par génération présente (un seul opérateur), une par opérateur
    /// sur un support partagé.
    struct StripRow: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable { case generation(String), operatorKey(String) }
        let kind: Kind
        let marks: [Mark]
        var id: String {
            switch kind {
            case .generation(let gen): return "g-\(gen)"
            case .operatorKey(let key): return "o-\(key)"
            }
        }
    }

    struct Mark: Equatable, Sendable {
        let range: Range
        let generation: String
        let planned: Bool
    }

    var stripRows: [StripRow] {
        let visible = operators.map { ($0.operatorKey, Self.visibleBlocks($0.blocks)) }
        func marks(_ blocks: [Block]) -> [Mark] {
            var seen = Set<String>()
            return blocks.compactMap { block in
                guard let range = block.drawnRange else { return nil }
                let key = "\(range.low)-\(range.high)-\(block.generation)-\(block.planned)"
                guard seen.insert(key).inserted else { return nil }
                return Mark(range: range, generation: block.generation, planned: block.planned)
            }
        }
        if visible.count > 1 {
            return visible.compactMap { key, blocks in
                let m = marks(blocks)
                return m.isEmpty ? nil : StripRow(kind: .operatorKey(key), marks: m)
            }
        }
        let blocks = visible.first?.1 ?? []
        return ["2G", "3G", "4G", "5G"].compactMap { gen in
            let m = marks(blocks.filter { $0.generation == gen })
            return m.isEmpty ? nil : StripRow(kind: .generation(gen), marks: m)
        }
    }

    /// Bornes de la règle en MHz : 600 MHz à 4 GHz (planche), élargies si un bloc en sort.
    var stripDomain: Range {
        let ranges = stripRows.flatMap(\.marks).map(\.range)
        let low = min(600, ranges.map(\.low).min() ?? 600)
        let high = max(4000, ranges.map(\.high).max() ?? 4000)
        return Range(low: low, high: high)
    }
}

private extension FrequencyBlocks.Block {
    /// Même bloc, en projet ou en service : mêmes bornes, même génération, même bande.
    var sameBlockKey: String {
        "\(generation)|\(band ?? system)|\(boundsKey.hashValueString)"
    }
}

private extension FrequencyBlocks.BoundsKey {
    var hashValueString: String {
        func text(_ range: FrequencyBlocks.Range?) -> String { range.map { "\($0.low)-\($0.high)" } ?? "_" }
        return "\(text(dl))/\(text(ul))/\(text(range))/\(duplex ?? "_")"
    }
}
