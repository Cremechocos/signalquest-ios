import Foundation

/// Progression ANFR par génération et par bande (`GET /api/anfr/stats?view=bands`,
/// contrat v1 figé le 01/10 avec le serveur, le web et Android) : la 2G et la 3G
/// pour leur extinction, la 4G et la 5G pour leur progression. Une ligne illisible
/// est ignorée sans vider l'écran.
struct ANFRBandStats: Decodable, Equatable, Sendable {
    struct Meta: Decodable, Equatable, Sendable {
        let firstDate: String
        let latestDate: String
        /// Rattrapage incomplet côté serveur : les chiffres peuvent encore bouger.
        let partial: Bool
    }

    struct Band: Decodable, Equatable, Sendable, Identifiable {
        enum Kind: String, Decodable, Sendable {
            /// Supports portant au moins une bande de la génération.
            case generation
            case band
        }

        struct Label: Decodable, Equatable, Sendable {
            let fr: String
            let en: String
            /// « 900 », « n78 », « 2G ».
            let short: String
        }

        let key: String
        /// « 2G » à « 5G ».
        let generation: String
        let kind: Kind
        /// Toujours renseigné pour une bande, nul pour une génération.
        let mhz: Int?
        /// « n78 »… pour la 5G, sinon nul.
        let nrBand: String?
        let label: Label
        let firstDate: String

        var id: String { key }

        /// Libellé dans la langue de l'app, pas dans celle de la région.
        func localizedLabel(language: String? = Bundle.main.preferredLocalizations.first) -> String {
            language == "fr" ? label.fr : label.en
        }
    }

    struct Point: Decodable, Equatable, Sendable {
        let date: String
        /// `sfr`, `orange`, `bytel`, `free`, ou `all` : supports distincts tous
        /// opérateurs, jamais la somme des quatre.
        let operatorKey: String
        let band: String
        let operational: Int
        let projected: Int
        let total: Int

        enum CodingKeys: String, CodingKey {
            case date, band, operational, projected, total
            case operatorKey = "operator"
        }
    }

    /// Calculé par le serveur sur tout l'historique, quelle que soit la fenêtre
    /// demandée : les trois plateformes affichent les mêmes chiffres.
    struct Summary: Decodable, Equatable, Sendable {
        struct Latest: Decodable, Equatable, Sendable {
            let date: String
            let operational: Int
            let projected: Int
        }

        struct Change: Decodable, Equatable, Sendable {
            /// Dernier relevé au moins 7, 28 ou 364 jours plus tôt.
            let referenceDate: String
            /// Écart signé : dernier relevé moins relevé de référence. Négatif en
            /// pleine extinction.
            let operational: Int
        }

        struct Peak: Decodable, Equatable, Sendable {
            let date: String
            let operational: Int
        }

        let operatorKey: String
        let band: String
        let latest: Latest
        let delta1w: Change?
        let delta4w: Change?
        let delta52w: Change?
        /// Maximum de l'historique, le premier en date en cas d'égalité ;
        /// opérationnel à 0 pour une bande qui n'a eu que des projets.
        let peak: Peak
        /// arrondi(1000 × dernier / pic), nul quand le pic vaut 0.
        let shareOfPeakPermille: Int?

        enum CodingKeys: String, CodingKey {
            case band, latest, delta1w, delta4w, delta52w, peak, shareOfPeakPermille
            case operatorKey = "operator"
        }
    }

    let meta: Meta
    let bands: [Band]
    let series: [Point]
    let summary: [Summary]

    enum CodingKeys: String, CodingKey { case meta, bands, series, summary }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(Meta.self, forKey: .meta)
        bands = c.decodeLossyArray([Band].self, forKey: .bands)
        series = c.decodeLossyArray([Point].self, forKey: .series)
        summary = c.decodeLossyArray([Summary].self, forKey: .summary)
    }

    /// Les générations présentes, de la 2G à la 5G.
    var generations: [Band] {
        bands.filter { $0.kind == .generation }.sorted { $0.generation < $1.generation }
    }

    /// Les bandes d'une génération, de la plus basse fréquence à la plus haute.
    func bands(of generation: String) -> [Band] {
        bands
            .filter { $0.kind == .band && $0.generation == generation }
            .sorted { ($0.mhz ?? 0, $0.key) < ($1.mhz ?? 0, $1.key) }
    }

    /// Série d'un opérateur (ou `all`) sur une bande, dans l'ordre des dates.
    /// Une semaine où la bande n'existait pas encore est absente, jamais à 0.
    func series(operatorKey: String, band: String) -> [Point] {
        series.filter { $0.operatorKey == operatorKey && $0.band == band }.sorted { $0.date < $1.date }
    }

    func summary(operatorKey: String, band: String) -> Summary? {
        summary.first { $0.operatorKey == operatorKey && $0.band == band }
    }
}
