import Foundation

/// Texte traduisible d'un post automatique (contrat `feed-text-keys` v1, #695) :
/// le serveur sert une clé stable et des arguments typés, l'app écrit la phrase
/// dans sa langue. Tout ou rien : une clé inconnue, un argument manquant, mal
/// typé, vide ou hors de sa plage, une valeur d'énumération inconnue donnent
/// `nil`, et la carte garde `text` (lot F, F8).
struct FeedTextKey: Equatable {
    let key: String
    private let args: [String: JSONValue]

    private enum Kind {
        case integer, decimal, string, identifierType, countryCode
    }

    /// Les 36 clés de la v1 et le type de chaque argument.
    private static let catalog: [String: [String: Kind]] = [
        "feed.speedtest.done": ["downloadMbps": .decimal],
        "feed.speedtest.done_no_speed": [:],
        "feed.session.completed": ["distanceMeters": .integer, "measureCount": .integer],
        "feed.badge.earned": ["badgeId": .string, "badgeName": .string],
        "feed.level.reached": ["level": .integer],
        "feed.quest.completed": ["questKey": .string, "questTitle": .string],
        "feed.streak.bonus": ["days": .integer],
        "feed.site.first_discovery": [:],
        "feed.site.visited": [:],
        "feed.department.new": ["departmentCode": .string],
        "feed.validation.submitted": ["identifierType": .identifierType],
        "feed.validation.submitted_with_place": ["identifierType": .identifierType, "place": .string],
        "feed.validation.confirmed": ["identifierType": .identifierType],
        "feed.validation.confirmed_with_place": ["identifierType": .identifierType, "place": .string],
        "feed.validation.created": ["identifierType": .identifierType],
        "feed.validation.created_with_place": ["identifierType": .identifierType, "place": .string],
        "feed.validation.direct": ["identifierType": .identifierType, "identifierValue": .integer],
        "feed.validation.offline": ["identifierType": .identifierType, "identifierValue": .integer],
        "feed.antenna_report.accepted": [:],
        "feed.antenna_report.accepted_with_place": ["place": .string],
        "feed.bug_report.resolved": [:],
        "feed.photo.uploaded": [:],
        "feed.photo.uploaded_with_place": ["place": .string],
        "feed.photo.approved": [:],
        "feed.photo.site": [:],
        "feed.photo.site_with_place": ["place": .string],
        "feed.photo.custom_site": ["siteName": .string],
        "feed.custom_site.created": ["siteName": .string],
        "feed.rating.signal": ["stars": .integer],
        "feed.netmonster.daily": ["created": .integer, "updated": .integer, "addressesUpdated": .integer, "countryCode": .countryCode],
        "feed.experience.done": [:],
        "feed.canada.speedtest_share": [:],
        "feed.canada.theme_equipped": [:],
        "feed.canada.theme_long_press": [:],
        "feed.canada.radio_badge_press": [:],
        "feed.canada.live_signal_combo": [:],
    ]

    /// Types des arguments dans les mots du contrat (`integer`, `enum:…`), pour
    /// les comparer aux vecteurs.
    static var contractArgs: [String: [String: String]] {
        catalog.mapValues { schema in
            schema.mapValues { kind in
                switch kind {
                case .integer: return "integer"
                case .decimal: return "decimal"
                case .string, .countryCode: return "string"
                case .identifierType: return "enum:cellid|pci|enb|gnb"
                }
            }
        }
    }

    /// Libellé d'un identifiant radio, le même dans les deux langues.
    private static let identifierLabels = ["cellid": "Cell ID", "pci": "PCI", "enb": "eNB", "gnb": "gNB"]

    init?(key: String?, args: [String: JSONValue]?) {
        guard let key, let schema = Self.catalog[key] else { return nil }
        let args = args ?? [:]
        for (name, kind) in schema {
            guard let value = args[name], Self.isValid(value, kind) else { return nil }
        }
        if key == "feed.rating.signal", let stars = Self.integer(args["stars"]), !(1...5).contains(stars) { return nil }
        self.key = key
        self.args = args
    }

    private static func isValid(_ value: JSONValue, _ kind: Kind) -> Bool {
        switch (kind, value) {
        case (.integer, _): return integer(value) != nil
        case (.decimal, .number(let number)): return number.isFinite && number > 0
        case (.string, .string(let text)): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case (.identifierType, .string(let text)): return identifierLabels[text] != nil
        case (.countryCode, .string(let code)): return inCountry(code) != nil
        default: return false
        }
    }

    /// Entier JSON positif ou nul ; un gNB peut dépasser 2³¹ − 1.
    private static func integer(_ value: JSONValue?) -> Int64? {
        guard case .number(let number)? = value, number.isFinite, number >= 0,
              number == number.rounded(), number <= 9_007_199_254_740_991 else { return nil }
        return Int64(number)
    }

    func integer(_ name: String) -> Int64? { Self.integer(args[name]) }

    func string(_ name: String) -> String? {
        guard case .string(let text)? = args[name] else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var identifier: String { string("identifierType").flatMap { Self.identifierLabels[$0] } ?? "" }
    private var place: String { string("place") ?? "" }
    /// Un identifiant radio n'est pas une quantité : jamais de séparateur de
    /// milliers (« eNB 123456 »), d'où la chaîne plutôt que l'entier.
    private var identifierValue: String { integer("identifierValue").map(String.init) ?? "" }

    /// « au Luxembourg », « in Belgium » : la préposition dépend du pays. Un
    /// pays que l'app ne sait pas dire fait garder `text`.
    private static func inCountry(_ code: String) -> String? {
        switch code {
        case "LU": return String(localized: "au Luxembourg")
        case "BE": return String(localized: "en Belgique")
        case "FR": return String(localized: "en France")
        case "CH": return String(localized: "en Suisse")
        case "CA": return String(localized: "au Canada")
        case "MC": return String(localized: "à Monaco")
        default: return nil
        }
    }

    /// La phrase dans la langue de l'app. `feed.custom_site.created` est un
    /// prédicat, à lire après le nom de l'auteur (« a ajouté … sur la carte »).
    var text: String {
        let count = { (name: String) in Int(clamping: integer(name) ?? 0) }
        switch key {
        case "feed.speedtest.done":
            guard case .number(let mbps)? = args["downloadMbps"] else { return String(localized: "Test de débit effectué") }
            return String(localized: "Test de débit effectué (\(SQUnits.throughput(mbps: mbps)))")
        case "feed.speedtest.done_no_speed": return String(localized: "Test de débit effectué")
        case "feed.session.completed":
            let distance = SQUnits.distance(meters: Double(integer("distanceMeters") ?? 0))
            let measures = String(localized: "\(count("measureCount")) mesures")
            return String(localized: "Session de couverture terminée : \(distance), \(measures)")
        case "feed.badge.earned": return String(localized: "Badge « \(string("badgeName") ?? "") » obtenu !")
        case "feed.level.reached": return String(localized: "Niveau \(count("level")) atteint !")
        case "feed.quest.completed": return String(localized: "Quête « \(string("questTitle") ?? "") » terminée")
        case "feed.streak.bonus": return String(localized: "Série de \(count("days")) jours consécutifs !")
        case "feed.site.first_discovery": return String(localized: "Site découvert en premier !")
        case "feed.site.visited": return String(localized: "Nouveau site exploré")
        case "feed.department.new": return String(localized: "Nouveau département exploré (\(string("departmentCode") ?? ""))")
        case "feed.validation.submitted": return String(localized: "Validation \(identifier) soumise")
        case "feed.validation.submitted_with_place": return String(localized: "Validation \(identifier) soumise · \(place)")
        case "feed.validation.confirmed": return String(localized: "Validation \(identifier) confirmée")
        case "feed.validation.confirmed_with_place": return String(localized: "Validation \(identifier) confirmée · \(place)")
        case "feed.validation.created": return String(localized: "Nouvelle validation \(identifier) créée")
        case "feed.validation.created_with_place": return String(localized: "Nouvelle validation \(identifier) créée · \(place)")
        case "feed.validation.direct":
            return String(localized: "Identification directe depuis la carte : \(identifier) \(identifierValue)")
        case "feed.validation.offline":
            return String(localized: "Identification hors-ligne : \(identifier) \(identifierValue)")
        case "feed.antenna_report.accepted": return String(localized: "Signalement d’un problème d’identification accepté")
        case "feed.antenna_report.accepted_with_place":
            return String(localized: "Signalement d’un problème d’identification accepté · \(place)")
        case "feed.bug_report.resolved": return String(localized: "Signalement de bug validé")
        case "feed.photo.uploaded": return String(localized: "Photo uploadée")
        case "feed.photo.uploaded_with_place": return String(localized: "Photo uploadée · \(place)")
        case "feed.photo.approved": return String(localized: "Photo approuvée")
        case "feed.photo.site": return String(localized: "Photo terrain")
        case "feed.photo.site_with_place": return String(localized: "Photo terrain · \(place)")
        case "feed.photo.custom_site": return String(localized: "Photo terrain ajoutée pour « \(string("siteName") ?? "") »")
        case "feed.custom_site.created": return String(localized: "a ajouté \(string("siteName") ?? "") sur la carte")
        case "feed.rating.signal": return String(localized: "A évalué ce signal · \(count("stars"))/5")
        case "feed.netmonster.daily":
            let created = String(localized: "\(count("created")) nouvelles antennes")
            let updated = String(localized: "\(count("updated")) mises à jour")
            let addresses = String(localized: "\(count("addressesUpdated")) adresses mises à jour")
            let country = string("countryCode").flatMap(Self.inCountry) ?? ""
            return String(localized: "\(created), \(updated) et \(addresses) \(country)")
        case "feed.experience.done": return String(localized: "Test d’expérience")
        case "feed.canada.speedtest_share": return String(localized: "Premier partage speedtest en thème Canada")
        case "feed.canada.theme_equipped": return String(localized: "Preset Canada équipé")
        case "feed.canada.theme_long_press": return String(localized: "Appui long sur le preset Canada")
        case "feed.canada.radio_badge_press": return String(localized: "Badge Canada découvert dans Radio")
        case "feed.canada.live_signal_combo": return String(localized: "Combo LIVE SIGNAL Canada")
        default: return ""
        }
    }
}
