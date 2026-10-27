import Foundation

/// Tests d'expérience v3 (contrat serveur `experience-tests-v1`, figé le 26/10).
///
/// iOS ne mesure pas encore ces tests : il affiche ceux publiés par Android et le
/// web. Le serveur ne recalcule rien ; il range dans `metadata.experience` six
/// valeurs déjà calculées (`highlights`), et l'app compose sa ligne dans sa langue
/// plutôt que de relire le texte français de repli du post.
struct ExperienceHighlights: Equatable {
    /// Plus haute marche vidéo lue sans coupure (« 1080p »).
    let videoMaxQuality: String?
    /// Score de la lecture adaptative, sur 100.
    let videoScore: Int?
    /// Médiane des ouvertures de page, en millisecondes.
    let pageMedianMs: Int?
    /// Latence de jeu et d'appel, en millisecondes.
    let gameMedianMs: Int?
    /// `tcp_connect` (apps) ou `http_round_trip` (web) : deux mesures qui ne se comparent pas.
    let gameProbeMethod: String?
    /// Médiane des envois de photo, en millisecondes.
    let uploadPhotoMs: Int?
    /// Notes /100 (`experience-score-v1`, contrat v2) : servies par le serveur, ou calculées
    /// sur le téléphone pour un test pas encore confirmé. Absentes d'un post antérieur au barème.
    var scores: ExperienceScores?

    var isEmpty: Bool {
        videoMaxQuality == nil && videoScore == nil && pageMedianMs == nil
            && gameMedianMs == nil && uploadPhotoMs == nil
    }

    var gameIsHTTPRoundTrip: Bool { gameProbeMethod == "http_round_trip" }

    init(videoMaxQuality: String? = nil, videoScore: Int? = nil, pageMedianMs: Int? = nil,
         gameMedianMs: Int? = nil, gameProbeMethod: String? = nil, uploadPhotoMs: Int? = nil) {
        self.videoMaxQuality = videoMaxQuality
        self.videoScore = videoScore
        self.pageMedianMs = pageMedianMs
        self.gameMedianMs = gameMedianMs
        self.gameProbeMethod = gameProbeMethod
        self.uploadPhotoMs = uploadPhotoMs
    }

    /// Les valeurs servies (`metadata.experience.highlights` ou `highlights` du détail).
    /// Une valeur absente, nulle ou mal formée vaut nil, jamais 0.
    init(served object: [String: JSONValue]) {
        func int(_ key: String) -> Int? {
            guard case .number(let value)? = object[key], value.isFinite, value >= 0, value < 1e9 else { return nil }
            return Int(value)
        }
        func string(_ key: String) -> String? {
            guard case .string(let value)? = object[key], !value.isEmpty else { return nil }
            return value
        }
        self.init(videoMaxQuality: string("videoMaxQuality"), videoScore: int("videoScore"),
                  pageMedianMs: int("pageMedianMs"), gameMedianMs: int("gameMedianMs"),
                  gameProbeMethod: int("gameMedianMs") == nil ? nil : string("gameProbeMethod"),
                  uploadPhotoMs: int("uploadPhotoMs"))
        // Un autre barème ferait d'autres notes : on ne les lit que sous le nôtre.
        if string("scoreScale") == ExperienceScores.scale {
            scores = ExperienceScores(served: object["scores"])
        }
    }

    /// Les mêmes valeurs, calculées depuis `tests` selon le §4 du contrat. Sert au
    /// détail d'un test quand le serveur n'a pas joint ses `highlights`, et fige les
    /// règles par les vecteurs du contrat.
    init(tests: [String: JSONValue]) {
        let ladder = Self.measured(tests["videoLadder"])
        let adaptive = Self.measured(tests["videoAdaptive"])
        let web = Self.measured(tests["webPage"])
        let game = Self.measured(tests["gameAndCalls"])
        let upload = Self.measured(tests["upload"])

        let cleanRungs = Self.objects(ladder?["rungs"]).filter { rung in
            Self.isMeasured(rung) && Self.objects(rung["stalls"]).isEmpty
        }
        let gameMedian = Self.int(game?["medianMs"])
        self.init(
            videoMaxQuality: cleanRungs.compactMap { Self.string($0["quality"]) }.last,
            videoScore: Self.int(Self.object(adaptive?["score"])?["total"]),
            pageMedianMs: Self.median(Self.objects(web?["openings"]).filter(Self.isMeasured).compactMap { Self.int($0["totalMs"]) }),
            gameMedianMs: gameMedian,
            gameProbeMethod: gameMedian == nil ? nil : Self.string(game?["probeMethod"]),
            uploadPhotoMs: Self.median(Self.objects(upload?["items"])
                .filter { Self.string($0["kind"]) == "photo" }
                .compactMap { Self.int($0["totalMs"]) })
        )
    }

    /// Médiane du contrat : impair = valeur du milieu ; pair = moyenne des deux du
    /// milieu arrondie à l'entier INFÉRIEUR (`Math.floor((a + b) / 2)`).
    static func median(_ values: [Int]) -> Int? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return Int((Double(sorted[middle - 1] + sorted[middle]) / 2).rounded(.down))
    }

    /// Le serveur publie un post si au moins un test est « measured ».
    static func isPublishable(tests: [String: JSONValue]) -> Bool {
        tests.values.contains { Self.isMeasured(Self.object($0) ?? [:]) }
    }

    private static func measured(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let test = object(value), isMeasured(test) else { return nil }
        return test
    }

    private static func isMeasured(_ object: [String: JSONValue]) -> Bool {
        string(object["state"]) == "measured"
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private static func objects(_ value: JSONValue?) -> [[String: JSONValue]] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { object($0) }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value, !string.isEmpty else { return nil }
        return string
    }

    private static func int(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite, number >= 0, number < 1e9 else { return nil }
        return Int(number)
    }
}

/// Ce qu'un post `kind: "experience"` porte dans `metadata.experience`.
struct FeedExperience: Equatable {
    let testId: String?
    let highlights: ExperienceHighlights
    let connectionType: String?
    let technology: String?
    let operatorKey: String?

    /// `nil` pour tout autre post.
    init?(item: UnifiedSocialFeedItem) {
        guard item.kind.lowercased() == "experience" else { return nil }
        let experience: [String: JSONValue]
        if case .object(let object)? = item.metadata?["experience"] { experience = object } else { experience = [:] }
        func string(_ key: String) -> String? {
            guard case .string(let value)? = experience[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if case .object(let highlights)? = experience["highlights"] {
            self.highlights = ExperienceHighlights(served: highlights)
        } else {
            self.highlights = ExperienceHighlights()
        }
        testId = string("experienceTestId") ?? item.sourceId
        connectionType = string("connectionType")?.lowercased()
        technology = string("technology")
        operatorKey = string("operatorKey")
    }
}

/// Détail d'un test (`GET /api/experience-tests/{id}`). Un autre lecteur que
/// l'auteur le reçoit sans `location` : la ville n'est jamais montrée aux autres.
struct ExperienceTestDetail: Decodable, Equatable {
    struct Location: Decodable, Equatable {
        let city: String?
    }

    let id: String
    let tests: [String: JSONValue]
    let highlights: ExperienceHighlights
    let location: Location?

    enum CodingKeys: String, CodingKey { case id, tests, highlights, location }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tests = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .tests)) ?? [:]
        if let served = try? c.decodeIfPresent([String: JSONValue].self, forKey: .highlights) {
            highlights = ExperienceHighlights(served: served)
        } else {
            highlights = ExperienceHighlights(tests: tests)
        }
        location = try? c.decodeIfPresent(Location.self, forKey: .location)
    }

    /// État de chacun des cinq tests présents, dans l'ordre de l'écran. Un test non
    /// sélectionné est absent : il n'a pas de ligne.
    var states: [(test: ExperienceTestKind, state: String)] {
        ExperienceTestKind.allCases.compactMap { kind in
            guard case .object(let test)? = tests[kind.rawValue],
                  case .string(let state)? = test["state"] else { return nil }
            return (kind, state)
        }
    }
}

enum ExperienceTestKind: String, CaseIterable {
    case videoLadder, videoAdaptive, webPage, gameAndCalls, upload
}
