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

    var openURL: URL? { url.flatMap(URL.init(string:)) }

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
                avatarUrl: ShareCardData.optString(a["avatarUrl"]).flatMap(URL.init(string:))
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
            title: title,
            subtitle: ShareCardData.optString(card["subtitle"]),
            url: ShareCardData.optString(card["url"]),
            rows: rows,
            signal: signal,
            author: author,
            text: ShareCardData.optString(card["text"]),
            imageUrl: ShareCardData.optString(card["image"]).flatMap(URL.init(string:)),
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
            let lng = MessageLocationData.double(loc["lng"] ?? loc["longitude"])
        else { return nil }
        let place = (loc["place"] as? String)?.trimmingCharacters(in: .whitespaces)
        return MessageLocationData(latitude: lat, longitude: lng, place: (place?.isEmpty == false) ? place : nil)
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
