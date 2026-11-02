import Foundation

/// Notes sur 100 du barème `experience-score-v1` (méthode v3, §9) : une par test mesuré,
/// une par usage (la Vidéo réunit l'échelle et l'adaptatif), une globale, moyenne des
/// usages notés dès qu'il y en a deux. Les apps n'envoient aucune note : le serveur fait le
/// même calcul et sert `highlights.scores`. L'app la calcule pour l'afficher tout de suite,
/// hors ligne compris ; pour un test publié, la note servie fait foi.
struct ExperienceScores: Equatable, Sendable {
    var videoLadder: Int?
    var videoAdaptive: Int?
    var video: Int?
    var webPage: Int?
    var gameAndCalls: Int?
    var upload: Int?
    var overall: Int?

    static let scale = "experience-score-v1"

    /// Nombre d'usages notés (Vidéo, Web, Jeu et appels, Envoi).
    var ratedUses: Int { [video, webPage, gameAndCalls, upload].compactMap { $0 }.count }

    var isEmpty: Bool { ratedUses == 0 }

    func score(for test: ExperienceTestKind) -> Int? {
        switch test {
        case .videoLadder: videoLadder
        case .videoAdaptive: videoAdaptive
        case .webPage: webPage
        case .gameAndCalls: gameAndCalls
        case .upload: upload
        }
    }

    init(videoLadder: Int? = nil, videoAdaptive: Int? = nil, video: Int? = nil, webPage: Int? = nil,
         gameAndCalls: Int? = nil, upload: Int? = nil, overall: Int? = nil) {
        self.videoLadder = videoLadder
        self.videoAdaptive = videoAdaptive
        self.video = video
        self.webPage = webPage
        self.gameAndCalls = gameAndCalls
        self.upload = upload
        self.overall = overall
    }

    /// Les notes d'un lancement, sur le JSON exact qui part au serveur (gigue déjà arrondie).
    init(_ tests: ExperienceTestsResult) {
        self.init(tests: ExperienceSubmission.tests(tests))
    }

    /// Les notes depuis `tests`, à la forme du contrat v1.
    init(tests: [String: Any]) {
        videoLadder = Self.ladder(Self.measured(tests["videoLadder"]))
        videoAdaptive = Self.measured(tests["videoAdaptive"]).flatMap { Self.int(($0["score"] as? [String: Any])?["total"]) }
        webPage = Self.web(Self.measured(tests["webPage"]))
        gameAndCalls = Self.cappedGame(Self.measured(tests["gameAndCalls"]))
        upload = Self.upload(Self.measured(tests["upload"]))
        let videos = [videoLadder, videoAdaptive].compactMap { $0 }
        video = videos.isEmpty ? nil : Self.mean(videos)
        let uses = [video, webPage, gameAndCalls, upload].compactMap { $0 }
        overall = uses.count >= 2 ? Self.mean(uses) : nil
    }

    /// `highlights.scores` servi par le serveur (v1.1). Une note mal formée vaut nil.
    init?(served value: JSONValue?) {
        guard case .object(let object)? = value else { return nil }
        func int(_ key: String) -> Int? {
            guard case .number(let number)? = object[key], number.isFinite, number >= 0, number <= 100,
                  number == number.rounded() else { return nil }
            return Int(number)
        }
        self.init(videoLadder: int("videoLadder"), videoAdaptive: int("videoAdaptive"), video: int("video"),
                  webPage: int("webPage"), gameAndCalls: int("gameAndCalls"), upload: int("upload"), overall: int("overall"))
    }

    // MARK: Barème par test

    /// Plus haute marche mesurée sans coupure ; aucune marche tenue = 0, et la note compte.
    private static func ladder(_ test: [String: Any]?) -> Int? {
        guard let test else { return nil }
        let held = objects(test["rungs"]).filter { rung in
            rung["state"] as? String == "measured" && objects(rung["stalls"]).isEmpty
        }
        return held.compactMap { rungPoints($0["quality"] as? String) }.max() ?? 0
    }

    private static func rungPoints(_ quality: String?) -> Int? {
        switch quality {
        case "480p": 20
        case "720p": 40
        case "1080p": 60
        case "1440p": 80
        case "2160p": 100
        default: nil
        }
    }

    /// 100 jusqu'à 1 s, 0 à 6 s ; −15 par ouverture en échec, avant la borne à 0.
    private static func web(_ test: [String: Any]?) -> Int? {
        guard let test else { return nil }
        let openings = objects(test["openings"])
        let totals = openings.filter { $0["state"] as? String == "measured" }.compactMap { int($0["totalMs"]) }
        guard let median = ExperienceHighlights.median(totals) else { return nil }
        let failed = openings.filter { $0["state"] as? String == "failed" }.count
        return final(max(0, 100 * clamp((6_000 - Double(median)) / 5_000) - 15 * Double(failed)))
    }

    /// Latence 40, gigue 25, à-coups 15, sous charge 20 ; une composante absente sort du
    /// calcul et la somme est ramenée sur 100.
    private static func game(_ test: [String: Any]?) -> Int? {
        guard let test, let median = number(test["medianMs"]) else { return nil }
        var points = 40 * clamp((300 - median) / 280)
        var maximum = 40.0
        if let jitter = number(test["jitterMs"]) {
            points += 25 * clamp((50 - jitter) / 45)
            maximum += 25
        }
        if let share = number(test["spikeShare"]) {
            points += 15 * clamp((0.10 - share) / 0.10)
            maximum += 15
        }
        if let grade = (test["underLoad"] as? [String: Any])?["grade"] as? String, let bonus = Self.gradePoints[grade] {
            points += bonus
            maximum += 20
        }
        return final(points / maximum * 100)
    }

    /// La note ne dit jamais plus que le verdict affiché à côté (décision du 28/10) :
    /// min(note, plafond du verdict), à la lecture, anciens tests compris, avant la
    /// moyenne globale. Sans verdict (donnée manquante), la note reste telle quelle.
    private static func cappedGame(_ test: [String: Any]?) -> Int? {
        guard let test, let score = game(test) else { return nil }
        guard let verdict = ExperiencePresentation.gameVerdict(test) else { return score }
        return min(score, verdict.scoreCap)
    }

    /// E existe dans le schéma ; les apps n'émettent que A à D et F.
    private static let gradePoints: [String: Double] = ["A": 20, "B": 15, "C": 10, "D": 5, "E": 0, "F": 0]

    /// Débit agrégé des vidéos envoyées, sinon des photos : 1 Mb/s → 0, 10 → 50, 100 → 100.
    private static func upload(_ test: [String: Any]?) -> Int? {
        guard let test else { return nil }
        let kept = objects(test["items"]).compactMap { item -> (kind: String, bytes: Double, ms: Double)? in
            guard let kind = item["kind"] as? String, let bytes = number(item["bytes"]), bytes > 0,
                  let ms = number(item["totalMs"]), ms > 0 else { return nil }
            return (kind, bytes, ms)
        }
        for kind in ["video", "photo"] {
            let items = kept.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            let mbps = items.reduce(0) { $0 + $1.bytes } * 8 / items.reduce(0) { $0 + $1.ms } / 1_000
            return final(100 * clamp(log10(mbps) / 2))
        }
        return nil
    }

    // MARK: Arrondis communs

    /// Ramené à 6 décimales, puis demi vers le haut, une seule fois : Swift, Kotlin et
    /// JavaScript tombent sur le même entier malgré les flottants.
    static func final(_ value: Double) -> Int {
        let six = (value * 1_000_000 + 0.5).rounded(.down) / 1_000_000
        return max(0, Int((six + 0.5).rounded(.down)))
    }

    /// Moyenne entière demi vers le haut, sans flottant : 22,5 → 23.
    static func mean(_ values: [Int]) -> Int {
        (2 * values.reduce(0, +) + values.count) / (2 * values.count)
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func measured(_ value: Any?) -> [String: Any]? {
        guard let test = value as? [String: Any], test["state"] as? String == "measured" else { return nil }
        return test
    }

    private static func objects(_ value: Any?) -> [[String: Any]] { (value as? [Any] ?? []).compactMap { $0 as? [String: Any] } }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = number(value), number == number.rounded(), abs(number) < 1e9 else { return nil }
        return Int(number)
    }
}
