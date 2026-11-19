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

    /// Les plages d'un opérateur dans une rangée, rangées par sens (comme le Web, `rangesOf`).
    struct OperatorRanges: Equatable, Sendable {
        let operatorKey: String
        var dl: [Range] = []
        var ul: [Range] = []
        /// TDD : la même plage dans les deux sens.
        var both: [Range] = []
        /// Sens inconnu (`rangeMhz`), en dernier.
        var unknown: [Range] = []
        /// Part du temps en descente d'un TDD (ISED).
        var dlSharePercent: Double?
        /// Générations de cet opérateur dans la rangée, 2G → 5G (support partagé, forme B du 19/11).
        var generations: [BandRow.GenerationTag] = []

        /// Une seule paire FDD : elle tient sur une ligne « ↓ … · ↑ … MHz ».
        var isSinglePair: Bool { dl.count == 1 && ul.count == 1 && both.isEmpty && unknown.isEmpty }

        init(operatorKey: String, blocks: [Block]) {
            self.operatorKey = operatorKey
            var seen = Set<BoundsKey>()
            for block in blocks where seen.insert(BoundsKey(dl: block.dl, ul: block.ul, range: block.range, duplex: nil)).inserted {
                if let range = block.range {
                    unknown.append(range)
                } else if block.duplex == "TDD", let dl = block.dl {
                    both.append(dl)
                    if let share = block.dlSharePercent { dlSharePercent = share }
                } else {
                    if let dl = block.dl { self.dl.append(dl) }
                    if let ul = block.ul { self.ul.append(ul) }
                }
            }
            let byLow: (Range, Range) -> Bool = { $0.low < $1.low }
            dl.sort(by: byLow); ul.sort(by: byLow); both.sort(by: byLow); unknown.sort(by: byLow)
        }
    }

    /// Une rangée de la liste : une bande (`bandMhz`), tous opérateurs confondus, comme le site
    /// (`frequencyFrameView`, choix d'Alexandre du 18/11 d'aligner le cadre sur le site).
    struct BandRow: Equatable, Sendable, Identifiable {
        let id: String
        let bandMhz: Double?
        /// Bande 3GPP des blocs en service (B…, sinon n…, sinon une autre), sinon le système.
        let label: String
        let duplex: String?
        /// Largeur, quand la bande n'a qu'une plage en service, sur un support non partagé et hors plan 3GPP.
        let widthMhz: Double?
        /// Plages distinctes en service, quand il y en a plusieurs au Canada (« 2 porteuses »).
        let carriers: Int?
        let operators: [OperatorRanges]
        /// Générations de la rangée, dans l'ordre 2G → 5G ; « en projet » si aucun bloc n'est en service.
        let generations: [GenerationTag]
        let isPlanned: Bool
        /// Tous les libellés de la rangée, B… puis n… puis les autres (« B28 · n28 ») : l'en-tête
        /// d'une rangée partagée, comme le site.
        var labels: [String] = []
        /// Part du temps en descente d'un TDD de la rangée : en tête de rangée sur un support partagé.
        var dlSharePercent: Double?

        struct GenerationTag: Equatable, Sendable {
            let generation: String
            let planned: Bool
        }
    }

    /// Les rangées de la liste, une par `bandMhz`, de la plus basse à la plus haute ; à fréquence égale,
    /// l'ordre servi. Sans `bandMhz`, une rangée par libellé, en fin de liste. Le serveur range par
    /// génération : garder son ordre mettait 900 (UMTS) avant 700 (B28).
    var bandRows: [BandRow] {
        let visible = operators.map { ($0.operatorKey, Self.visibleBlocks($0.blocks)) }.filter { !$0.1.isEmpty }
        let shared = visible.count > 1
        let all = visible.flatMap(\.1)
        func label(_ blocks: [Block]) -> String {
            let bands = blocks.compactMap(\.band)
            return bands.first { $0.hasPrefix("B") } ?? bands.first { $0.hasPrefix("n") } ?? bands.first
                ?? blocks.first?.system ?? ""
        }
        func rowKey(_ block: Block) -> String {
            block.bandMhz.map { "mhz-\(Self.keyNumber($0))" } ?? "label-\(label([block]))"
        }
        var order: [String] = []
        for block in all where !order.contains(rowKey(block)) { order.append(rowKey(block)) }
        let rows = order.map { key -> BandRow in
            let inRow = all.filter { rowKey($0) == key }
            let live = inRow.filter { !$0.planned }
            let shown = live.isEmpty ? inRow : live
            let distinct = Set(shown.map { BoundsKey(dl: $0.dl, ul: $0.ul, range: $0.range, duplex: nil) }).count
            func tags(_ blocks: [Block]) -> [BandRow.GenerationTag] {
                ["2G", "3G", "4G", "5G"].compactMap { gen -> BandRow.GenerationTag? in
                    guard blocks.contains(where: { $0.generation == gen }) else { return nil }
                    return .init(generation: gen, planned: !blocks.contains { $0.generation == gen && !$0.planned })
                }
            }
            let ranges = visible.compactMap { key2, blocks -> OperatorRanges? in
                let own = blocks.filter { rowKey($0) == key }
                let ownLive = own.filter { !$0.planned }
                guard !own.isEmpty else { return nil }
                var entry = OperatorRanges(operatorKey: key2, blocks: ownLive.isEmpty ? own : ownLive)
                entry.generations = tags(own)
                return entry
            }
            var labels: [String] = []
            for name in inRow.map({ $0.band ?? $0.system }) where !name.isEmpty && !labels.contains(name) {
                labels.append(name)
            }
            labels = labels.filter { $0.hasPrefix("B") } + labels.filter { $0.hasPrefix("n") }
                + labels.filter { !$0.hasPrefix("B") && !$0.hasPrefix("n") }
            return BandRow(
                id: key,
                bandMhz: inRow.first?.bandMhz,
                label: label(shown),
                duplex: shown.lazy.compactMap(\.duplex).first,
                widthMhz: !shared && distinct == 1 && source != .bandPlan ? shown.first?.widthMhz.flatMap { $0 > 0 ? $0 : nil } : nil,
                carriers: !shared && distinct > 1 && source == .ised ? distinct : nil,
                operators: ranges,
                generations: tags(inRow),
                isPlanned: live.isEmpty,
                labels: labels,
                dlSharePercent: inRow.lazy.compactMap(\.dlSharePercent).first
            )
        }
        return rows.enumerated().sorted { a, b in
            let fa = a.element.bandMhz ?? .infinity, fb = b.element.bandMhz ?? .infinity
            return fa != fb ? fa < fb : a.offset < b.offset
        }.map(\.element)
    }

    /// Porteuses distinctes en service, sur tous les opérateurs : en-tête du cadre au Canada seulement.
    var carrierCount: Int? {
        guard source == .ised else { return nil }
        return operators.reduce(0) { sum, op in
            sum + Set(Self.visibleBlocks(op.blocks).filter { !$0.planned }
                .map { BoundsKey(dl: $0.dl, ul: $0.ul, range: $0.range, duplex: nil) }).count
        }
    }

    /// Les opérateurs dans l'ordre des lignes opérateur de la fiche, l'actif en tête (choix d'Alexandre
    /// du 19/11) ; un opérateur servi hors de cette liste garde sa place servie, à la suite.
    func ordered(by keys: [String]) -> FrequencyBlocks {
        let rank = Dictionary(keys.enumerated().map { ($1.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = operators.enumerated().sorted { a, b in
            let ra = rank[a.element.operatorKey.uppercased()] ?? Int.max
            let rb = rank[b.element.operatorKey.uppercased()] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return FrequencyBlocks(source: source, datasetDate: datasetDate, operators: sorted)
    }

    /// Les opérateurs du support sans bloc servi, dans l'ordre du support : une ligne « Bandes non
    /// publiées » chacun. Seulement sur une réponse partagée dont toutes les clés sont celles du
    /// support : une réponse à un seul opérateur (serveur d'avant le 19/11) ne dit rien des autres.
    func unpublishedOperators(of support: [String]) -> [String] {
        let served = operators.filter { !Self.visibleBlocks($0.blocks).isEmpty }.map { $0.operatorKey.uppercased() }
        let known = Set(support.map { $0.uppercased() })
        guard served.count > 1, served.allSatisfy(known.contains) else { return [] }
        var seen = Set(served)
        return support.filter { seen.insert($0.uppercased()).inserted && $0.uppercased() != "ALL" }
    }

    private static func keyNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
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
        // Une barre par plage, comme le site (`bars`) : en service avant en projet, puis la
        // génération la plus récente ; B1 et n1 aux mêmes bornes ne font qu'une barre.
        func marks(_ blocks: [Block]) -> [Mark] {
            let rank = ["2G": 2, "3G": 3, "4G": 4, "5G": 5]
            let ordered = blocks.enumerated().sorted { a, b in
                if a.element.planned != b.element.planned { return !a.element.planned }
                let ga = rank[a.element.generation] ?? 0, gb = rank[b.element.generation] ?? 0
                return ga != gb ? ga > gb : a.offset < b.offset
            }.map(\.element)
            var seen = Set<BoundsKey>()
            return ordered.compactMap { block -> Mark? in
                guard let range = block.drawnRange,
                      seen.insert(BoundsKey(dl: block.dl, ul: block.ul, range: block.range, duplex: nil)).inserted
                else { return nil }
                return Mark(range: range, generation: block.generation, planned: block.planned)
            }.sorted { $0.range.low < $1.range.low }
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
