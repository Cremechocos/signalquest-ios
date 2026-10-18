import Foundation

// MARK: - Partages & localisation (parité Android)
//
// Android écrit dans `message.metadata` (chaîne JSON) deux structures que le fil
// iOS doit savoir afficher pour l'inter-compatibilité :
//   { "shareCard": { version, kind, id, title, subtitle, url, metrics{}, signal{} } }
//   { "location":  { lat, lng, place } }
// On les décode en lecture seule depuis le metadata (jamais besoin de les
// produire pour le rendu). Le metadata des cartes voyage EN CLAIR même en
// conversation E2EE (Android n'y chiffre que le texte de repli).

/// Données structurées d'une « Mesure de signal » partagée (carte dédiée).
struct SignalShareData: Equatable {
    let rsrp: Int?
    let band: String?
    let site: String?
    let operatorName: String?
    let technology: String?
    let stars: Int?
    let score: Int?

    /// Score 0–100 : champ `score` explicite, sinon dérivé des étoiles (×20).
    var resolvedScore: Int? {
        if let score { return score }
        if let stars { return stars * 20 }
        return nil
    }

    var subtitleLine: String? {
        [operatorName, technology]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .nilIfEmpty
    }
}

// MARK: - Publication partagée (kind "social_post")
//
// Depuis le durcissement backend (commit b9bbc1b8), le partage d'un post écrit un
// `shareCard` fidèle : auteur, texte, vignette image et l'éventuelle mesure
// (signal / speedtest / session). On les décode pour afficher une carte riche.

/// Auteur d'une publication partagée.
struct ShareCardAuthor: Equatable {
    let name: String?
    let handle: String?
    let avatarUrl: URL?

    var displayName: String { name?.nilIfEmpty ?? handle?.nilIfEmpty ?? "SignalQuest" }
    /// Handle normalisé avec « @ » de tête.
    var handleLine: String? {
        guard let h = handle?.nilIfEmpty else { return nil }
        return h.hasPrefix("@") ? h : "@\(h)"
    }
}

/// Mesure « speedtest » portée par une publication partagée.
struct SpeedtestShareData: Equatable {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let pingMs: Double?
    let technology: String?
    let operatorName: String?
}

/// Mesure « session de couverture » portée par une publication partagée.
struct SessionShareData: Equatable {
    let points: Int?
    let distanceKm: Double?
    let durationSeconds: Int?
    let technologies: String?
}

/// Une ligne « label : valeur » d'une carte de partage générique.
struct ShareCardRow: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// Carte de partage (speedtest / session / mesure signal / post social) lue
/// depuis `metadata.shareCard`.
struct ShareCardData: Equatable {
    let kind: String
    /// Id de la cible du partage (`shareCard.id`) — pour `social_post`, c'est
    /// l'id backend de la publication (utilisé pour la charger en direct).
    let targetId: String?
    let title: String
    let subtitle: String?
    let url: String?
    let rows: [ShareCardRow]
    let signal: SignalShareData?
    // Champs enrichis du partage de publication (kind == "social_post").
    let author: ShareCardAuthor?
    let text: String?
    let imageUrl: URL?
    let speedtest: SpeedtestShareData?
    let session: SessionShareData?

    /// Le lien vient de l'expéditeur : seul `https` est ouvert. Hors des
    /// domaines SignalQuest, la carte montre la destination avant d'ouvrir.
    var openURL: URL? {
        guard let url = url.flatMap(URL.init(string:)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Domaine SignalQuest (site, API, médias) ou hôte de l'environnement courant.
    static func isSignalQuestURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        if host == "signalquest.fr" || host.hasSuffix(".signalquest.fr") { return true }
        let config = AppConfig.current
        return [config.appBaseURL.host, config.apiBaseURL.host]
            .compactMap { $0?.lowercased() }
            .contains(host)
    }

    /// Image d'une carte : chargée seulement depuis nos domaines, jamais depuis
    /// un hôte choisi par l'expéditeur (même règle que les aperçus de lien).
    private static func signalQuestImageURL(_ value: Any?) -> URL? {
        guard let url = optString(value).flatMap(URL.init(string:)), isSignalQuestURL(url) else { return nil }
        return url
    }

    /// Id de la publication partagée (kind « social_post ») — clé de chargement
    /// du post réel dans la conversation. Nil pour les autres kinds ou les
    /// anciens partages sans id.
    var socialPostId: String? {
        guard kind.lowercased() == "social_post" else { return nil }
        return targetId
    }

    /// Décode la carte depuis la chaîne JSON `message.metadata`. Renvoie nil si la
    /// clé `shareCard` est absente/invalide.
    static func parse(fromMetadataJSON json: String?) -> ShareCardData? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let card = root["shareCard"] as? [String: Any]
        else { return nil }

        let kind = (card["kind"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = (card["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !kind.isEmpty, !title.isEmpty else { return nil }

        // Lignes génériques : metadata.shareCard.metrics = { label: value }.
        // JSONSerialization ne préserve pas l'ordre des clés → tri stable par label.
        var rows: [ShareCardRow] = []
        if let metrics = card["metrics"] as? [String: Any] {
            rows = metrics
                .compactMap { key, value -> ShareCardRow? in
                    let text = ShareCardData.stringify(value)
                    guard !text.isEmpty, text.lowercased() != "null" else { return nil }
                    return ShareCardRow(label: key, value: text)
                }
                .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
        }

        // Objet structuré dédié à la carte signal.
        var signal: SignalShareData?
        if let s = card["signal"] as? [String: Any] {
            signal = SignalShareData(
                rsrp: ShareCardData.intValue(s["rsrp"]),
                band: ShareCardData.optString(s["band"]),
                site: ShareCardData.optString(s["site"]),
                operatorName: ShareCardData.optString(s["operator"]),
                technology: ShareCardData.optString(s["technology"]),
                stars: ShareCardData.intValue(s["stars"]),
                score: ShareCardData.intValue(s["score"])
            )
        }

        // Publication partagée : auteur, texte, vignette et mesure enrichie.
        var author: ShareCardAuthor?
        if let a = card["author"] as? [String: Any] {
            author = ShareCardAuthor(
                name: ShareCardData.optString(a["name"]),
                handle: ShareCardData.optString(a["handle"]),
                avatarUrl: ShareCardData.signalQuestImageURL(a["avatarUrl"])
            )
        }
        var speedtest: SpeedtestShareData?
        if let s = card["speedtest"] as? [String: Any] {
            speedtest = SpeedtestShareData(
                downloadMbps: ShareCardData.doubleValue(s["download"]),
                uploadMbps: ShareCardData.doubleValue(s["upload"]),
                pingMs: ShareCardData.doubleValue(s["ping"]),
                technology: ShareCardData.optString(s["technology"]),
                operatorName: ShareCardData.optString(s["operator"])
            )
        }
        var session: SessionShareData?
        if let s = card["session"] as? [String: Any] {
            session = SessionShareData(
                points: ShareCardData.intValue(s["points"]),
                distanceKm: ShareCardData.doubleValue(s["distance"]),
                durationSeconds: ShareCardData.intValue(s["duration"]),
                technologies: ShareCardData.optString(s["technologies"])
            )
        }

        return ShareCardData(
            kind: kind,
            targetId: ShareCardData.optString(card["id"]),
            title: title,
            subtitle: ShareCardData.optString(card["subtitle"]),
            url: ShareCardData.optString(card["url"]),
            rows: rows,
            signal: signal,
            author: author,
            text: ShareCardData.optString(card["text"]),
            imageUrl: ShareCardData.signalQuestImageURL(card["image"]),
            speedtest: speedtest,
            session: session
        )
    }

    private static func stringify(_ value: Any?) -> String {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespaces)
        case let n as NSNumber: return n.stringValue
        case .none: return ""
        default: return String(describing: value ?? "")
        }
    }

    private static func optString(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty, s.lowercased() != "null" else { return nil }
        return s
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// Localisation partagée lue depuis `metadata.location` (kind LOCATION).
struct MessageLocationData: Equatable {
    let latitude: Double
    let longitude: Double
    let place: String?
    /// Absents des anciens messages ; jamais déduits de la date d'envoi serveur.
    let accuracyMeters: Double?
    let observedAt: Date?

    /// Lien Apple Plans (ouvre la position ; libellé en légende si présent).
    var appleMapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        var items = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")]
        if let place, !place.isEmpty { items.append(URLQueryItem(name: "q", value: place)) }
        components?.queryItems = items
        return components?.url
    }

    static func parse(fromMetadataJSON json: String?) -> MessageLocationData? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let loc = root["location"] as? [String: Any]
        else { return nil }
        // Android écrit lat/lng ; on accepte aussi latitude/longitude par sûreté.
        guard
            let lat = MessageLocationData.double(loc["lat"] ?? loc["latitude"]),
            let lng = MessageLocationData.double(loc["lng"] ?? loc["longitude"]),
            lat.isFinite, (-90...90).contains(lat),
            lng.isFinite, (-180...180).contains(lng)
        else { return nil }
        let place = (loc["place"] as? String)?.trimmingCharacters(in: .whitespaces)
        // Un client ancien ou malformé ne doit pas faire déborder l'affichage
        // `Int(accuracy)` de la bulle. Au-delà de 1 000 km, l'incertitude ne
        // porte plus d'information utile : on l'omet plutôt que l'inventer.
        let accuracy = double(loc["accuracyMeters"]).flatMap {
            $0.isFinite && (0...1_000_000).contains($0) ? $0 : nil
        }
        let observedAt = (loc["observedAt"] as? String).flatMap(SQDateParsing.parse)
        return MessageLocationData(latitude: lat, longitude: lng,
            place: (place?.isEmpty == false) ? place : nil,
            accuracyMeters: accuracy, observedAt: observedAt)
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Site partagé en texte (P2-47)
//
// Format d'échange commun au web, à iOS et à Android (arrêté le 18/10) : un site
// partagé dans une conversation est un TEXTE « Libellé: valeur », une paire par
// ligne, dont la première ligne est l'en-tête « Antenne… ». Le texte voyage tel
// quel, y compris en conversation chiffrée ; le destinataire le relit pour
// dessiner une vraie carte avec une vignette de plan.
//
//   Antenne Orange (eNB 812345)
//   Opérateur: Orange
//   Technologies: 4G, 5G
//   eNB: 812345
//   PCI: 211
//   Support: 1234567
//   ANFR: 0691234567
//   Marché: FR
//   Adresse: 45, rue de Gerland, 69007 Lyon
//   Position: 45.72869, 4.83312
//   Lien: https://signalquest.fr/carte?lat=…&lng=…&siteId=…&market=FR&operator=ORANGE&open=antenna
//
// Les libellés sont toujours en français (ce n'est pas de l'affichage). Une ligne
// absente veut dire « donnée inconnue » : jamais « inconnu », jamais 0, 0. Le
// lecteur est tolérant, l'écrivain strict. Toute évolution se fait des trois
// côtés à la fois, sans quoi un site partagé retombe en texte brut.

/// Coordonnée WGS84 lue dans un partage. Valide par construction : finie, dans
/// les bornes et différente de 0, 0 (qui n'est jamais un site).
struct SiteShareCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              latitude != 0 || longitude != 0 else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

struct SiteShareCard: Equatable {
    var operatorName: String?
    /// Générations canoniques « 2G » à « 5G », de la plus ancienne à la plus récente.
    var technologies: [String] = []
    var enb: String?
    var pci: String?
    var supportId: String?
    var anfr: String?
    var market: String?
    var address: String?
    var coordinate: SiteShareCoordinate?
    var link: String?

    /// Le lien vient de l'expéditeur : seul `https` est retenu (même règle que
    /// `ShareCardData.openURL`).
    var openURL: URL? {
        guard let url = link.flatMap(URL.init(string:)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Plusieurs opérateurs sur un support (fiche ANFR) : une liste, pas un nom de marque.
    var hasSeveralOperators: Bool { operatorName?.contains(",") == true }

    // MARK: Lecture

    /// Un message plus long n'est pas un partage de site : l'écrivain tient en
    /// quelques centaines de caractères.
    private static let maxTextLength = 1_500

    /// Relit le texte d'un message. `nil` si ce n'est pas un partage de site : il
    /// faut l'en-tête « Antenne… » ET au moins une ligne de donnée connue, pour
    /// qu'un texte libre qui commence par « Antenne » reste un texte.
    static func parse(_ raw: String) -> SiteShareCard? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxTextLength else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isSeparator($0) }
        guard let first = lines.first, let header = parseHeader(first) else { return nil }

        var card = SiteShareCard()
        var known = 0
        for line in lines.dropFirst() {
            if let url = firstURL(in: line) {
                if card.link == nil { card.link = url }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = folded(String(line[..<colon]))
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard let content = meaningful(value) else { continue }
            switch label {
            case "operateur", "operator":
                card.operatorName = clipped(content, 80)
            case "technologies", "technologie", "technology":
                card.technologies = generations(in: [content])
            case "enb":
                card.enb = clipped(content, 24)
            case "pci":
                card.pci = clipped(content, 12)
            case "support":
                card.supportId = clipped(content, 48)
            case "anfr":
                card.anfr = clipped(content, 24)
            case "marche", "market":
                card.market = clipped(content.uppercased(), 8)
            case "adresse", "address":
                card.address = clipped(content, 200)
            case "position":
                card.coordinate = parseCoordinate(content)
            default:
                // Libellé inconnu (ou « Lien » sans adresse lisible) : ignoré.
                continue
            }
            known += 1
        }
        guard known > 0 else { return nil }
        // L'eNB de l'en-tête sert quand la ligne « eNB » manque (anciens partages).
        if card.enb == nil { card.enb = header.enb }
        return card
    }

    private struct Header { let enb: String? }

    /// `nil` si la ligne n'est pas un en-tête « Antenne… ». Renvoie l'eNB que la
    /// parenthèse porte éventuellement. « Antennes de Lyon » n'en est pas un.
    private static func parseHeader(_ line: String) -> Header? {
        // Décoration de tête (emoji, puce) ignorée, comme le web.
        let stripped = line.drop { !$0.isLetter && !$0.isNumber }
        let head = folded(String(stripped.prefix(7)))
        guard head == "antenne" else { return nil }
        let rest = stripped.dropFirst(7)
        if let next = rest.first, next.isLetter || next.isNumber { return nil }
        return Header(enb: firstMatch(#"\beNB\s+(\d+)"#, in: String(rest)))
    }

    private static func isSeparator(_ line: String) -> Bool {
        let core = line.filter { !$0.isWhitespace }
        return core.count >= 3 && core.allSatisfy { "-_=━".contains($0) }
    }

    /// Minuscules sans accents : « Opérateur » et « operateur » se valent.
    private static func folded(_ text: String) -> String {
        text.drop { !$0.isLetter && !$0.isNumber }
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Valeur lisible, ou `nil` pour un vide ou un « inconnu » que d'autres
    /// clients auraient écrit malgré le format.
    private static func meaningful(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ["inconnu", "unknown", "-", "—", "n/a", "null"].contains(text.lowercased()) ? nil : text
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    private static func firstURL(in line: String) -> String? {
        line.range(of: #"https?://\S+"#, options: [.regularExpression, .caseInsensitive]).map { String(line[$0]) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// « 45.72869, 4.83312 », avec « ; » à la place de la virgule de séparation
    /// et des virgules décimales (« 45,72869; 4,83312 ») tolérés. Hors bornes ou
    /// 0, 0 : pas de coordonnée, donc pas de vignette — la carte reste.
    static func parseCoordinate(_ value: String) -> SiteShareCoordinate? {
        let number = #"(-?\d+(?:[.,]\d+)?)"#
        let pattern = "^\\s*\(number)\\s*(?:[;,]|\\s)\\s*\(number)\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges == 3,
              let latRange = Range(match.range(at: 1), in: value),
              let lngRange = Range(match.range(at: 2), in: value),
              let latitude = Double(value[latRange].replacingOccurrences(of: ",", with: ".")),
              let longitude = Double(value[lngRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return SiteShareCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Les générations « 2G » à « 5G » d'une liste de systèmes (« 4G », « LTE 800 »,
    /// « 5G NR 3500 »…), dédoublonnées et de la plus ancienne à la plus récente.
    static func generations(in systems: [String]) -> [String] {
        var found = Set<String>()
        for system in systems {
            for word in system.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                switch word {
                case "2G", "GSM", "EDGE": found.insert("2G")
                case "3G", "UMTS", "HSPA", "WCDMA": found.insert("3G")
                case "4G", "LTE": found.insert("4G")
                case "5G", "NR": found.insert("5G")
                default: break
                }
            }
        }
        return ["2G", "3G", "4G", "5G"].filter(found.contains)
    }

    // MARK: Écriture

    /// Nom affiché d'un opérateur de la métropole ; `nil` pour tout autre, dont le
    /// nom est alors celui que porte le site.
    static func metropolitanOperatorName(forKey key: String?) -> String? {
        switch linkOperatorKey(key) {
        case "ORANGE": return "Orange"
        case "SFR": return "SFR"
        case "BOUYGUES": return "Bouygues Telecom"
        case "FREE": return "Free Mobile"
        default: return nil
        }
    }

    /// Clé `operator` du lien : ORANGE, SFR, BOUYGUES, FREE (comme le web), sinon
    /// le nom en majuscules, les blancs et tirets devenus `_`.
    static func linkOperatorKey(_ name: String?) -> String? {
        let key = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: #"[\s-]+"#, with: "_", options: .regularExpression)
        guard let key, !key.isEmpty, key != "ALL" else { return nil }
        switch key {
        case "BOUYGUES_TELECOM", "BYTEL": return "BOUYGUES"
        case "FREE_MOBILE": return "FREE"
        default: return key
        }
    }

    /// Le texte d'échange de ce site, ligne pour ligne. `linkSiteId` est
    /// l'identifiant que le lien porte quand il diffère du support (empreinte d'un
    /// site canadien) ; `baseURL`, l'origine du site web.
    func shareText(baseURL: URL, linkSiteId: String? = nil) -> String {
        func line(_ label: String, _ value: String?) -> String? {
            // Une valeur sur une seule ligne : un retour à la ligne casserait le format.
            let flat = value?.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return flat.flatMap { $0.isEmpty ? nil : "\(label): \($0)" }
        }
        let name = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let enbNumber = enb?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let anfrNumber = anfr?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let support = supportId?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let marketCode = market?.trimmingCharacters(in: .whitespaces).uppercased().nilIfEmpty
        let generations = Self.generations(in: technologies)

        // L'en-tête reste « Antenne … » : les anciens lecteurs le classent encore.
        let tag = enbNumber.map { "eNB \($0)" } ?? anfrNumber.map { "ANFR \($0)" }
        // Plusieurs opérateurs (fiche ANFR d'un support) : l'en-tête n'en nomme aucun.
        let headerName = hasSeveralOperators ? nil : name
        let header = "Antenne" + (headerName.map { " \($0)" } ?? "") + (tag.map { " (\($0))" } ?? "")

        var query: [(String, String)] = []
        if let coordinate {
            query.append(("lat", Self.coordinateText(coordinate.latitude)))
            query.append(("lng", Self.coordinateText(coordinate.longitude)))
        }
        if let id = (linkSiteId ?? support)?.nilIfEmpty { query.append(("siteId", id)) }
        if let marketCode { query.append(("market", marketCode)) }
        if !hasSeveralOperators, let key = Self.linkOperatorKey(name) { query.append(("operator", key)) }
        query.append(("open", "antenna"))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString

        return [
            header,
            line("Opérateur", name),
            generations.isEmpty ? nil : "Technologies: \(generations.joined(separator: ", "))",
            line("eNB", enbNumber),
            line("PCI", pci),
            line("Support", support),
            line("ANFR", anfrNumber),
            line("Marché", marketCode),
            line("Adresse", address),
            coordinate.map { "Position: \(Self.coordinateText($0.latitude)), \(Self.coordinateText($0.longitude))" },
            "Lien: \(base)/carte?\(encoded)",
        ].compactMap { $0 }.joined(separator: "\n")
    }

    /// 5 décimales, point décimal, quelle que soit la langue de l'appareil.
    private static func coordinateText(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
